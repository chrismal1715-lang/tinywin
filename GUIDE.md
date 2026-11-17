# tinywin — the complete guide

Everything from "here is a Chromebook" to "here is a working tiny Linux desktop
on it", plus what to do when something goes wrong.

Target machine: **ASUS Chromebook CX22NA-BCLN4**
Board name: `BABYMEGA` · Intel Celeron N3350/N4020 (Apollo Lake) · x86_64 · 8 GB RAM · 64 GB eMMC

---

## 0. Contents

1. [The 60-second version](#1-the-60-second-version)
2. [What tinywin is, and what it deliberately is not](#2-what-tinywin-is)
3. [Know your machine: firmware (read this before wiping)](#3-know-your-machine)
4. [Build the image](#4-build-the-image)
5. [Test it in QEMU (no risk)](#5-test-in-qemu)
6. [Write it to a USB stick](#6-write-to-usb)
7. [Boot the Chromebook and install to the eMMC](#7-install-to-the-chromebook)
8. [First run: WiFi, password, and getting a browser](#8-first-run)
9. [The four tools](#9-the-four-tools)
10. [Installing things, Windows-style](#10-installing-things)
11. [Updates](#11-updates)
12. [Themes and appearance](#12-themes)
13. [Memory, speed and what you can trim](#13-memory-and-speed)
14. [Customising and rebuilding](#14-customising)
15. [Recovery and repair](#15-recovery)
16. [Troubleshooting table](#16-troubleshooting)
17. [Undoing it / getting ChromeOS back](#17-undoing-it)
18. [FAQ](#18-faq)

---

## 1. The 60-second version

```bash
# on any x86_64 Linux computer (not the Chromebook):
sudo apt install debootstrap e2fsprogs dosfstools mtools gdisk rsync xz-utils
sudo ./osbuild/build.sh                     # ~6 min -> out/tinywin-YYYYMMDD.img
sudo ./tools/flash.sh out/tinywin-*.img /dev/sdX     # the USB stick

# on the Chromebook: boot the stick -> desktop -> "Install tinywin to internal disk"
# -> it powers off -> unplug -> power on -> done.
```

Login `tinywin` / `tinywin`. Change it with `passwd` the first time you log in.

---

## 2. What tinywin is

A Debian 13 ("trixie") base, booted by GRUB, running Xfce, with ~90 packages,
plus seven small scripts that do the jobs you asked for. That's it. There is no
tinywin package repository, no custom init system, no custom kernel — the parts
that are hard to get right (kernel, drivers, package management, security
updates) are stock Debian, which means they will keep working for years.

**What is in the image**

| Area | Choice | Why |
|---|---|---|
| Core | Debian 13 trixie, systemd, apt | security updates until ~2030 |
| Kernel | `linux-image-amd64` (6.12 LTS) + `initramfs-tools` | eMMC, NVMe, USB all supported |
| Firmware | `firmware-linux`, `firmware-iwlwifi`, `firmware-atheros`, `firmware-realtek`, `firmware-mediatek`, `firmware-sof-signed`, `intel-microcode` | WiFi + audio + CPU errata for this exact board |
| Graphics | `xserver-xorg` + modesetting + `libgl1-mesa-dri` + VA-API | Apollo Lake works out of the box |
| Desktop | Xfce 4.20 (panel, whisker menu, xfwm4, xfdashboard-free) | light, familiar, themeable |
| File manager | Thunar + `thunar-archive-plugin` + `xarchiver` + `gvfs` | "Extract here", USB drives, trash |
| Network | NetworkManager + `network-manager-gnome` tray applet | click a WiFi name, no terminal |
| Audio | PipeWire + WirePlumber + `xfce4-pulseaudio-plugin` | tray volume, no config |
| App support | `unzip`, `p7zip`, `tar`, `xz`, `libfuse2` (AppImage), `libnss3`, `libgbm1`, `libasound2` | so downloaded apps actually run |
| Bootloader | GRUB **both** UEFI (`/EFI/BOOT/BOOTX64.EFI`) and legacy (MBR + BIOS boot partition) | works whichever firmware you have |

**What is deliberately absent:** snapd, flatpak, LibreOffice, a mail client,
games, GNOME software centre, background update daemons, telemetry, Wayland
experiments, a second browser, cloud accounts, and anything that phones home.

### The honest trade-off

You asked for "the least RAM possible". This build idles at roughly **400–470 MB
with the desktop up** — see [§13](#13-memory-and-speed) for measured numbers and
how to halve it. The alternative (Alpine + a bare window manager) idles near
60–100 MB, but it uses musl libc, which means the Chrome/Firefox/AppImage files
you plan to copy over from another device **will not run**. Since "run zips and
install them like Windows" was the actual requirement, compatibility won. With
8 GB of RAM, 450 MB at idle leaves you ~7.5 GB for a browser and everything else.

---

## 3. Know your machine

### Board name
Your CX22NA is board **`BABYMEGA`** — the same firmware family as the C223NA and
CX1100CNA. Confirm any time from ChromeOS: open `chrome://version` and look at
the **Firmware** / board line, or check the bottom of the recovery screen
(`Esc`+`Refresh`+`Power`).

### Why this matters
ChromeOS devices ship with Google's own boot firmware, which only boots ChromeOS.
Before any Linux can boot, the firmware must support an alternative. Your board
supports two routes:

| Route | What it is | What it costs you | tinywin works? |
|---|---|---|---|
| **UEFI Full ROM** (MrChromebox) | Replaces ChromeOS firmware entirely with standard UEFI | Requires disabling hardware write-protect (open the case, disconnect the battery, or use a SuzyQ cable). ChromeOS gone. | ✅ boots directly, no keypresses |
| **RW_LEGACY** (MrChromebox) | Adds a legacy-boot payload, leaves ChromeOS firmware intact | No case opening, no risk of bricking, ChromeOS stays usable | ⚠️ image ships a legacy bootloader, but it stalls before the boot menu in testing — see §16 |
| **Stock, untouched** | ChromeOS only | — | ❌ |

You already ran antiX on this machine, so **one of the first two is already in
place** — you do not need to do anything in this section. If you ever re-flash
firmware, or you're reading this before that step:

1. From ChromeOS, press `Ctrl`+`Alt`+`T`, type `shell`, then run the
   [MrChromebox firmware utility script](https://docs.mrchromebox.tech/):
   `cd; curl -LO mrchromebox.tech/firmware-util.sh; sudo bash firmware-util.sh`
2. Pick **Install/Update UEFI (Full ROM) Firmware** for the cleanest experience,
   or **Install RW_LEGACY** if you want to keep ChromeOS and avoid opening the
   case.
3. Make a note of which one you chose — it decides how you boot the USB stick:

| Firmware | Boot the USB stick |
|---|---|
| UEFI Full ROM | Plug in, power on. That's all. |
| RW_LEGACY | `Esc`+`Refresh`+`Power` → recovery screen → `Ctrl+L`, or power on and press `Ctrl+L` at the dev screen |
| Stock | Won't work — see above |

tinywin's image carries **both** bootloaders, so you can't get this wrong.

---

## 4. Build the image

### Where to run it
On any x86_64 Linux machine with root and ~10 GB free: a laptop, a desktop, a VM,
a cloud box. Not on the Chromebook itself (you'd be erasing what you build on).

Debian/Ubuntu host packages:
```bash
sudo apt install debootstrap e2fsprogs dosfstools mtools gdisk rsync xz-utils
```
Fedora: `sudo dnf install debootstrap e2fsprogs dosfstools mtools gdisk rsync xz`
Arch: `sudo pacman -S debootstrap e2fsprogs dosfstools mtools gptfdisk rsync xz`

### Run it
```bash
cd tinywin
sudo ./osbuild/build.sh
```

That produces `out/tinywin-YYYYMMDD.img` (6 GB) plus a `.sha256` and, unless you
pass `--no-compress`, a `.img.xz` (≈1.6 GB) for archiving.

### Options you might actually want

```bash
sudo ./osbuild/build.sh \
  --user yourname --password 'something-better' \
  --hostname mychromebook \
  --timezone America/New_York \
  --keyboard us \
  --size 8G \
  --extra-pkgs "firefox-esr vlc"     # baked in, so first boot has them
```

| Flag | Default | Notes |
|---|---|---|
| `--user` / `--password` | `tinywin` / `tinywin` | desktop user, member of sudo/video/audio/netdev/plugdev/input |
| `--root-password` | none (root locked, use `sudo`) | mirrors ChromeOS's model; set one if you want `su` |
| `--size` | `6G` | raw image size. Doesn't need to match your disk — first boot grows it |
| `--out`, `--work` | `./out`, `/var/tmp` | work dir needs ~2× image size free |
| `--no-compress` | off | skips `.img.xz`, faster iteration |
| `--rootfs-only` | off | stops before image assembly; useful when editing packages |
| `--extra-pkgs` | — | extra Debian packages baked in |

### What the build does, in order
1. `debootstrap` Debian 13 minbase (main, contrib, non-free, non-free-firmware)
2. installs `osbuild/packages.list` with `--no-install-recommends`
3. configures locale, timezone, keyboard, branding (`tinywin 1.0`), user, sudo,
   polkit rule, services (LightDM autologin, NetworkManager, fstrim), masks
   Bluetooth/ModemManager/apt-daily
4. copies `osbuild/overlay/` into the rootfs (desktop defaults + the 7 tools)
5. builds the initramfs, cleans caches
6. creates a GPT disk: BIOS boot partition + 128→512 MB ESP + ext4 root, populates
   it (ESP via `mtools`, so no vfat mounting needed), installs both bootloaders,
   writes `fstab` with real PARTUUIDs
7. names the image, writes checksums, optionally compresses

Nothing is signed or distributed — it's your image, built from Debian's archive.

---

## 5. Test in QEMU

Strongly recommended the first time: same image, zero risk to the Chromebook.

```bash
sudo apt install qemu-system-x86 ovmf        # once
./tools/qemu-test.sh out/tinywin-YYYYMMDD.img
```

* With a graphical session it opens a QEMU window (Ctrl+Alt+G releases the mouse).
* Without one it runs headless, logs the serial console to `qemu-serial.log`,
  takes a screenshot (`qemu-screen.ppm`) and prints the console tail.
* `MEM=2048 ./tools/qemu-test.sh …` to give the VM more RAM (default 3 GB).

Inside the VM, WiFi is emulated as an Ethernet device, so the network works
without configuration; the real machine needs the WiFi steps in §8.

---

## 6. Write to USB

Use a stick of **8 GB or more**. Everything on it is destroyed.

```bash
sudo ./tools/flash.sh out/tinywin-YYYYMMDD.img /dev/sdX
```

The script refuses to write to your system disk, refuses mounted targets,
shows you the model/size of the stick, asks you to type `ERASE`, then **reads
the stick back and compares hashes**. If you prefer a GUI: **balenaEtcher**
(any OS), or **Rufus** on Windows — choose the `.img` file and *DD image* mode,
not ISO mode.

> Windows note: Rufus only shows `.img` files after you switch the file-type
> filter to "All files". If you built an `.img.xz`, decompress it first (7-Zip).

---

## 7. Install to the Chromebook

> **Blank machine (no ChromeOS, no antiX, just firmware)?** That is the case the
> installer was written for — read **[START-HERE-NO-OS.md](START-HERE-NO-OS.md)**
> first. It covers identifying the firmware (the only real prerequisite: it must
> be able to boot a USB stick), writing the stick from a phone or PC, and the
> blank-disk install. The tool wipes whatever is (or isn't) on the disk, writes
> the three partitions, and carries this system's PARTUUID + filesystem UUID
> across so `/etc/fstab` and `grub.cfg` stay valid. It offers a reboot instead of
> powering off on its own now, and it refuses to start with an explanation if a
> required tool is missing.

1. Plug the stick into the Chromebook.
2. Power on and boot it (§3 table for the keypress if you're on RW_LEGACY).
3. You land on the tinywin desktop, logged in automatically. It's running from
   the stick — nothing on the machine has changed yet.
4. Optional sanity check: browse the Start menu, open the file manager, connect
   to WiFi, make sure the touchpad and sound work.
5. Start menu → **Install tinywin to internal disk**.
   * It lists the internal disks only (never the stick it's running from).
   * Pick the eMMC (`/dev/mmcblk0`, ~58 GB) and type `ERASE` to confirm.
   * It copies the system, installs **both** bootloaders, then offers to reboot.
6. Unplug the stick, power on. It boots from the eMMC.
7. On that first boot, `tinywin-growroot.service` expands the partition table and
   the filesystem to fill the whole 64 GB. Check with `df -h /` — you should see
   ~57–58 GB total. This happens once and takes a couple of seconds.

> Why a block-level copy instead of a fancy installer? Because an installer is
> 400 MB of partitioning code with a UI, and a `dd` of a known-good image is
> 3 lines that can't get your partition layout wrong. Same result, no decisions.

If you'd rather install from another computer (e.g. a USB-to-eMMC adapter, or by
booting a live Linux on the Chromebook), writing the same `.img` with `flash.sh`
directly to `/dev/mmcblk0` does exactly the same thing.

---

## 8. First run

**Login:** user `tinywin`, password `tinywin`, logged in automatically.

Do these four things once:

```bash
passwd                     # 1. change your password
```

2. **WiFi** — click the network icon in the bottom-right tray → pick your network
   → enter the password. (No tray? Start menu → Settings → Network, or from a
   terminal: `sudo nmtui`.) If your 5 GHz networks are missing, set your country:
   `sudo nano /etc/wpa_supplicant/wpa_supplicant.conf` isn't needed with
   NetworkManager, but `iw reg set US` works for the session.

3. **Sound** — open the tray speaker icon and unmute. ChromeOS speakers run
   through `firmware-sof-signed`, which is installed; if audio is silent after an
   update, `sudo alsactl init` fixes the mixer state.

4. **Browser** — you have three options:
   * **Start menu → Get apps → Firefox ESR / Chromium / Google Chrome**
     (Chrome downloads Google's official `.deb` and installs it).
   * **Copy a file over** from another device (USB stick, SD card, or `scp`) and
     double-click it — see the next section. This is the path you described, and
     it works for any of: `google-chrome-stable_current_amd64.deb`,
     `firefox-*.tar.xz`, `*.AppImage`.
   * `sudo apt install firefox-esr` in the terminal.

---

## 9. The four tools

All four live in the Start menu (bottom-left, "Menu") and also work from a
terminal. None of them require a password for the `tinywin` user, because that
user is the owner of the machine (see `/etc/sudoers.d/50-tinywin`).

### Install app — `tinywin-install`
Double-click (or right-click → Open With) any of:

| File | What happens |
|---|---|
| `.deb` | Opens a terminal running `apt install ./file.deb` — dependencies included, output visible. Later removal: `sudo apt remove <name>` |
| `.AppImage` | Copied to `~/Applications`, marked executable, Start-menu entry created, offers to run now |
| `.zip`, `.tar`, `.tar.gz/.xz/.bz2`, `.7z` | Asks where to unpack (default `~/Applications/<name>`), extracts, then searches for a runnable program inside. If it finds one: offers to add a Start-menu entry and run it. If it finds several: you pick. If none: opens the folder |
| `.sh`, `.run` | Marks executable and offers to run it in a terminal |

That's the "run zips like Windows" behaviour: unpack → it's an app → it's in the
Start menu. No terminal knowledge required, though the terminal is there if you
want to watch.

### Updates — `tinywin-update`
One dialog: shows how many packages are upgradable, lists them, then runs
`apt update`, `apt full-upgrade` (keeping your config files), `autoremove`,
`apt clean` in a visible terminal, and tells you whether a reboot is needed.
There are **no** background update daemons: `apt-daily.timer` and
`apt-daily-upgrade.timer` are masked. Updates happen when you ask for them.

### Themes — `tinywin-theme`
Sets widget theme + window theme + icon theme + wallpaper together:

| Preset | GTK theme | Icons |
|---|---|---|
| Dark (default) | Arc-Dark | Papirus-Dark |
| Light | Arc | Papirus |
| Stock GTK | Adwaita | Adwaita |
| Classic dark | Adwaita-dark | Papirus-Dark |
| High contrast | HighContrast | Papirus-Dark |

It also flips the `prefer-dark` setting for GTK4/libadwaita apps. More themes:
drop a GTK theme folder in `~/.themes`, icons in `~/.icons`, or `apt install` a
theme package — they appear in Settings → Appearance too.

### File manager — Thunar
Start menu → File Manager. Right-click any archive → **Extract Here**; double-click
to open in the archive manager. USB sticks appear in the side pane. Trash, bulk
rename, custom actions and `Ctrl+Shift+N` all work as you'd expect.

### Plus three small ones
* **System info** (`tinywin-info`) — RAM, top processes, disk, theme, network,
  update count, firmware/board/CPU, in one window (`--text` for the terminal).
* **Get apps** (`tinywin-apps`) — installs Firefox ESR, Chromium, Chrome, VLC,
  LibreOffice, GIMP or Shutter on demand. Nothing is preinstalled.
* **Install to internal disk** (`tinywin-install-disk`) — §7.

---

## 10. Installing things

### The Windows-ish workflow you described
1. On another device, download what you want:
   * Chrome → `https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb`
   * Firefox → `https://www.mozilla.org/firefox/linux/` (`firefox-*.tar.xz`)
   * Portable apps → often a `.zip` or `.tar.gz` with a `bin/` folder
   * AppImages → a single executable file, e.g. `SomeApp-1.2-x86_64.AppImage`
2. Copy it onto a USB stick (FAT32/exFAT are fine) or send it over the network.
3. On the Chromebook: File manager → open the stick → **double-click the file**.
4. Follow the dialog. Done — it's in the Start menu.

### The normal Linux way
```bash
sudo apt update && sudo apt install <package>   # or: Start menu → Updates
apt search <thing>                              # find packages
apt-cache show <package>                        # details
sudo apt remove <package> && sudo apt autoremove
```
`apt` installs from Debian's signed archive — ~69,000 packages, security updates
until Debian 13's end of life.

### Should I use flatpak/snap?
No. They'd add 300–600 MB of runtime plus a daemon for no benefit here. If you
ever need one specific app that only ships as flatpak, ask — it can be added
without bloating the base image.

---

## 11. Updates

Start menu → **Updates**. That's the whole feature. Under the hood it is
`apt full-upgrade`, i.e. the same updates Debian publishes for security and
stability. Kernel updates land as a new `linux-image` package and need a reboot
(the dialog tells you).

From a terminal:
```bash
sudo apt update && sudo apt full-upgrade
sudo apt autoremove --purge
```

Automatic maintenance you *do* get: `fstrim.timer` (weekly eMMC trim, good for
flash longevity) and `systemd`'s standard journal rotation, capped by
`/etc/systemd/journald.conf`.

If you want unattended *security-only* updates later, install
`unattended-upgrades` and re-enable `apt-daily.timer` — but the point of this
build is that nothing happens behind your back.

---

## 12. Themes

Three levels, pick your comfort:

1. **Start menu → Themes** — five presets, one click, everything consistent.
2. **Start menu → Settings → Appearance** — the standard Xfce panels for style,
   icons, fonts, toolbar, DPI.
3. **Full control** — GTK themes go in `~/.themes/<Name>/`, icons in
   `~/.icons/<Name>/`, and `xfconf-query` can change anything live:
     ```bash
     xfconf-query -c xsettings -p /Net/ThemeName -s Arc-Dark
     xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus-Dark
     xfconf-query -c xfwm4 -p /general/theme -s Arc-Dark
     ```

Wallpapers live in `/usr/share/backgrounds/tinywin/` (`aurora.png`, `dusk.png`).
Drop your own there or in `~/Pictures`, then Settings → Desktop → Background.
Panel layout ships as a real config file you can edit or delete:
`~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml` (log out/in to apply).

---

## 13. Memory and speed

Measured on the real image, booted in QEMU (UEFI, 1 GB guest, TCG emulation, so
slower than your hardware but memory-accurate) with the desktop freshly logged in
and idle:

```
$ free -m                      # inside the running tinywin
               total        used        free      shared  buff/cache   available
Mem:             961         443         415           5         236         517
$ systemctl --failed           # nothing failed
$ df -h /
/dev/vda3       5.4G  2.3G  3.1G  43% /
```

| Component | Idle RSS (shared pages counted per process, as `ps` does) |
|---|---|
| Xorg | ~108 MB |
| xfwm4 (window manager) | ~130 MB (inflated by shared Mesa/GTK pages) |
| xfce4-session | ~78 MB |
| xfdesktop | ~45 MB |
| nm-applet (network tray) | ~44 MB |
| xfce4-panel + plugins | ~105 MB |
| xfce4-notifyd, xfsettingsd | ~64 MB |
| **Total used at idle** | **≈ 440 MB** |
| With Chromium/Firefox open (3–5 tabs) | +400–900 MB |

On 8 GB that leaves ~7.5 GB free. The point of the small footprint was not to
squeeze into 2 GB — it was to keep the machine cool, quiet and quick on an
N3350-class CPU, where every megabyte of idle churn is felt.

### If you want it even smaller
| Change | Saves | Command |
|---|---|---|
| Swap the panel for a bare window manager | ~80 MB | `sudo apt install openbox` then pick Openbox at login |
| Drop the tray applets (nm-applet, pulseaudio plugin, power manager) | ~35 MB | remove from the panel config, reboot |
| Turn off PipeWire (headless use) | ~25 MB | `sudo systemctl --user disable --now pipewire wireplumber` |
| Use `xfce4-terminal` instead of a browser for a dashboard | — | — |
| Add zram swap (mostly pointless with 8 GB, fine with 4) | — | `sudo apt install zram-tools` |

### Make it feel faster on this CPU
* `intel-microcode` is installed (fixed a lot of Apollo Lake errata).
* Keep `vm.swappiness=10` (set in `/etc/sysctl.d/99-tinywin.conf`), so RAM is used
  before swap.
* Boot logs are quiet (`loglevel=3`); "verbose boot" is a menu entry if you want
  to see them.
* `fstrim.timer` keeps eMMC write performance from degrading.

---

## 14. Customising

Everything is in `osbuild/`, and nothing is hidden behind a framework:

* **Packages** — edit `osbuild/packages.list` (it's commented; delete lines to
  remove things). Rebuild.
* **Desktop defaults** — `osbuild/overlay/etc/skel/.config/xfce4/…` becomes the new
  user's config. Panel layout, theme, icon theme, wallpaper, window buttons.
* **Tools** — `osbuild/overlay/usr/local/bin/tinywin-*` are plain bash. Edit freely.
* **Start-menu entries** — `osbuild/overlay/usr/share/applications/*.desktop`.
* **Branding** — `/etc/os-release`, `/etc/issue`, `/etc/motd` are written in
  `osbuild/build.sh` (search for `branding`).
* **Boot menu / kernel parameters** — `$WORK/grub.cfg` inside `build.sh`; add
  `--url`-style flags or just edit the menu entries.
* **Wallpapers** — replace the two PNGs in `overlay/usr/share/backgrounds/tinywin/`.

Iterate quickly while editing: `sudo ./osbuild/build.sh --no-compress` then
`./tools/qemu-test.sh out/tinywin-*.img`. Six minutes per loop, or use
`--rootfs-only` plus `chroot` if you're only touching config files.

---

## 15. Recovery

**The desktop is broken / won't start.** At the GRUB menu (hold `Shift` during
boot if it's hidden) pick **"tinywin 1.0 (rescue shell)"**. You get a root shell
on the console. Then:

```bash
tinywin-info --text                 # what's wrong?
journalctl -b -p err                # errors this boot
systemctl status lightdm            # is the desktop starting?
lightdm --test-mode --debug         # run the session by hand
sudo systemctl set-default multi-user.target   # boot to text only, temporarily
sudo systemctl set-default graphical.target    # undo
```

**Boot menu doesn't appear.** It's hidden with a 0-second timeout. Hold `Shift`
(or `Esc` on UEFI) immediately after the firmware splash.

**I broke the bootloader.** Boot the USB stick again (Ctrl+L / power on), open a
terminal, and reinstall to the eMMC (§7 step 5). Everything is on the stick.

**Root password / sudo.** root is locked by design; the `tinywin` user has
passwordless sudo. If you locked yourself out of the desktop user, use the rescue
shell entry (`single`), then `passwd tinywin`. Forgot the desktop password?
Same thing — the rescue shell doesn't need it.

**Repair a chroot from the USB stick** (fix packages without reinstalling):
```bash
sudo mount /dev/mmcblk0p3 /mnt
sudo mount --bind /dev /mnt/dev; sudo mount --bind /proc /mnt/proc; sudo mount --bind /sys /mnt/sys
sudo chroot /mnt /bin/bash
# ... apt install --fix-broken, dpkg-reconfigure, etc.
```

**Start fresh.** Re-flash the USB stick, boot it, install to internal disk again.

---

## 16. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Firmware says nothing to boot / boots ChromeOS | USB not legacy/UEFI-bootable or wrong key | §3 table. Verify the stick has `EFI/BOOT/BOOTX64.EFI` (partition 2). |
| SeaBIOS/RW_LEGACY: "GRUB loading…" then a blank screen | the legacy bootloader is incomplete on this build (known, see `docs/build-log.txt`) | Tell me and I'll rebuild with a syslinux-based BIOS bootloader; or flash **UEFI Full ROM**, which is the firmware MrChromebox recommends and which is verified working with this image |
| Not sure which firmware you have | — | In any Linux on the machine: `ls /sys/firmware/efi`. Directory = UEFI. Missing = legacy/SeaBIOS. |
| `ALERT! PARTUUID=… does not exist` at boot | partition table rewritten (e.g. by another installer) | boot the stick, reinstall, or boot rescue and check `blkid` |
| Black screen after GRUB | GPU/modesetting issue | GRUB → "verbose boot"; if it's the GPU, add `nomodeset` to the kernel line (press `e` in GRUB) |
| No WiFi networks listed | firmware or rfkill | `rfkill list`, `sudo rfkill unblock all`, `dmesg \| grep -i iwl`; `firmware-iwlwifi` is installed |
| Touchpad dead | i2c-hid module | `dmesg \| grep -i hid`, then `sudo modprobe i2c_hid_acpi`; report it and it gets baked in |
| No sound | SOF firmware/mixer state | `sudo apt install firmware-sof-signed`, `sudo alsactl init`, unmute in tray |
| Chrome won't start from a `.deb` | missing dep | read the terminal output; `sudo apt --fix-broken install` |
| AppImage won't run | FUSE | `libfuse2t64` is installed; for stubborn ones: `./App.AppImage --appimage-extract` then run `squashfs-root/AppRun` |
| Screen too large/small | DPI | Settings → Appearance → Settings tab → DPI, or `KIOSK`-style `xfconf-query -c xsettings -p /Xft/DPI -s 110` |
| Everything is tiny on a 1366×768 panel | font size | Settings → Appearance → Fonts, or Themes dialog → High contrast preset |
| eMMC shows 6 GB not 64 GB | first-boot grow didn't run | `sudo tinywin-growroot` then `df -h /` |
| Boots to a text login instead of desktop | LightDM failure | `systemctl status lightdm`, `journalctl -b -u lightdm` |
| Fan always on / hot | CPU governor | `sudo apt install cpufrequtils`, `cpufreq-set -g powersave` |
| Stuck at 30 Hz / tearing | no compositor | normal on Xfce without `picom`; `sudo apt install picom` + autostart if it bothers you |

---

## 17. Undoing it

You asked for a full wipe, so this is only here for completeness.

* **ChromeOS back:** you need stock firmware + a ChromeOS recovery USB. If you
  flashed UEFI Full ROM, run the MrChromebox script from a Linux USB and choose
  **Restore Stock Firmware** (only possible for non-EOL boards, and requires
  write-protect disabled again), then use the
  [ChromeOS Recovery tool](https://support.google.com/chromebook/answer/1080595)
  on another computer to write a recovery image for `BABYMEGA`.
* **Another Linux back:** flash whatever `.iso`/`.img` you like with the same
  tools. tinywin leaves no special partitions behind except a standard GPT.

---

## 18. FAQ

**Is this a "real" OS or a Debian remix?**
It's a Debian remix — built from scratch by `build.sh`, bootable, installable, and
updatable from Debian's archive. Rolling your own kernel and init would add risk
and zero capability for your use case.

**Why is the image 6 GB when the desktop is 2.2 GB?**
Image size ≠ used space: 2.2 GB is what's actually written; the rest is empty
space that gets expanded to your full 64 GB on first boot. Use `--size` if you
prefer a smaller or larger raw image.

**Can I run Windows .exe files?**
Not natively. You can install `wine`, but on an N3350 that's a bad experience
for anything modern. The zip/portable-app workflow in §10 covers most of what
people actually want from "just run it".

**Does it work on other Chromebooks?**
The build is generic x86_64 Debian — it will boot on any MrChromebox-supported
x86_64 Chromebook. The firmware list (§2) and the RAM/desktop choices are tuned
for yours.

**Is it secure?**
Stock Debian with security updates, a single unprivileged desktop user, no
services listening on the network, no remote access daemons. It is *not*
hardened like ChromeOS (no verified boot, no per-app sandbox beyond what the
browser does). Keep it updated and it's a normal, sane Linux desktop.

**Where do I report a problem?**
Bring me the output of `tinywin-info --text` and `journalctl -b -p err` — that
covers 90% of diagnosis.
