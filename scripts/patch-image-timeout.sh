#!/usr/bin/env bash
# Add ro.hw_timeout_multiplier to the system image's build.prop.
#
# Under QEMU TCG the guest is 10-50x slower than native, so the framework's
# Watchdog and ANR timeouts fire on work that is merely slow, not stuck
# ("System UI isn't responding", "Process system isn't responding", and
# eventually an ANR cascade that kills the app under test). `ro.*` properties
# cannot be setprop'd, so the only place to raise them is build.prop inside
# system.img.
#
# Usage: sudo patch-image-timeout.sh [multiplier] [image]
#        sudo patch-image-timeout.sh 20
#        sudo patch-image-timeout.sh --check
set -euo pipefail

MULT=20
CHECK=0

# Under sudo, ~ is root's home: resolve the SDK from the invoking user instead.
if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    SDK="$ANDROID_SDK_ROOT"
elif [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    SDK="$(getent passwd "$SUDO_USER" | cut -d: -f6)/Android/Sdk"
else
    SDK="$HOME/Android/Sdk"
fi
IMAGE="$SDK/system-images/android-26/default/arm64-v8a/system.img"

if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
[ $# -ge 1 ] && MULT="$1"
[ $# -ge 2 ] && IMAGE="$2"

[ -f "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "needs root: run with sudo" >&2; exit 1; }
[[ "$MULT" =~ ^[0-9]+$ ]] || { echo "multiplier must be an integer" >&2; exit 1; }

# GPT: first partition starts at LBA 2048 in these images; parse it properly.
OFFSET=$(python3 - "$IMAGE" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(512)
    if f.read(8) != b'EFI PART':
        sys.exit('no GPT signature at LBA1')
    f.seek(1024)
    ent = f.read(128)
print(struct.unpack('<Q', ent[32:40])[0] * 512)
PY
)

MNT=$(mktemp -d)
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

echo "image    : $IMAGE"
echo "partition: offset $OFFSET"

if [ "$CHECK" -eq 1 ]; then
    mount -o "loop,ro,offset=$OFFSET" "$IMAGE" "$MNT"
    echo -n "state    : "
    grep -E '^ro\.hw_timeout_multiplier=' "$MNT/build.prop" || echo "not set"
    exit 0
fi

mount -o "loop,rw,offset=$OFFSET" "$IMAGE" "$MNT"

if grep -qE '^ro\.hw_timeout_multiplier=' "$MNT/build.prop"; then
    sed -i "s/^ro\.hw_timeout_multiplier=.*/ro.hw_timeout_multiplier=$MULT/" "$MNT/build.prop"
    echo "state    : updated to $MULT"
else
    printf '\nro.hw_timeout_multiplier=%s\n' "$MULT" >> "$MNT/build.prop"
    echo "state    : appended $MULT"
fi
sync
umount "$MNT"

# read back
mount -o "loop,ro,offset=$OFFSET" "$IMAGE" "$MNT"
echo -n "verify   : "
grep -E '^ro\.hw_timeout_multiplier=' "$MNT/build.prop" || { echo "MISSING" >&2; exit 1; }
