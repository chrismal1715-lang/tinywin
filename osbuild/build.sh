#!/bin/bash
# ===========================================================================
#  tinywin builder — Debian trixie, minimal Xfce desktop, glibc (so that a
#  normal prebuilt browser binary can be dropped in later).
#
#  Design rule #1: NO LOOP DEVICES AND NO MOUNTS.
#  Everything is assembled with plain file I/O (sgdisk, mkfs + -d, mtools,
#  dd) so the build also runs on a rooted Android phone in Termux/proot,
#  where losetup/mount are unavailable.
#
#  Usage:
#    sudo ./osbuild/build.sh                 # 6 GiB image, xz-compressed
#    sudo ./osbuild/build.sh --size 6G --no-compress --out /tmp/out --work /tmp
#  Flags: --user --password --root-password --hostname --timezone --keyboard
#         --extra-pkgs --size --out --work --rootfs-only --no-compress --mirror --arch
# ===========================================================================
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

DIST=trixie
ARCH=amd64
MIRROR="http://deb.debian.org/debian"
SECURITY="http://security.debian.org/debian-security"

USERNAME=tinywin
PASSWORD=tinywin
ROOT_PASSWORD=""
HOSTNAME_T=tinywin
TIMEZONE=America/New_York
KEYBOARD=us
EXTRA_PKGS=""
SIZE=6G
OUT=$PWD/out
WORK=${TMPDIR:-/tmp}/tinywin-build
ROOTFS_ONLY=0
COMPRESS=1

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOGDIR=$HERE/../docs

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          USERNAME=${2:?}; shift 2 ;;
    --password)      PASSWORD=${2:?}; shift 2 ;;
    --root-password) ROOT_PASSWORD=${2:?}; shift 2 ;;
    --hostname)      HOSTNAME_T=${2:?}; shift 2 ;;
    --timezone)      TIMEZONE=${2:?}; shift 2 ;;
    --keyboard)      KEYBOARD=${2:?}; shift 2 ;;
    --extra-pkgs)    EXTRA_PKGS=${2:-}; shift 2 ;;
    --size)          SIZE=${2:?}; shift 2 ;;
    --out)           OUT=${2:?}; shift 2 ;;
    --work)          WORK=${2:?}; shift 2 ;;
    --mirror)        MIRROR=${2:?}; shift 2 ;;
    --arch)          ARCH=${2:?}; shift 2 ;;
    --rootfs-only)   ROOTFS_ONLY=1; shift ;;
    --no-compress)   COMPRESS=0; shift ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ logging --
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT" "$WORK" "$LOGDIR" 2>/dev/null || true
LOG=$OUT/build-$STAMP.log
exec > >(tee -a "$LOG") 2>&1
STEP=0
step() { STEP=$((STEP+1)); printf '\n=== [%d] %s ===\n' "$STEP" "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
warn() { printf '  !!   %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }
trap 'die "unexpected failure on line $LINENO"' ERR

chroot_run() { chroot "$ROOTFS" /usr/bin/env -i \
  HOME=/root TERM=dumb PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 bash -euo pipefail -c "$*"; }

# ===========================================================================
step "host checks"
# ===========================================================================
for t in debootstrap sgdisk mtools mcopy mdir mkfs.vfat mkfs.ext4 grub-mkstandalone \
         grub-mkimage rsync python3 truncate dd; do
  command -v "$t" >/dev/null || die "missing tool: $t
  Debian/Ubuntu: apt-get install debootstrap gdisk mtools dosfstools e2fsprogs \
                 grub-common grub-pc-bin grub-efi-amd64-bin rsync python3 xz-utils
  Termux (root): pkg install debootstrap gdisk mtools dosfstools e2fsprogs rsync python xz-utils"
done
[ "$(id -u)" -eq 0 ] || warn "not root — debootstrap may still work, mounting-free build should be fine"
[ -f "$HERE/packages.list" ] || die "packages.list not found next to build.sh"
[ -d "$HERE/overlay" ]       || die "overlay/ not found next to build.sh"
GRUBDIR_I386=$(grub-mkimage --help >/dev/null 2>&1 && echo /usr/lib/grub/i386-pc || true)
[ -f "$GRUBDIR_I386/boot.img" ] || warn "no $GRUBDIR_I386/boot.img — legacy BIOS bootloader will be skipped"
ok "tools present (grub i386-pc modules: ${GRUBDIR_I386:-none})"

ROOTFS=$WORK/rootfs
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"

# ===========================================================================
step "debootstrap $DIST ($ARCH)"
# ===========================================================================
debootstrap --arch=$ARCH --variant=minbase --include=apt-utils,ca-certificates,locales,tzdata \
            $DIST "$ROOTFS" "$MIRROR" || die "debootstrap failed"
ok "base system: $(du -sh "$ROOTFS" | cut -f1)"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $DIST main contrib non-free non-free-firmware
deb $MIRROR $DIST-updates main contrib non-free non-free-firmware
deb $SECURITY $DIST-security main contrib non-free non-free-firmware
EOF
mkdir -p "$ROOTFS/etc/apt/apt.conf.d"
cat > "$ROOTFS/etc/apt/apt.conf.d/99tinywin" <<'EOF'
APT::Install-Recommends "true";
APT::Install-Suggests "false";
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
Acquire::Languages "none";
Dpkg::Options { "--force-confdef"; "--force-confold"; }
EOF
# no automatic updaters, ever — the user presses the button
cat > "$ROOTFS/etc/apt/apt.conf.d/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
rm -f "$ROOTFS/etc/apt/apt.conf.d/99*unattended*" 2>/dev/null || true

# ===========================================================================
step "base configuration"
# ===========================================================================
printf 'tinywin\n' > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_T
::1         localhost ip6-localhost ip6-loopback
EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE "$ROOTFS/etc/localtime"
echo "$TIMEZONE" > "$ROOTFS/etc/timezone"
printf 'en_US.UTF-8 UTF-8\nC.UTF-8 UTF-8\n' > "$ROOTFS/etc/locale.gen"
mkdir -p "$ROOTFS/etc/default"
cat > "$ROOTFS/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYBOARD"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
cat > "$ROOTFS/etc/fstab" <<'EOF'
# filled in at image-assembly time (PARTUUIDs are generated there)
EOF
[ -e "$ROOTFS/etc/os-release" ] || ln -sf ../usr/lib/os-release "$ROOTFS/etc/os-release"
cat > "$ROOTFS/usr/lib/os-release" <<EOF
PRETTY_NAME="tinywin 1.0"
NAME="tinywin"
VERSION_ID="1.0"
VERSION="1.0 (trixie)"
ID=tinywin
ID_LIKE=debian
VERSION_CODENAME=$DIST
ANSI_COLOR="0;36"
HOME_URL="https://www.debian.org/"
EOF
ln -sf /usr/lib/os-release "$ROOTFS/etc/os-release"
ok "hostname/timezone/locale set"

# ===========================================================================
step "packages ($(grep -vcE '^[[:space:]]*(#|$)' "$HERE/packages.list") listed)"
# ===========================================================================
PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$HERE/packages.list" | tr '\n' ' ')
[ -n "$EXTRA_PKGS" ] && PKGS="$PKGS $EXTRA_PKGS"
export DEBIAN_FRONTEND=noninteractive
chroot_run "apt-get update -qq"
chroot_run "apt-get -y -q --no-install-recommends install $PKGS" || {
  warn "batch install failed — retrying one package at a time to find the culprit"
  FAILED=""
  for p in $PKGS; do
    chroot_run "apt-get -y -q --no-install-recommends install $p" || FAILED="$FAILED $p"
  done
  [ -z "$FAILED" ] || warn "packages that would not install:$FAILED"
}
ok "installed: $(chroot_run "dpkg-query -W -f='\${Package}\n'" | wc -l) packages, $(du -sh "$ROOTFS" | cut -f1)"

# ===========================================================================
step "users, sudo, autologin"
# ===========================================================================
chroot_run "usermod -s /bin/bash root; passwd -d root >/dev/null 2>&1 || true"
[ -n "$ROOT_PASSWORD" ] && chroot_run "echo 'root:$ROOT_PASSWORD' | chpasswd"
chroot_run "id $USERNAME >/dev/null 2>&1 || useradd -m -s /bin/bash -c '$USERNAME' $USERNAME"
chroot_run "echo '$USERNAME:$PASSWORD' | chpasswd"
for g in sudo audio video input plugdev netdev bluetooth lpadmin; do
  chroot_run "getent group $g >/dev/null && usermod -aG $g $USERNAME || true"
done
# passwordless sudo: this is a single-user laptop, and no dialog gets in the way
cat > "$ROOTFS/etc/sudoers.d/010-$USERNAME" <<EOF
$USERNAME ALL=(ALL) NOPASSWD: ALL
Defaults:$USERNAME !lecture, !mail_badpass
EOF
chmod 440 "$ROOTFS/etc/sudoers.d/010-$USERNAME"

mkdir -p "$ROOTFS/etc/lightdm/lightdm.conf.d"
cat > "$ROOTFS/etc/lightdm/lightdm.conf.d/50-tinywin.conf" <<EOF
[Seat:*]
autologin-user=$USERNAME
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
greeter-hide-users=false
EOF
ok "user $USERNAME with passwordless sudo, LightDM autologin"

# missing user dirs + skel ownership
chroot_run "mkdir -p /home/$USERNAME/.config /home/$USERNAME/.local/share /home/$USERNAME/Applications /home/$USERNAME/Downloads"
chroot_run "chown -R $USERNAME:$USERNAME /home/$USERNAME"

# ===========================================================================
step "overlay: desktop, tools, theme defaults"
# ===========================================================================
if [ -d "$HERE/overlay" ]; then
  cp -a "$HERE/overlay/." "$ROOTFS/"
  # the panel config names an absolute panel dir — point it at the real user
  find "$ROOTFS/etc/skel" -name '*.xml' -exec sed -i "s/__USER__/$USERNAME/g" {} + 2>/dev/null || true
  chmod +x "$ROOTFS"/usr/local/bin/* 2>/dev/null || true
fi
chroot_run "chown -R $USERNAME:$USERNAME /etc/skel"
chroot_run "cp -a /etc/skel/. /home/$USERNAME/ 2>/dev/null || true; chown -R $USERNAME:$USERNAME /home/$USERNAME"

# keep the wallpapers, drop the rest of the backgrounds package weight
mkdir -p "$ROOTFS/usr/share/backgrounds/tinywin"
for w in "$HERE"/overlay/usr/share/backgrounds/tinywin/*; do
  [ -f "$w" ] && cp -f "$w" "$ROOTFS/usr/share/backgrounds/tinywin/" || true
done

# xdg user dirs (Desktop, Downloads, Pictures…)
chroot_run "su -s /bin/bash $USERNAME -c 'xdg-user-dirs-update' >/dev/null 2>&1 || true"

# ---- the tools in /usr/local/bin must be able to do their job ------------
MISSING_TOOLS=""
for t in mke2fs resize2fs e2fsck tune2fs sfdisk sgdisk mkfs.vfat blkid rsync partx \
         grub-install grub-mkstandalone zenity thunar unzip 7z xz notify-send \
         nmcli wpctl xrandr xfconf-query update-desktop-database xdg-user-dirs-update; do
  [ -x "$ROOTFS/usr/sbin/$t" ] || [ -x "$ROOTFS/usr/bin/$t" ] || [ -x "$ROOTFS/sbin/$t" ] || \
    [ -x "$ROOTFS/bin/$t" ] || MISSING_TOOLS="$MISSING_TOOLS $t"
done
if [ -n "$MISSING_TOOLS" ]; then
  warn "missing in the image (tools will degrade):$MISSING_TOOLS"
else
  ok "every binary the tinywin-* tools need is present"
fi

# ===========================================================================
step "services & first-boot behaviour"
# ===========================================================================
enable_unit() {  # $1 unit
  if ! chroot_run "systemctl enable $1" >/dev/null 2>&1; then
    # offline fallback: create the WantedBy symlink by hand
    local target
    target=$(sed -n 's/^WantedBy=//p' "$ROOTFS/usr/lib/systemd/system/$1" 2>/dev/null | head -1)
    target=${target:-multi-user.target}
    if [ -f "$ROOTFS/usr/lib/systemd/system/$1" ] || [ -f "$ROOTFS/etc/systemd/system/$1" ]; then
      mkdir -p "$ROOTFS/etc/systemd/system/$target.wants"
      ln -sf "/etc/systemd/system/$1" "$ROOTFS/etc/systemd/system/$target.wants/$1" 2>/dev/null || \
      ln -sf "/usr/lib/systemd/system/$1" "$ROOTFS/etc/systemd/system/$target.wants/$1"
      return 0
    fi
    return 1
  fi
}
for u in lightdm.service NetworkManager.service systemd-timesyncd.service \
         bluetooth.service tinywin-growroot.service; do
  if [ -f "$ROOTFS/usr/lib/systemd/system/$u" ] || [ -f "$ROOTFS/etc/systemd/system/$u" ]; then
    enable_unit "$u" && ok "enabled $u" || warn "could not enable $u"
  else
    warn "unit not present, skipped: $u"
  fi
done
# mask anything that phones home or updates behind your back
for u in apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer \
         unattended-upgrades.service packagekit.service; do
  chroot_run "systemctl mask $u" >/dev/null 2>&1 && ok "masked $u" || true
done
chroot_run "systemctl set-default graphical.target" >/dev/null 2>&1 || \
  ln -sf /usr/lib/systemd/system/graphical.target "$ROOTFS/etc/systemd/system/default.target"
chroot_run "locale-gen" >/dev/null 2>&1 || chroot_run "locale-gen C.UTF-8" >/dev/null 2>&1 || \
  warn "locale-gen skipped"
ok "desktop set as default target"

# ===========================================================================
step "kernel, firmware, boot config"
# ===========================================================================
chroot_run "depmod -a" >/dev/null 2>&1 || true
KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* 2>/dev/null | head -1 || true)
[ -n "$KERNEL" ] || die "no kernel installed — is linux-image-amd64 in packages.list?"
KERNEL_NAME=$(basename "$KERNEL")
INITRD=$(ls "$ROOTFS"/boot/initrd.img-${KERNEL_NAME#vmlinuz-} 2>/dev/null | head -1 || true)
[ -n "$INITRD" ] || die "no initramfs built"
ok "$KERNEL_NAME + $(basename "$INITRD") ($(du -h "$INITRD" | cut -f1))"

mkdir -p "$ROOTFS/etc/default"
cat > "$ROOTFS/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="tinywin"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 nowatchdog"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=false
EOF
if [ "$ROOTFS_ONLY" = 0 ]; then
  # initramfs for a real disk (no resume, keep it small)
  chroot_run "update-initramfs -u -k all" >/dev/null 2>&1 || warn "initramfs rebuild skipped"
fi

# ---------------------------------------------------------------------------
#  grub.cfg — everything is by label/PARTUUID so a re-plugged disk still boots
# ---------------------------------------------------------------------------
write_grub_cfg() {   # $1 = root PARTUUID
  mkdir -p "$ROOTFS/boot/grub"
  cat > "$ROOTFS/boot/grub/grub.cfg" <<EOF
# tinywin — generated by build.sh
set default=0
set timeout=2
set timeout_style=menu

insmod part_gpt
insmod part_msdos
insmod ext2
insmod fat
insmod all_video
insmod gfxterm
insmod video_bochs
insmod video_cirrus

if loadfont /boot/grub/fonts/unicode.pf2 ; then
  set gfxmode=auto
  terminal_output gfxterm
fi
set gfxpayload=keep

menuentry "tinywin" --class debian --class gnu-linux --class os {
  search --no-floppy --label --set=root tinywin
  if [ -z "\$root" ]; then search --no-floppy --fs-uuid --set=root $1; fi
  echo "Booting tinywin…"
  linux  /boot/$(basename "$KERNEL") root=PARTUUID=$1 ro quiet loglevel=3 nowatchdog
  initrd /boot/$(basename "$INITRD")
}

menuentry "tinywin (verbose boot)" --class debian {
  search --no-floppy --label --set=root tinywin
  if [ -z "\$root" ]; then search --no-floppy --fs-uuid --set=root $1; fi
  linux  /boot/$(basename "$KERNEL") root=PARTUUID=$1 ro systemd.log_level=info
  initrd /boot/$(basename "$INITRD")
}

menuentry "Memory test (if available)" {
  search --no-floppy --label --set=root tinywin
  if [ -f /boot/memtest86+amd64.bin ]; then
    linux16 /boot/memtest86+amd64.bin
  else
    echo "memtest86+ is not installed"
    sleep 2
  fi
}

menuentry "Reboot" { reboot }
menuentry "Power off" { halt }
EOF
}

# BIOS modules + font live on the root filesystem for the core image
if [ -d "$GRUBDIR_I386" ]; then
  mkdir -p "$ROOTFS/boot/grub/i386-pc" "$ROOTFS/boot/grub/fonts"
  cp -f "$GRUBDIR_I386"/*.mod "$GRUBDIR_I386"/*.lst "$GRUBDIR_I386"/*.img \
        "$ROOTFS/boot/grub/i386-pc/" 2>/dev/null || true
  [ -f /usr/share/grub/unicode.pf2 ] && cp -f /usr/share/grub/unicode.pf2 "$ROOTFS/boot/grub/fonts/" || true
fi

# ===========================================================================
step "assemble disk image — loop-free (no losetup, no mount)"
# ===========================================================================
IMG=$OUT/tinywin-$(date +%Y%m%d).img
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"

sgdisk --clear \
  --new=1:2048:+2M   --typecode=1:EF02 --change-name=1:bios_grub \
  --new=2:0:+512M    --typecode=2:EF00 --change-name=2:TINYWIN-ESP \
  --new=3:0:0        --typecode=3:8300 --change-name=3:tinywin \
  "$IMG" >/dev/null
part_geom() { sgdisk -i "$2" "$1" | awk -F': ' -v k="$3" '$1==k {split($2,a," "); print a[1]}'; }
P1_START=$(part_geom "$IMG" 1 "First sector");  P1_SIZE=$(part_geom "$IMG" 1 "Partition size")
P2_START=$(part_geom "$IMG" 2 "First sector");  P2_SIZE=$(part_geom "$IMG" 2 "Partition size")
P3_START=$(part_geom "$IMG" 3 "First sector");  P3_SIZE=$(part_geom "$IMG" 3 "Partition size")
[ -n "$P1_START" ] && [ -n "$P2_START" ] && [ -n "$P3_START" ] || die "could not read partition geometry"
for pair in "1:$P1_START" "2:$P2_START" "3:$P3_START"; do
  s=${pair#*:}; [ $(( s % 2048 )) -eq 0 ] || die "partition ${pair%%:*} not MiB aligned (sector $s)"
done
ok "partitions: p1 ${P1_START}+${P1_SIZE}s (bios_grub), p2 ${P2_START}+${P2_SIZE}s (ESP), p3 ${P3_START}+${P3_SIZE}s (root)"

# ---- identifiers ----------------------------------------------------------
PARTUUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
FSUUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
ESPSERIAL=$(python3 -c 'import random;print("%04X-%04X"%(random.randint(0x1000,0xffff),random.randint(0x1000,0xffff)))')
sgdisk --partition-guid=3:$PARTUUID "$IMG" >/dev/null
ok "root PARTUUID $PARTUUID / fs UUID $FSUUID / ESP $ESPSERIAL"

cat > "$ROOTFS/etc/fstab" <<EOF
# <file system>                  <mount>   <type>  <options>            <dump> <pass>
PARTUUID=$PARTUUID               /         ext4    errors=remount-ro    0      1
UUID=$FSUUID                     /         ext4    errors=remount-ro    0      1
tmpfs                            /tmp      tmpfs   nosuid,nodev          0      0
EOF
write_grub_cfg "$PARTUUID"
ok "fstab + grub.cfg written (root by PARTUUID and by LABEL)"

# ---- ESP image (FAT32) ----------------------------------------------------
ESPFILE=$WORK/esp.img
rm -f "$ESPFILE"; truncate -s $((P2_SIZE * 512)) "$ESPFILE"
mkfs.vfat -F 32 -n TINYWIN-ESP -i "${ESPSERIAL/-/}" "$ESPFILE" >/dev/null 2>&1 || \
  mkfs.vfat -F 32 -n TINYWIN-ESP "$ESPFILE" >/dev/null
ESPSTAGE=$WORK/esp-stage
rm -rf "$ESPSTAGE"; mkdir -p "$ESPSTAGE/EFI/BOOT"
grub-mkstandalone -O x86_64-efi \
  --modules="part_gpt part_msdos fat ext2 normal search search_label search_fs_uuid configfile linux echo test true loadenv all_video gfxterm gfxmenu font video_bochs video_cirrus regexp keystatus sleep reboot halt minicmd lsefi efifwsetup efi_gop efi_uga" \
  --locales="" --fonts="" \
  -o "$ESPSTAGE/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$ROOTFS/boot/grub/grub.cfg" >/dev/null 2>&1 || die "grub-mkstandalone (x86_64-efi) failed"
mkdir -p "$ESPSTAGE/EFI/BOOT" "$ESPSTAGE/grub" "$ESPSTAGE/boot/grub/fonts"
[ -f /usr/share/grub/unicode.pf2 ] && cp -f /usr/share/grub/unicode.pf2 "$ESPSTAGE/boot/grub/fonts/"
cp -f "$ROOTFS/boot/grub/grub.cfg" "$ESPSTAGE/grub/grub.cfg"
printf 'fs0:\nEFI\\BOOT\\BOOTX64.EFI\n' > "$ESPSTAGE/EFI/BOOT/STARTUP.NSH"
export MTOOLS_SKIP_CHECK=1
mmd -i "$ESPFILE" ::/EFI ::/EFI/BOOT ::/grub 2>/dev/null || true
mcopy -i "$ESPFILE" "$ESPSTAGE/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/ || die "mcopy BOOTX64.EFI failed"
mcopy -i "$ESPFILE" "$ESPSTAGE/EFI/BOOT/STARTUP.NSH" ::/EFI/BOOT/ || true
mcopy -i "$ESPFILE" "$ESPSTAGE/grub/grub.cfg" ::/grub/grub.cfg || true
mmd -i "$ESPFILE" ::/boot ::/boot/grub ::/boot/grub/fonts 2>/dev/null || true
[ -f "$ESPSTAGE/boot/grub/fonts/unicode.pf2" ] && \
  mcopy -i "$ESPFILE" "$ESPSTAGE/boot/grub/fonts/unicode.pf2" ::/boot/grub/fonts/ || true
mdir -i "$ESPFILE" ::/EFI/BOOT | grep -qi 'BOOTX64' || die "ESP does not contain BOOTX64.EFI"
ok "ESP: BOOTX64.EFI ($(stat -c%s "$ESPSTAGE/EFI/BOOT/BOOTX64.EFI" | numfmt --to=iec))"

# ---- BIOS bootloader: MBR + core.img on the bios_grub partition -----------
LEGACY_OK=0
if [ -f "$GRUBDIR_I386/boot.img" ]; then
  cat > "$WORK/early.cfg" <<'EOF'
search --no-floppy --label --set=root tinywin
if [ -z "$root" ]; then
  search --no-floppy --fs-uuid --set=root __FSUUID__
fi
if [ -z "$root" ]; then set root=(hd0,gpt3); fi
set prefix=($root)/boot/grub
normal
EOF
  sed -i "s/__FSUUID__/$FSUUID/" "$WORK/early.cfg"
  if grub-mkimage -O i386-pc -o "$WORK/core.img" -c "$WORK/early.cfg" \
       -p '(hd0,gpt3)/boot/grub' \
       part_gpt part_msdos ext2 fat biosdisk search search_label search_fs_uuid \
       normal linux echo test configfile boot all_video gfxterm >/dev/null 2>&1; then
    CORESZ=$(stat -c%s "$WORK/core.img")
    MBR=$WORK/mbr.bin
    python3 - "$GRUBDIR_I386/boot.img" "$WORK/core.img" "$MBR" "$P1_START" <<'PY'
import sys, struct, math
bootimg, core, out, lba = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
b = bytearray(open(bootimg,'rb').read())
c = open(core,'rb').read()
# 440 bytes of boot code; partition table (written by sgdisk) stays untouched
mbr = bytearray(b[:440])
struct.pack_into('<Q', mbr, 0x5c, lba)                  # first sector of core.img
struct.pack_into('<H', mbr, 0x64, math.ceil(len(c)/512))# core.img size in sectors
open(out,'wb').write(mbr)
open(out+'.core','wb').write(c)
PY
    dd if="$MBR" of="$IMG" bs=440 count=1 conv=notrunc status=none
    dd if="$WORK/mbr.bin.core" of="$IMG" bs=512 seek="$P1_START" conv=notrunc status=none
    LEGACY_OK=1
    ok "BIOS bootloader: MBR + core.img ($CORESZ bytes) at LBA $P1_START"
  else
    warn "grub-mkimage (i386-pc) failed — image will be UEFI-only"
  fi
fi
[ "$LEGACY_OK" = 1 ] || warn "no legacy BIOS bootloader in this image"

# ---- root filesystem, straight out of the directory tree ------------------
# devtmpfs mounts /dev at boot; device nodes only confuse mke2fs -d
rm -rf "$ROOTFS/dev"/* 2>/dev/null || true
mkdir -p "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/run" "$ROOTFS/tmp" \
         "$ROOTFS/mnt" "$ROOTFS/media" "$ROOTFS/var/tmp"
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"
rm -f "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

ROOTIMG=$WORK/root.img
rm -f "$ROOTIMG"; truncate -s $((P3_SIZE * 512)) "$ROOTIMG"
mkfs.ext4 -q -F -m 0 -L tinywin -U "$FSUUID" -E lazy_itable_init=0,lazy_journal_init=0 \
          -d "$ROOTFS" "$ROOTIMG" || die "mkfs.ext4 -d failed"
ok "root filesystem: $(du -sh --apparent-size "$ROOTFS" | cut -f1) of content"

# ---- stamp the partitions into the image ---------------------------------
dd if="$ESPFILE" of="$IMG" bs=1M seek=$(( P2_START / 2048 )) conv=notrunc,sparse status=none \
  || die "writing ESP to image failed"
dd if="$ROOTIMG" of="$IMG" bs=1M seek=$(( P3_START / 2048 )) conv=notrunc,sparse status=none \
  || die "writing root filesystem to image failed"
sync
rm -f "$ESPFILE" "$ROOTIMG" "$WORK/mbr.bin" "$WORK/mbr.bin.core" "$WORK/core.img"
ok "image assembled: $IMG ($(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk)"

# ===========================================================================
step "verify"
# ===========================================================================
sgdisk -v "$IMG" >/dev/null 2>&1 && ok "GPT is valid" || warn "sgdisk -v complained"
mdir -i "$IMG@@$(( P2_START * 512 ))" ::/EFI/BOOT 2>/dev/null | grep -qi 'BOOTX64' \
  && ok "ESP inside the image has BOOTX64.EFI" || warn "ESP check failed"
ROOTTYPE=$(blkid -p -o value -s TYPE -O $(( P3_START * 512 )) "$IMG" 2>/dev/null || true)
[ "${ROOTTYPE:-}" = ext4 ] && ok "root partition reads back as ext4" || warn "root partition type: ${ROOTTYPE:-unknown}"
if [ "$LEGACY_OK" = 1 ]; then
  od -An -tx1 -j 510 -N 2 "$IMG" | grep -q '55 aa' && ok "MBR signature 55AA present" || warn "no MBR signature"
fi
SIZE_OUT=$(du -h "$IMG" | cut -f1); APPARENT=$(du -h --apparent-size "$IMG" | cut -f1)
ok "size: $APPARENT apparent / $SIZE_OUT on disk"

# ===========================================================================
step "release artifacts"
# ===========================================================================
cp -f "$LOG" "$OUT/build.log" 2>/dev/null || true
SHA=$OUT/$(basename "$IMG").sha256
( cd "$OUT" && sha256sum "$(basename "$IMG")" > "$(basename "$SHA")" )
ok "sha256: $(cut -d' ' -f1 "$SHA")"
if [ "$COMPRESS" = 1 ]; then
  printf '  ..   compressing (a few minutes, ~30%% of original) '
  xz -T0 -6 -f -k "$IMG" && { ok "compressed: $IMG.xz ($(du -h "$IMG.xz" | cut -f1))"; \
    ( cd "$OUT" && sha256sum "$(basename "$IMG").xz" >> "$(basename "$SHA")" ); } || warn "xz failed"
fi
if [ "$COMPRESS" = 1 ] && [ -f "$IMG.xz" ]; then
  KEEP=$IMG.xz
else
  KEEP=$IMG
fi
printf '\n%s\n' "-------------------------------------------------------------"
printf 'tinywin image ready:  %s\n' "$KEEP"
printf 'checksum:             %s\n' "$SHA"
printf 'default login:        %s / %s   (passwordless sudo)\n' "$USERNAME" "$PASSWORD"
printf 'flash it:              sudo ./tools/flash.sh %s /dev/sdX\n' "$KEEP"
printf '%s\n' "-------------------------------------------------------------"
