#!/data/data/com.termux/files/usr/bin/bash
# ===========================================================================
#  find-chroot.sh — run this in Termux (no root needed). It tells you exactly
#  which command line to use for the build, on your device, right now.
#
#      bash find-chroot.sh
#
#  Prints: architecture, free space, proot-distro version + layout, where the
#  Debian rootfs actually is, how to get root here, and whether the kernel can
#  execute x86_64 binaries at all (needed for an amd64 build on an arm64 phone).
# ===========================================================================
set -u
P=${PREFIX:-/data/data/com.termux/files/usr}
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
yes_no() { [ "$1" = 0 ] && echo "yes" || echo "NO"; }

say "1. device"
printf '  arch          : %s\n' "$(uname -m)"
printf '  android       : %s\n' "$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
printf '  kernel        : %s\n' "$(uname -r)"
printf '  free on /data : %s\n' "$(df -h /data 2>/dev/null | awk 'NR==2{print $4" of "$2}')"

say "2. proot-distro"
if command -v proot-distro >/dev/null; then
  printf '  version       : %s\n' "$(proot-distro --version 2>/dev/null | head -1)"
  printf '  installed     : %s\n' "$(proot-distro list --installed 2>/dev/null | tr '\n' ' ' || true)"
else
  echo "  not installed (pkg install proot-distro)"
fi
echo "  base dirs:"
for b in "$P/var/lib/proot-distro" "$HOME/.proot-distro" "$HOME/.local/share/proot-distro"; do
  [ -d "$b" ] && { printf '    %s\n' "$b"; ls -1 "$b" 2>/dev/null | sed 's/^/      /'; }
done

say "3. where is the Debian rootfs?"
FOUND=""
for c in \
  "$P/var/lib/proot-distro/containers/debian/rootfs" \
  "$P/var/lib/proot-distro/installed-rootfs/debian" \
  "$HOME/.proot-distro/containers/debian/rootfs" \
  "$HOME/.local/share/proot-distro/installed-rootfs/debian"; do
  if [ -x "$c/bin/bash" ]; then printf '  [ok] %s\n' "$c"; FOUND=${FOUND:-$c}; fi
done
if [ -z "$FOUND" ]; then
  echo "  not at a known path; searching (this takes a few seconds)…"
  S=$(find "$P/var/lib/proot-distro" "$HOME" -maxdepth 5 -name debian_version -printf '%h\n' 2>/dev/null | head -3)
  [ -n "$S" ] && printf '%s\n' "$S" | sed 's|/etc$|   <-- this is the D= value|; s/^/  /'
fi
if [ -n "$FOUND" ]; then
  printf '  debian version: %s\n' "$(cat "$FOUND/etc/debian_version" 2>/dev/null)"
  printf '\n  >>> use this in the guide:\n  D=%s\n' "$FOUND"
fi

say "4. can proot-distro itself start it?"
if proot-distro login debian -- cat /etc/debian_version </dev/null >/tmp/pdtest 2>/tmp/pderr; then
  printf '  yes — Debian %s runs (proot)\n' "$(cat /tmp/pdtest)"
else
  printf '  NO:\n'; tail -3 /tmp/pderr | sed 's/^/    /'
fi

say "5. how do we get root here?"
echo "  \$PREFIX/bin/su  : $([ -x "$P/bin/su" ] && echo exists || echo missing)   (Termux's own — often not usable)"
for s in tsu /system/bin/su /system/xbin/su; do
  if command -v "$s" >/dev/null 2>&1; then
    if "$s" -c id >/dev/null 2>&1; then printf '  %-16s: works (uid=0)\n' "$s"
    else printf '  %-16s: present but refused\n' "$s"; fi
  fi
done
command -v magisk >/dev/null && echo "  magisk          : $(magisk -v 2>/dev/null)"
echo "  recommendation  : pkg install tsu   then use 'tsu' (or 'tsu -c \"command\"')"

say "6. can this kernel run x86_64 binaries (needed for an amd64 build)?"
printf '  binfmt_misc   : %s\n' "$([ -d /proc/sys/fs/binfmt_misc ] && echo present || echo 'NOT mounted (root can mount it)')"
printf '  qemu-x86_64   : %s\n' "$(command -v qemu-x86_64-static || echo 'not installed (apt install qemu-user-static + binfmt-support inside Debian)')"

say "7. verdict"
[ -n "$FOUND" ] && echo "  Debian helper chroot: ready" || echo "  Debian helper chroot: install it (proot-distro install debian)"
echo "  then:  tsu     # become root"
echo "         bash tools/build-foreign-arch.sh --chroot ${FOUND:-<D from step 3>}"
