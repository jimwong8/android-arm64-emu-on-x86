#!/usr/bin/env bash
# Recreate an arm64 AVD from the templates checked into avd/.
#
# An AVD is just two text files:
#     ~/.android/avd/<name>.ini            -> points at the .avd directory
#     ~/.android/avd/<name>.avd/config.ini -> screen, RAM, cores, system image
# The emulator creates userdata/cache on first boot, so checking those two files
# in is enough to rebuild the device anywhere.
#
# `avdmanager create avd` is deliberately NOT used: with recent cmdline-tools it
# dies with "Range [0, 0 + -1) out of bounds for length 256" while scanning
# device profiles, and it only produces a worse default config anyway.
#
# Two profiles ship with this repo:
#   avd/gx26      320x640 @160dpi, 4 cores, 3 GB RAM, 4 GB data — small enough to
#                 be tolerable under TCG (10-50x slower than native)
#   avd/gx_arm64  1080x2340 @440dpi (pixel_5) — realistic phone, slower to boot
#
# Usage: create-avd.sh [name] [template] [image]
#   create-avd.sh                     # -> gx26 from avd/gx26
#   create-avd.sh mytest gx26
#   create-avd.sh big gx_arm64 system-images;android-26;default;arm64-v8a
set -euo pipefail

NAME="${1:-gx26}"
TEMPLATE="${2:-gx26}"
IMAGE="${3:-system-images;android-26;default;arm64-v8a}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"

TPL_DIR="$REPO/avd/$TEMPLATE"
[ -f "$TPL_DIR/config.ini" ] || {
    echo "no template: $TPL_DIR/config.ini" >&2
    echo "available:" >&2
    ls "$REPO/avd" 2>/dev/null | sed 's/^/  /' >&2
    exit 1
}

# system-images;android-26;default;arm64-v8a -> system-images/android-26/default/arm64-v8a
IMG_PATH="${IMAGE//;//}"
if [ ! -d "$ANDROID_SDK_ROOT/$IMG_PATH" ]; then
    echo "system image not installed:" >&2
    echo "  $ANDROID_SDK_ROOT/$IMG_PATH" >&2
    echo "install it with:" >&2
    echo "  $ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager \"$IMAGE\"" >&2
    exit 1
fi

AVD_HOME="$HOME/.android/avd/${NAME}.avd"
if [ -e "$AVD_HOME" ] || [ -e "$HOME/.android/avd/${NAME}.ini" ]; then
    echo "AVD already exists: $AVD_HOME" >&2
    echo "remove it first: rm -rf \"$AVD_HOME\" \"$HOME/.android/avd/${NAME}.ini\"" >&2
    exit 1
fi

echo "creating AVD '$NAME' from template '$TEMPLATE'"
mkdir -p "$AVD_HOME"
cp "$TPL_DIR/config.ini" "$AVD_HOME/config.ini"
sed -i "s/^avd\.id=.*/avd.id=$NAME/; s/^avd\.name=.*/avd.name=$NAME/" "$AVD_HOME/config.ini"

printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/%s.avd\ntarget=android-26\n' \
    "$AVD_HOME" "$NAME" > "$HOME/.android/avd/${NAME}.ini"

echo "created: $AVD_HOME"
grep -E '^(avd\.name|abi\.type|hw\.cpu\.arch|hw\.lcd\.width|hw\.lcd\.height|hw\.lcd\.density|hw\.ramSize|hw\.cpu\.ncore|image\.sysdir\.1)=' \
    "$AVD_HOME/config.ini" | sed 's/^/  /'

cat <<EOF

start it with:
  ./bin/arm-emu.sh $NAME 5562

first boot under TCG takes ~3-6 min; wait for:
  adb -s emulator-5562 shell getprop sys.boot_completed   -> 1
EOF
