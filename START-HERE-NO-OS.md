# START HERE — the Chromebook has no OS

Good news: **an empty machine is the easy case.** There is nothing to preserve,
nothing to dual-boot, and no ChromeOS that could fight you for the disk. What
changes is the *order* of the work:

```
1. firmware check   → can this machine boot a USB stick at all?
2. build the image  → on Android/Termux or a PC      (BUILD-ON-ANDROID.md)
3. write it to USB  → from the phone (OTG) or a PC
4. boot the USB     → tinywin runs straight off the stick
5. install to eMMC  → one menu item; it formats the blank disk and copies itself
6. reboot           → tinywin on the internal 64 GB, grown to full size
```

The only real risk in the whole plan is step 1: on some Chromebooks the stock
firmware cannot boot a USB stick until it is unlocked and reflashed. That is
firmware, not tinywin — so it comes first.

---

> **Confirmed for this machine:** row 1 below — **MrChromebox UEFI Full ROM**
> (rabbit logo / `Esc` gives a boot menu). Nothing in §1b applies to you: no
> ChromeOS recovery USB, no reflash, no write-protect work. Go to step 2, then
> step 3, boot with `Esc` → *Boot Manager* → `UEFI: <stick>`, and use the
> installer from the running USB.

## 1. What firmware is on it now? (2 minutes)

Power on with nothing plugged in and watch what appears. Match it to a row:

| What you see | Firmware state | Can it boot our USB? | What to do |
|---|---|---|---|
| A **dark boot screen** with a rabbit/robot logo, or pressing **Esc** at power-on gives a **"Select boot device"** menu / "Boot Manager" | **MrChromebox UEFI Full ROM** — very likely, because antiX was installed, which stock firmware does not allow | **Yes, directly.** `Esc` → pick the USB → boots in UEFI mode | Go to step 2. This is the path tinywin is verified against. |
| White **"ChromeOS is missing or damaged"** screen, and **Ctrl+L** beeps then tries to boot from USB/disk | **Stock firmware, developer mode** (the state antiX installs usually leave behind) | **Yes, with Ctrl+L** (legacy/SeaBIOS). Our legacy chain is *unverified* (see `docs/build-log.txt`) | Try it: `Ctrl+L` with the stick in. If it hangs at `GRUB loading…`, tell me and I'll switch the image to syslinux. Or flash UEFI Full ROM (row 1) — no ChromeOS needed if it's already unlocked. |
| White **"OS verification is off"** screen that sits for 30 s then tries to boot, and **Ctrl+L** does nothing | **Stock, dev mode but legacy boot disabled** or firmware write-protect on | **No** | Needs the firmware utility: reinstall ChromeOS from a recovery USB (step 1b), then reflash. |
| **Recovery screen** (yellow/red exclamation, "ChromeOS is missing or damaged", only Ctrl+D / Ctrl+U work) | **Stock, locked** | **No** | Step 1b below. |
| Nothing at all on the screen but the machine powers on | Screen/backlight or firmware problem | No | Try a hard reset: hold **Refresh + Power** 10 s, then plug in the charger and power on. |

### 1b. If you land in the "No" rows

There is exactly one supported route on stock firmware and it needs a shell:

1. On another device, make a **ChromeOS recovery USB** for BABYMEGA (Google's
   *Chromebook Recovery Utility*, or `cros recovery` on Linux) — it needs a USB
   stick of 8 GB+.
2. Boot it: `Esc+Refresh+Power` → recovery → reinstall ChromeOS onto the eMMC.
   Accept that this *undoes* the "no OS" state for an hour.
3. In ChromeOS: sign in (no account needed on the first screen — use guest to
   reach the browser), enable **developer mode** (`Esc+Refresh+Power`, `Ctrl+D`,
   confirm), then open a shell with `Ctrl+Alt+T` → `shell`.
