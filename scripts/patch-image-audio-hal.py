#!/usr/bin/env python3
"""Patch the arm64 API-26 vendor image so the audio HAL stops crashing.

Symptom this fixes
------------------
After switching to emulator 30.4.5 the AVD gets a QEMU process and adb shows the
device, but boot never completes:

    E AudioService: Audioserver died.
    I ServiceManager: Waiting for service media.sound_trigger_hw...

`getprop sys.boot_completed` stays empty and `pm install` produces no output at
all, because `system_server` is parked in startOtherServices() waiting for a
sound-trigger HAL that can never publish.

Cause
-----
`StreamOut::getPresentationPosition` in
    /vendor/lib64/hw/android.hardware.audio@2.0-impl.so
segfaults inside its lazy-init prologue:

    0x2aa10 : adrp x8, ...            <- lazy init entry
    0x2aa8c : ldr  x8, [x21, #0xc0]   <- normal path once initialised

Patching the entry instruction to jump straight to the normal path
(`b 0x2aa8c`, encoded 0x1400001f) removes the crash. File offset is
`vaddr - 0x6000` = 0x24a10 (that segment is mapped at vaddr = file_offset + 0x6000).

Usage
-----
    sudo ./patch-image-audio-hal.py            # patch the default image
    sudo ./patch-image-audio-hal.py --check    # report state, change nothing
    sudo ./patch-image-audio-hal.py --image /path/to/vendor.img

The original .so is saved next to the image as
`<image>.audiohal-orig.so` the first time the patch is applied.
"""
from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

SO_IN_IMAGE = "lib64/hw/android.hardware.audio@2.0-impl.so"
VADDR = 0x2AA10
SEG_DELTA = 0x6000  # vaddr = file_offset + SEG_DELTA
FILE_OFF = VADDR - SEG_DELTA
PATCH_WORD = 0x1400001F  # b 0x2aa8c
EXPECTED_ORIG = 0xD00000A8  # adrp x8, ... (lazy-init entry)
DEFAULT_IMAGE = None  # resolved in main(): under sudo, ~ is root's home


def default_sdk_root() -> str:
    """SDK root of the *invoking* user — under sudo, ~ resolves to /root."""
    env = os.environ.get("ANDROID_SDK_ROOT")
    if env:
        return env
    user = os.environ.get("SUDO_USER") if os.geteuid() == 0 else None
    home = os.path.expanduser(f"~{user}") if user else os.path.expanduser("~")
    return os.path.join(home, "Android", "Sdk")


def default_image() -> str:
    return os.path.join(
        default_sdk_root(),
        "system-images/android-26/default/arm64-v8a/vendor.img",
    )


def part_offset(image: str) -> int:
    """Return the byte offset of the first GPT partition in a disk image."""
    with open(image, "rb") as fh:
        fh.seek(512)
        hdr = fh.read(92)
        if hdr[:8] != b"EFI PART":
            raise SystemExit(f"{image}: no GPT signature at LBA1")
        fh.seek(1024)  # first partition entry
        ent = fh.read(128)
    first_lba = struct.unpack("<Q", ent[32:40])[0]
    return first_lba * 512


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--image", default=DEFAULT_IMAGE, help="vendor.img path")
    ap.add_argument("--check", action="store_true", help="only report, do not write")
    args = ap.parse_args()

    image = os.path.abspath(args.image or default_image())
    if not os.path.isfile(image):
        raise SystemExit(f"no such image: {image}")
    if os.geteuid() != 0:
        raise SystemExit("needs root (loop mount): run with sudo")

    offset = part_offset(image)
    print(f"image    : {image}")
    print(f"partition: offset {offset}")

    mnt = tempfile.mkdtemp(prefix="vendorimg-")
    try:
        run(["mount", "-o", f"loop,ro,offset={offset}", image, mnt])
        so_path = os.path.join(mnt, SO_IN_IMAGE)
        if not os.path.isfile(so_path):
            raise SystemExit(f"missing in image: {SO_IN_IMAGE}")
        blob = bytearray(open(so_path, "rb").read())
    finally:
        subprocess.run(["umount", mnt], check=False)
        os.rmdir(mnt)

    if len(blob) <= FILE_OFF + 4:
        raise SystemExit(f"{SO_IN_IMAGE}: too small ({len(blob)} bytes)")

    word = struct.unpack("<I", blob[FILE_OFF:FILE_OFF + 4])[0]
    print(f"{SO_IN_IMAGE}: {len(blob)} bytes, word@0x{FILE_OFF:x} = 0x{word:08x}")

    if word == PATCH_WORD:
        print("state    : ALREADY PATCHED (b 0x2aa8c)")
        return 0
    if word != EXPECTED_ORIG:
        raise SystemExit(
            f"state    : UNEXPECTED 0x{word:08x} (expected 0x{EXPECTED_ORIG:08x} "
            "or patched 0x%08x) — different image/build, refusing to patch"
            % PATCH_WORD
        )
    print("state    : unpatched (lazy-init entry present)")

    if args.check:
        return 0

    backup = image + ".audiohal-orig.so"
    if not os.path.exists(backup):
        open(backup, "wb").write(bytes(blob))
        print(f"backup   : {backup}")

    blob[FILE_OFF:FILE_OFF + 4] = struct.pack("<I", PATCH_WORD)
    patched = image + ".audiohal-patched.so"
    with open(patched, "wb") as fh:
        fh.write(bytes(blob))
    print(f"patched  : wrote {patched}")

    mnt = tempfile.mkdtemp(prefix="vendorimg-")
    try:
        run(["mount", "-o", f"loop,rw,offset={offset}", image, mnt])
        shutil.copyfile(patched, os.path.join(mnt, SO_IN_IMAGE))
    finally:
        subprocess.run(["umount", mnt], check=False)
        os.rmdir(mnt)

    # read back from the image to prove the write landed
    mnt = tempfile.mkdtemp(prefix="vendorimg-")
    try:
        run(["mount", "-o", f"loop,ro,offset={offset}", image, mnt])
        blob2 = open(os.path.join(mnt, SO_IN_IMAGE), "rb").read()
    finally:
        subprocess.run(["umount", mnt], check=False)
        os.rmdir(mnt)

    got = struct.unpack("<I", blob2[FILE_OFF:FILE_OFF + 4])[0]
    if got != PATCH_WORD:
        raise SystemExit(f"verify FAILED: in-image word is 0x{got:08x}")
    print(f"verify   : in-image word = 0x{got:08x}  OK")
    os.unlink(patched)
    return 0


if __name__ == "__main__":
    sys.exit(main())
