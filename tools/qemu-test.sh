#!/usr/bin/env bash
# ===========================================================================
#  qemu-test.sh — boot a tinywin image in QEMU before you touch the Chromebook.
#
#    ./tools/qemu-test.sh out/tinywin-20261117.img
#
#  Needs: qemu-system-x86 + OVMF (UEFI firmware).
#    Debian/Ubuntu: sudo apt install qemu-system-x86 ovmf
#
#  With a graphical desktop (DISPLAY set) it opens a window.
#  Without one it runs headless, writes the serial console to a log and takes a
#  screenshot when it thinks the desktop should be up.
# ===========================================================================
set -Eeuo pipefail

IMG="${1:?usage: qemu-test.sh <image.img> [seconds-to-screenshot]}"
SHOT_AFTER="${2:-75}"
MEM="${MEM:-3072}"

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
IMG="$(cd "$(dirname "$IMG")" && pwd)/$(basename "$IMG")"

OVMF=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/qemu/OVMF.fd /usr/local/share/ovmf/OVMF_CODE.fd; do
  [ -f "$c" ] && OVMF="$c" && break
done
[ -n "$OVMF" ] || { echo "OVMF (UEFI firmware) not found — install the 'ovmf' package" >&2; exit 1; }

LOG="$(dirname "$IMG")/qemu-serial.log"
SHOT="$(dirname "$IMG")/qemu-screen.ppm"
MON="$(dirname "$IMG")/qemu-monitor.sock"
rm -f "$LOG" "$SHOT" "$MON"

# OVMF wants a writable copy for its variable store
VARS="$(dirname "$IMG")/ovmf-vars.fd"
for c in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
         /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.fd; do
  [ -f "$c" ] && cp -f "$c" "$VARS" && break
done

echo "image : $IMG"
echo "firmware: $OVMF"
echo "serial: $LOG"
echo "memory: ${MEM} MB"
echo

ARGS=(
  -machine q35,accel=kvm:tcg
  -m "$MEM" -smp 2
  -drive "file=$IMG,format=raw,if=virtio,cache=writeback"
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF"
)
[ -f "$VARS" ] && ARGS+=(-drive "if=pflash,format=raw,unit=1,file=$VARS")

if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "${HEADLESS:-0}" != "1" ]; then
  ARGS+=(-vga std -serial "file:$LOG")
  echo "A QEMU window should open. Log in as the desktop user; the kiosk-free"
  echo "Xfce desktop is what a real Chromebook will show. Ctrl+Alt+G releases"
  echo "the mouse, Ctrl+Alt+F2 in the guest gives you a console."
  exec qemu-system-x86_64 "${ARGS[@]}"
else
  ARGS+=(-display none -vga std -monitor "unix:$MON,server,nowait" -serial "file:$LOG")
  qemu-system-x86_64 "${ARGS[@]}" &
  QPID=$!
  trap 'kill $QPID 2>/dev/null || true' EXIT
  echo "headless: booting, then waiting ${SHOT_AFTER}s for the desktop..."
  sleep "$SHOT_AFTER"
  # ask the monitor for a framebuffer dump
  python3 - "$MON" "$SHOT" <<'PY' || true
import socket, sys, time
sock, shot = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock); time.sleep(0.3); s.recv(65536)
s.sendall(f"screendump {shot}\n".encode()); time.sleep(1.5)
print(s.recv(65536).decode(errors="replace").strip())
s.close()
PY
  [ -f "$SHOT" ] && echo "screenshot: $SHOT" || echo "(no screenshot — the guest may still be booting)"
  echo
  echo "--- tail of the guest's serial console -------------------------"
  tail -30 "$LOG" 2>/dev/null || echo "(no serial output yet)"
  echo "----------------------------------------------------------------"
  echo "Guest still running (pid $QPID). Kill it with: kill $QPID"
  wait $QPID
fi