4. Run the MrChromebox firmware utility and choose **UEFI (Full ROM)**. This
   device is EOL, so the "RW_LEGACY" update is blocked by the script; Full ROM
   requires disabling write protect (battery/SuzyQ method on this board).
5. Reboot → you are in row 1 → continue at step 2.

> Do this only if you have to. If the machine already shows the rabbit logo or
> responds to `Ctrl+L`, skip all of 1b — you do not need ChromeOS for anything.

---

## 2. Build the image

Follow **`BUILD-ON-ANDROID.md`** (or run `osbuild/build.sh` on any x86_64 Linux
machine — same result, ~5 minutes instead of ~15).

Output you want: `tinywin-YYYYMMDD.img` (6 GB) + its `.sha256`.

```bash
uname -m      # OnePlus 9 Pro / Snapdragon 888 = aarch64 -> see the table below
df -h /data   # want ~9 GB free on an arm64 phone
```

On an arm64 phone there are two good routes: **GitHub Actions** (12 minutes, no
emulation — `.github/workflows/build-image.yml` is in the kit) or
**`tools/build-foreign-arch.sh`** (1.5–3 hours, everything on the phone). See
`BUILD-ON-ANDROID.md` §8 and §8b.

One command, at the end:

```bash
sudo ./osbuild/build.sh --size 6G --no-compress --out /build/out --work /build/work
# → ok image assembled: 6.0G apparent / 2.9G on disk
# → ok every binary the tinywin-* tools need is present
# → ok sha256: e8998c6c…
```

---

## 3. Put it on a USB stick

The machine has no OS, so this has to happen elsewhere: your rooted Android
device over OTG, or any PC.

**From Android (rooted), with a USB stick in an OTG adapter:**

```bash
su -
ls /dev/block/ | grep -E 'sd[a-z]$'     # e.g. sda — confirm by size below
cat /sys/block/sda/size                 # 8 GB stick ≈ 15104512
sha256sum /data/data/com.termux/files/home/tinywin/out/tinywin-*.img
dd if=/data/data/com.termux/files/home/tinywin/out/tinywin-*.img \
   of=/dev/block/sda bs=4M conv=fsync   # 3–6 minutes on USB 2.0
sync
```

**From a PC:**

* Linux/macOS: `sudo dd if=tinywin-YYYYMMDD.img of=/dev/sdX bs=4M conv=fsync`
  (or `tools/flash.sh`, which makes you type `ERASE` and reads the hash back).
* Windows: **Rufus in "DD image" mode** or **balenaEtcher**. It must be *DD
  mode* — this is a whole-disk image, not an ISO, so "ISO mode" writes a
  non-bootable stick.
* Never write the `.img.xz` directly. Either build with `--no-compress` or pipe:
  `xz -dc tinywin.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync`.

Stick must be **8 GB or larger**. Everything on it is erased.

---

## 4. Boot from it

| Firmware | Keys |
|---|---|
| UEFI Full ROM (rabbit logo) | `Esc` at power-on → *Boot Manager* → pick **UEFI: <your USB>**. Or just let it boot the USB first if it is the only disk. |
| Dev-mode stock | `Ctrl+L` at the white screen — boots the USB in legacy/SeaBIOS mode |
| Nothing happens | try the other USB port (USB-C vs USB-A), and re-write the stick in DD mode |

You should get: **GRUB menu** (2 s) → *Booting tinywin…* → auto-login as
`tinywin` → Xfce desktop with the Menu button. If the GRUB menu appears but the
kernel panics, the stick was written wrong — rewrite it raw.

---

## 5. Install onto the blank eMMC — one menu item

Straight from the running USB desktop:

**Menu → System → Install tinywin to internal disk**

* It lists every disk that is *not* the USB stick. On an empty machine the eMMC
  shows up as the only entry (usually `58–64 GB`).
