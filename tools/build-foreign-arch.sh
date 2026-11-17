#!/data/data/com.termux/files/usr/bin/bash
# ===========================================================================
#  build-foreign-arch.sh — build the tinywin amd64 image on an ARM64 Android
#  device (Termux, rooted). Verified logic, untested on hardware other than
#  the reference x86_64 build: expect 1.5-3 h on a Snapdragon 888-class SoC.
#
#  How it works: the *build tools* (debootstrap, sgdisk, mtools, grub) run
#  natively in an ARM64 Debian chroot; the *target* system's amd64 binaries
#  (dpkg maintainer scripts, locale-gen, initramfs hooks) run through
#  qemu-user-static registered with the kernel's binfmt_misc. No full-system
#  emulation, no nested PRoot, no loop devices.
#
#  Usage (from Termux, NOT inside proot):
#     ./tools/build-foreign-arch.sh                       # build into ./out
#     ./tools/build-foreign-arch.sh --out /data/local/tmp/tinywin-out
#     ./tools/build-foreign-arch.sh --chroot /path/to/debian/rootfs
#
#  proot-distro 5.x stores containers at containers/<name>/rootfs/; 4.x used
#  installed-rootfs/<name>/. Both are detected automatically (or use --chroot).
# ===========================================================================
set -Eeuo pipefail

KIT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=/data/local/tmp/tinywin-out
CHROOT_OVERRIDE=""
TERMUX_PREFIX=${PREFIX:-/data/data/com.termux/files/usr}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=${2:?}; shift 2 ;;
    --chroot) CHROOT_OVERRIDE=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n>>> %s\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
say "preflight"
case "$(uname -m)" in
  aarch64|arm64) : ;;
  x86_64)  die "this device is x86_64 — just run ./osbuild/build.sh directly on it." ;;
  *) die "unsupported host: $(uname -m)" ;;
esac
command -v proot-distro >/dev/null || die "run: pkg install proot-distro"

# Termux ships its own $PREFIX/bin/su, which shadows the system one and cannot
# be used here ("Permission denied"). Find a root method that actually works.
ASROOT=""
for c in tsu /system/bin/su /system/xbin/su; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c id >/dev/null 2>&1; then ASROOT=$c; break; fi
done
[ -n "$ASROOT" ] || die "no working root method. In Termux run: pkg install tsu
  then start this script with 'tsu -c \"bash $KIT/tools/build-foreign-arch.sh\"'"
say "root via: $ASROOT"

FREE_MB=$(df -Pm /data | awk 'NR==2{print $4}')
[ "${FREE_MB:-0}" -ge 9000 ] || die "need ~9 GB free on /data (have ${FREE_MB} MB)"

# ------------------------------------------------------- arm64 build chroot --
find_rootfs() {
  local c
  for c in "$CHROOT_OVERRIDE" \
           "$TERMUX_PREFIX/var/lib/proot-distro/containers/debian/rootfs" \
           "$TERMUX_PREFIX/var/lib/proot-distro/installed-rootfs/debian" \
           "$HOME/.proot-distro/containers/debian/rootfs" \
           "$HOME/.local/share/proot-distro/installed-rootfs/debian"; do
    [ -n "$c" ] && [ -x "$c/bin/bash" ] && { printf '%s\n' "$c"; return 0; }
  done
  # last resort: locate the tree that owns /etc/debian_version
  c=$(find "$TERMUX_PREFIX/var/lib/proot-distro" -maxdepth 5 -name debian_version 2>/dev/null | head -1)
  [ -n "$c" ] && { printf '%s\n' "${c%/etc/debian_version}"; return 0; }
  return 1
}

D=$(find_rootfs || true)
if [ -z "$D" ]; then
  say "no Debian chroot yet — installing one (helper only; the target is amd64)"
  proot-distro install debian || die "proot-distro install debian failed"
  D=$(find_rootfs || true)
fi
[ -n "$D" ] && [ -x "$D/bin/bash" ] || die "could not locate the Debian rootfs.
  Run: bash tools/find-chroot.sh    and pass the path it prints as --chroot <path>"
