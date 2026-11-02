#!/usr/bin/env bash
# Install emulator 30.4.5 (build 7140946) alongside the SDK's own emulator.
#
# Needed because 37.x appends `-soundhw hda` to the arm64 ranchu machine, which
# has no PCI bus, so every arm64 AVD dies with:
#   qemu-system-aarch64: PCI bus not available for hda
#
# The download is ~267 MB. Existing install of the same build is left alone
# unless --force is passed.
#
# Usage: get-emulator-3045.sh [--force] [dest]
#   default dest: ~/Android/emulator-30.4.5
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
DEST="${1:-$HOME/Android/emulator-30.4.5}"
BUILD=7140946
URL="https://dl.google.com/android/repository/emulator-linux_x64-${BUILD}.zip"

PROPS="$DEST/emulator/source.properties"
if [ -f "$PROPS" ] && [ "$FORCE" -eq 0 ]; then
    if grep -qE '^Pkg\.(Revision=30\.4\.5|BuildId=7140946)' "$PROPS"; then
        echo "already installed: $DEST"
        grep -E '^Pkg\.(Revision|BuildId)=' "$PROPS" | sed 's/^/  /'
        exit 0
    fi
    echo "warning: $DEST exists but is not 30.4.5; use --force to replace" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $URL"
curl -fL --retry 3 --progress-bar -o "$TMP/emu.zip" "$URL"

echo "verifying archive"
unzip -tq "$TMP/emu.zip" >/dev/null

echo "extracting to $DEST"
mkdir -p "$DEST"
unzip -q -o "$TMP/emu.zip" -d "$DEST"

if [ -f "$PROPS" ]; then
    grep -E "^Pkg\.(Revision|BuildId)=" "$PROPS" | sed "s/^/  /"
fi

QEMU="$DEST/emulator/qemu/linux-x86_64/qemu-system-aarch64"
[ -x "$QEMU" ] || { echo "extraction incomplete: $QEMU missing" >&2; exit 1; }

cat <<EOF

installed. now patch the system image (needs sudo, loop mount):
  sudo ./scripts/patch-image-audio-hal.py
  sudo ./scripts/patch-image-timeout.sh

then start:
  ./bin/arm-emu.sh <avd> 5562
EOF
