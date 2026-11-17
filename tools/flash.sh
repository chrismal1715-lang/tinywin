#!/usr/bin/env bash
# ===========================================================================
#  flash.sh — write a tinywin image to a USB stick, safely.
#
#    sudo ./tools/flash.sh out/tinywin-20261117.img /dev/sdX
#
#  macOS:        diskutil list   ->  /dev/diskN   (then use rdiskN if asked)
#  Windows:      use Rufus (select the .img, "DD image" mode) or balenaEtcher
#
#  This refuses to write to a disk that is mounted or looks like your system
#  disk, shows you exactly what it is about to destroy, and verifies the result.
# ===========================================================================
set -Eeuo pipefail

IMG="${1:-}"
DEV="${2:-}"
if [ -z "$IMG" ] || [ -z "$DEV" ]; then
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
[ -b "$DEV" ] || { echo "not a block device: $DEV" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

SIZE="$(stat -c %s "$IMG" 2>/dev/null || stat -f %z "$IMG")"
DEV_SIZE="$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)"
DEVMODEL="$(cat "/sys/block/$(basename "$DEV")/device/model" 2>/dev/null || echo unknown)"
REMOVABLE="$(cat "/sys/block/$(basename "$DEV")/removable" 2>/dev/null || echo 0)"

# refuse the obvious mistakes
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || echo "")"
if [ -n "$ROOT_SRC" ] && [ "$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)" = "$(basename "$DEV")" ]; then
  echo "REFUSING: $DEV holds the filesystem you are running from." >&2; exit 1
fi
if grep -qs "^$DEV" /proc/mounts; then
  echo "REFUSING: something on $DEV is mounted. Unmount it first." >&2; exit 1
fi
for p in /dev/disk/by-uuid/*; do
  [ -e "$p" ] || continue
done

echo "  image : $IMG  ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "$SIZE bytes"))"
echo "  target: $DEV  ($(numfmt --to=iec "$DEV_SIZE" 2>/dev/null || echo "$DEV_SIZE bytes"), $DEVMODEL, removable=$REMOVABLE)"
echo
if [ "$DEV_SIZE" -lt "$SIZE" ]; then
  echo "REFUSING: the target is smaller than the image." >&2; exit 1
fi
if [ "$REMOVABLE" != "1" ]; then
  echo "WARNING: $DEV does not look removable."
fi
echo "Everything on $DEV will be destroyed."
printf 'Type ERASE to continue: '
read -r ANSWER
[ "$ANSWER" = "ERASE" ] || { echo "cancelled"; exit 1; }

echo "writing..."
dd if="$IMG" of="$DEV" bs=16M conv=fsync status=progress oflag=direct 2>/dev/null \
  || dd if="$IMG" of="$DEV" bs=16M conv=fsync status=progress
sync

echo "verifying (reading it back)..."
IMG_HASH="$(head -c "$SIZE" "$IMG" | sha256sum | cut -d' ' -f1)"
DEV_HASH="$(dd if="$DEV" bs=16M count=$(( (SIZE + 16777215) / 16777216 )) 2>/dev/null | head -c "$SIZE" | sha256sum | cut -d' ' -f1)"
if [ "$IMG_HASH" = "$DEV_HASH" ]; then
  echo "verified: the stick matches the image byte for byte."
else
  echo "WARNING: verification mismatch — re-run, or use a different stick." >&2
  exit 1
fi

cat <<EOF

Done. Now:
  1. Plug the stick into the Chromebook.
  2. Power on. With MrChromebox UEFI firmware it boots straight away.
     With stock firmware + RW_LEGACY: press Esc+Refresh+Power, then Ctrl+L.
  3. From the desktop, run "Install tinywin to internal disk" to move it to
     the eMMC (or just keep booting from the stick).
EOF
