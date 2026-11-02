#!/usr/bin/env bash
# Launch an arm64 Android AVD on an x86_64 Linux host.
#
# The SDK's own emulator (37.x) refuses arm64 images outright, and its bundled
# qemu-system-aarch64 then aborts with "PCI bus not available for hda" because
# it appends `-soundhw hda` to a ranchu machine that has no PCI bus. Emulator
# 30.4.5 drives the same image correctly over TCG (virtio-mmio).
#
# Prerequisites (see README): emulator 30.4.5 installed by
# scripts/get-emulator-3045.sh, and vendor.img/system.img patched by
# scripts/patch-image-audio-hal.py + scripts/patch-image-timeout.sh.
#
# Usage: arm-emu.sh <avd> [port]
#   arm-emu.sh gx26 5562
# Env:   ARM_EMU_DIR  emulator install root (default ~/Android/emulator-30.4.5)
#        ANDROID_SDK_ROOT  SDK root (default ~/Android/Sdk)
set -uo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

AVD="$1"
PORT="${2:-5562}"

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
EMU="${ARM_EMU_DIR:-$HOME/Android/emulator-30.4.5}/emulator"
export LD_LIBRARY_PATH="$EMU/lib64:$EMU/lib64/qt/lib"
BIN="$EMU/qemu/linux-x86_64/qemu-system-aarch64"
LOG="/tmp/arm-emu-${AVD}-${PORT}.log"

if [ ! -x "$BIN" ]; then
    echo "missing $BIN" >&2
    echo "install it first: scripts/get-emulator-3045.sh   (or set ARM_EMU_DIR)" >&2
    exit 1
fi

if [ ! -f "$HOME/.android/avd/${AVD}.avd/config.ini" ]; then
    echo "no such AVD: $AVD" >&2
    echo "available:" >&2
    ls "$HOME/.android/avd" 2>/dev/null | sed 's/\.avd$//; s/\.ini$//' | sort -u | sed 's/^/  /' >&2
    exit 1
fi

# Refuse to start if another instance already owns the port.
if adb devices 2>/dev/null | grep -q "^emulator-${PORT}[[:space:]]"; then
    echo "port $PORT already in use by emulator-$PORT" >&2
    exit 1
fi

cat <<EOF
== arm64 emulator: $AVD on port $PORT
   emulator: $EMU
   TCG (no KVM) — a cold boot takes ~3-6 min; leave it alone until boot_completed=1
   log:      $LOG
   wait:     adb -s emulator-$PORT wait-for-device
   check:    adb -s emulator-$PORT shell getprop sys.boot_completed
EOF

exec "$BIN" -avd "$AVD" -no-window -accel off -port "$PORT" \
    -no-snapshot -gpu swiftshader_indirect \
    > "$LOG" 2>&1