say "helper chroot: $D"
case "$(cat "$D/etc/debian_version" 2>/dev/null)" in
  13*) : ;;
  12*) die "the chroot is Debian 12 (bookworm); remove it and reinstall:
  proot-distro remove debian && pkg update && proot-distro install debian" ;;
  *)   say "warning: unexpected debian_version ($(cat "$D/etc/debian_version" 2>/dev/null))" ;;
esac



# a root script that runs inside that chroot: mount, install tools, build
INNER=/data/local/tmp/tinywin-foreign-inner.sh
cat > "$INNER" <<'INNEREOF'
#!/bin/bash
set -Eeuo pipefail
D=$1; KIT=$2; OUT=$3
mkdir -p "$D/proc" "$D/sys" "$D/dev" "$D/dev/pts" "$OUT"
ismnt() { grep -q " $1 " /proc/mounts 2>/dev/null; }
ismnt "$D/proc"    || mount -t proc  proc  "$D/proc"
ismnt "$D/sys"     || mount -t sysfs sys   "$D/sys"
ismnt "$D/dev"     || mount --bind /dev    "$D/dev"
ismnt "$D/dev/pts" || mount --bind /dev/pts "$D/dev/pts"
printf 'nameserver 1.1.1.1\n' > "$D/etc/resolv.conf"

# the kernel must be able to run x86_64 ELFs: binfmt_misc
if [ ! -d /proc/sys/fs/binfmt_misc ]; then
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi
if [ ! -d /proc/sys/fs/binfmt_misc ]; then
  echo "!! this kernel has no binfmt_misc — cannot run amd64 maintainer scripts."
  echo "!! Use the GitHub Actions route (.github/workflows/build-image.yml) or a PC."
  exit 3
fi

cp -f /data/local/tmp/qemu-x86_64-static "$D/usr/bin/" 2>/dev/null || true

chroot "$D" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  DEBIAN_FRONTEND=noninteractive TERM=dumb bash -euo pipefail -c "
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      debootstrap gdisk mtools dosfstools e2fsprogs fdisk rsync python3 xz-utils \
      file ca-certificates grub-common grub-pc-bin grub-efi-amd64-bin \
      qemu-user-static binfmt-support
    update-binfmts --enable qemu-x86_64 || true
    ls -l /proc/sys/fs/binfmt_misc/ | tr '\n' ' '; echo
    # sanity: can this chroot execute an amd64 binary at all?
    if ! /usr/libexec/qemu-binfmt/x86_64-binfmt-P /bin/true 2>/dev/null && \
       ! qemu-x86_64-static /bin/true 2>/dev/null; then
      echo '!! qemu-user-static is not executing amd64 binaries'
      exit 4
    fi
    mkdir -p /build && cp -a /kit/. /build/ 2>/dev/null || true
    cd /build
    ./osbuild/build.sh --arch amd64 --size 6G --no-compress \
        --out /out --work /build-work
  "
INNEREOF
chmod +x "$INNER"

# bind the kit into the chroot so it does not get copied twice
mkdir -p "$D/kit" "$D/out" "$D/build-work"
ismnt2() { grep -q " $1 " /proc/mounts 2>/dev/null; }
ismnt2 "$D/kit" || mount --bind "$KIT" "$D/kit"
ismnt2 "$D/out" || mount --bind "$OUT" "$D/out"

say "building amd64 tinywin on $(uname -m) via qemu-user  (1.5-3 h on ARM)"
say "keep the charger plugged in and run 'termux-wake-lock' in another session"
"$ASROOT" -c "bash $INNER $D $KIT $OUT" || die "build failed — see the log above"

say "done: $OUT"
ls -lh "$OUT"
cat <<EOF

Next: write the raw .img to a USB stick (from a root shell):

  su -
  dd if=$OUT/tinywin-*.img of=/dev/block/sda bs=4M conv=fsync && sync

(your firmware is UEFI Full ROM, so the stick boots directly:
 Esc at power-on -> Boot Manager -> UEFI: <stick>)
EOF