* Confirm, type `ERASE`, and it does the rest in a terminal window:
  1. wipes the disk (any leftover ChromeOS/antiX GPT goes away),
  2. writes `bios_grub` + `TINYWIN-ESP` + `tinywin` partitions,
  3. formats them and **carries over the exact PARTUUID and filesystem UUID of
     the running system**, so the `/etc/fstab` and `grub.cfg` already inside the
     copy remain valid — no repair step, no wrong-UUID boot failure,
  4. `rsync`s the running system (2.7 GB, a few minutes, progress shown),
  5. installs **both** bootloaders: `EFI/BOOT/BOOTX64.EFI` on the ESP and
     MBR + `core.img` for legacy firmware,
  6. offers to reboot.
* Nothing is assumed about the target disk. Empty disk, half-written antiX,
  ChromeOS leftovers — all fine. This is the case the tool was written for.

Then: remove the USB stick, power on. The internal disk boots.

**First boot on the eMMC grows the filesystem** to the whole 64 GB
(`tinywin-growroot` runs on every boot and is a no-op once there is no slack).

---

## 6. After it boots — the order that works

1. **WiFi** — click the tray network icon, pick your network, enter the password.
2. **Updates** — Menu → System → Updates. First run pulls the current packages;
   reboot if it says so.
3. **Password** — open Terminal (Menu → Utility) and `passwd`.
4. **Browser** — no ChromeOS to copy from, so use your phone:
   * Easiest: Menu → **Get apps** → *Mozilla Firefox* (installs `firefox-esr`
     plus dependencies over WiFi).
   * Or the "Windows" way, which is what the file manager is for: download
     Firefox's Linux tarball on the phone
     (`https://www.mozilla.org/firefox/linux/` → `firefox-*.tar.bz2`), copy it to
     the USB stick, back to the Chromebook, open **Thunar** → Downloads →
     **double-click the archive** → it unpacks to `~/Applications`, finds the
     `firefox` binary, adds a Start-menu entry and offers to run it.
5. **Anything else** — same double-click on a `.deb` (installs with apt) or an
   `.AppImage` (copied to `~/Applications`, menu entry created).

---

## 7. If it goes wrong

| Symptom | Meaning | Fix |
|---|---|---|
| `ESC` at power-on does nothing, no boot menu | stock firmware, locked | §1b — ChromeOS recovery USB first |
| `Ctrl+L` prints `GRUB loading…` and stops | legacy path unverified | use UEFI Full ROM, or ask for the syslinux variant |
| "No bootable device" / boots to the white screen | stick written in ISO mode, or not DD mode | rewrite the raw `.img` |
| GRUB menu appears, kernel panics immediately | same as above (or wrong arch image) | rewrite; confirm the build was `--arch=amd64` |
| Desktop appears but there is no WiFi network listed | firmware blob missing for your card | `lspci -nn | grep -i net` in a terminal, tell me the ID |
| "Install to internal disk" shows no disk | eMMC not exposed to the live kernel | `lsblk` in a terminal; if it is truly absent, flash over ADB instead (`adb shell su -c 'dd of=/dev/block/mmcblk0 bs=4M' < tinywin.img`) |
| Install finishes but it boots the USB again | firmware has the USB first in boot order | unplug the stick, or set boot order in the firmware setup (`Esc` → Setup) |
| Root filesystem is only 6 GB after install | `tinywin-growroot` did not run | `sudo tinywin-growroot` — it expands to the full disk immediately |

---

## What this changes compared to the earlier plan

* **No "install from a running system on the internal disk"** — that was never
  needed; the USB is the installer and the installed system at once (2.7 GB
  copy, no squashfs, no live-session trickery).
* **No ChromeOS to copy a browser from** — the phone/USB route above replaces it.
* **Firmware first.** Everything else is easy; being unable to boot a USB stick
  is the only real blocker, and it is fixable.
* The image you build now is verified to boot in UEFI, contains both
  bootloaders, and every tool it ships has the binaries it needs checked at
  build time (`ok every binary the tinywin-* tools need is present`).
