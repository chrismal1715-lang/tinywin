# Building tinywin on Android (Termux)

Everything below happens **on your Android device**. No PC, no loop devices, no
mounting partitions — the builder was rewritten so that the entire image is
produced with plain file writes (`truncate`, `sgdisk`, `mkfs`, `mtools`, `dd`).
That is exactly why it can run in Termux.

Total time: **about 15 minutes of typing, 5–40 minutes of building** (see the
speed note), and ~7 GB of free storage.

> **Your situation (OnePlus 9 Pro, LineageOS, rooted = arm64):** the Chromebook's
> firmware is already MrChromebox **UEFI Full ROM**, so the Chromebook itself is
> ready and needs nothing from ChromeOS. The only awkward part is that an arm64
> phone has to *emulate* x86_64 to build an amd64 image. Three ways, in the order
> I'd pick them:
>
> | Route | Time | Where |
> |---|---|---|
> | **GitHub Actions** (recommended) — `.github/workflows/build-image.yml` is in the kit; push, press Run, download the `.img.xz` artifact | **~12 min** | phone + a GitHub account |
> | **Any x86_64 PC** — boot a Debian/Ubuntu live USB, copy the kit over, run `osbuild/build.sh` | ~10 min | borrowed PC |
> | **The phone itself** — `tools/build-foreign-arch.sh` (qemu-user + binfmt, all automated) | **1.5–3 h**, hot and busy | phone only |
>
> §8 has the phone route in full; §8b has the GitHub one.

---

## 0. Read this first — the two things that decide the whole route

```bash
# in Termux
uname -m
```

| `uname -m` says | What it means | What to do |
|---|---|---|
| `x86_64` | Your Android device is a PC-architecture machine (this is the case on the Chromebook side of BABYMEGA, and on x86 Chromebooks/tablets generally). | **Follow this guide as written.** Everything runs natively and fast. |
| `aarch64` | A phone/tablet. You would be building an x86_64 disk image on an ARM CPU, so every package script has to run under CPU emulation. | Still possible, but 5–20× slower (1.5–4 hours) and fragile. Do it only if you have no other machine; see **§8**. |

The **safest place to build is a device whose internal disk you are *not* about
to overwrite** — a phone, a second Android device, or the Chromebook itself but
with the image written to a **USB stick**, never to its own eMMC (see §6).

---

## 1. Termux, root, storage

```bash
pkg update && pkg upgrade -y
pkg install -y proot-distro curl xz-utils tar coreutils
command -v su && su -c id          # must print uid=0(root)
df -h /data | tail -1              # need ~7 GB free
```

* `su -c id` printing `uid=0(root)` is the whole rooting requirement. **You do
  not need to remount anything, patch the kernel, or unlock anything further.**
* Why root at all? Two reasons only: the real `chroot` used to configure
  packages, and the final `dd` to the USB stick / eMMC. The image build itself
  needs no privileges.

---

## 2. Create the Debian 13 build environment

`proot-distro` downloads an official Debian rootfs. We use it as a
**real chroot** (you are rooted, so you get native speed instead of PRoot
emulation).

```bash
proot-distro install debian              # one download, no interaction
```

Then find where it actually landed — **proot-distro 5.x moved it**:

| proot-distro | rootfs path |
|---|---|
| 5.x (current) | `$PREFIX/var/lib/proot-distro/containers/debian/rootfs` |
| 4.x (older) | `$PREFIX/var/lib/proot-distro/installed-rootfs/debian` |

```bash
D=$PREFIX/var/lib/proot-distro/containers/debian/rootfs
[ -x $D/bin/bash ] || D=$PREFIX/var/lib/proot-distro/installed-rootfs/debian
ls $D/etc/debian_version               # expect 13.x (trixie)
```

`tools/find-chroot.sh` does this for you and prints the exact `D=` to use. If
`ls: cannot access .../installed-rootfs/debian/etc/debian_version` is what you
saw, nothing is broken — 5.x simply installed it somewhere else.

Nothing to edit; just confirm it says 13.x. If it says 12.x, run
`proot-distro remove debian` and reinstall after `pkg update` — an old cached
rootfs is the usual cause.

---

## 3. Enter the chroot with working /proc, /sys, /dev

`apt` and `debootstrap` misbehave without `/proc`, so mount them. **Do this from
a root shell** (this is the only place root is needed during the build):

```bash
su -
D=/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/debian

mkdir -p $D/proc $D/sys $D/dev $D/dev/pts
mount -t proc  proc  $D/proc
mount -t sysfs sys   $D/sys
mount --bind /dev    $D/dev
mount --bind /dev/pts $D/dev/pts
# Android has no /etc/resolv.conf for chroots; give it a DNS server
echo 'nameserver 1.1.1.1' > $D/etc/resolv.conf

chroot $D /bin/bash
```

You are now root inside Debian 13. Prompt is `root@localhost:/#`.

> If `mount` fails with *Permission denied*: your `su` is not a full root shell
> (some ROMs ship a restricted `su`). Try `su -mm` (Magisk) or the `tsu` package
> (`pkg install tsu`, then `tsu`), and if it still refuses, continue anyway —
> the build works with a warning, only `apt` is slower and noisier.
>
> To get out later: `exit` twice (chroot, then root shell).

---

## 4. Install the build tools inside the chroot

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  debootstrap gdisk mtools dosfstools e2fsprogs rsync python3 \
  xz-utils file ca-certificates grub-common grub-pc-bin grub-efi-amd64-bin

grub-mkimage --version
ls /usr/lib/grub/i386-pc/boot.img
```

Both of those must succeed — `boot.img` is what makes the legacy (SeaBIOS)
bootloader possible; without it the image is simply UEFI-only, which is fine
for this Chromebook.

Tool list, briefly: `debootstrap` builds the system, `sgdisk` writes the GPT,
`mtools` fills the FAT boot partition without mounting it, `dosfstools` +
`e2fsprogs` create the filesystems, `grub-*-bin` produce the two bootloaders.

---

## 5. Build the image

Put the kit somewhere the chroot can see. Easiest: copy it into your Termux home
first (from `/sdcard/Download/tinywin/` if you transferred it, or `git clone`),
then it is already visible inside the chroot at
`/data/data/com.termux/files/home/`:

```bash
# still inside the chroot
mkdir -p /build && cd /build
cp -a /data/data/com.termux/files/home/tinywin/. .

./osbuild/build.sh --size 6G --out /build/out --work /build/work
```

What you should see, in order:

```
=== [1] host checks ===                     ok tools present
=== [2] debootstrap trixie (amd64) ===      ok base system: ~120M
=== [3] base configuration ===
=== [4] packages (106 listed) ===           ok installed: ~1030 packages, 2.7G
=== [5] users, sudo, autologin ===           ok user tinywin with passwordless sudo
=== [6] overlay: desktop, tools, theme defaults ===
=== [7] services & first-boot behaviour ===  ok masked apt-daily.timer   (no auto-updaters)
=== [8] kernel, firmware, boot config ===    ok vmlinuz-6.12.x + initrd (51M)
=== [9] assemble disk image — loop-free ===  ok ESP: BOOTX64.EFI (3.8M)
                                             ok BIOS bootloader: MBR + core.img
                                             ok image assembled: 6.0G apparent / 2.9G on disk
=== [10] verify ===                          ok GPT is valid / ext4 / 55AA
=== [11] release artifacts ===               ok sha256: 0a76c716…
```

Two harmless warnings are normal: `unit not present, skipped: …` for optional
units, and `not root` (you *are* root, but inside some chroots `id` reports a
different real uid — the build doesn't care).

Useful flags if you want to change something:

```bash
./osbuild/build.sh --user bob --password hunter2 --root-password s3cret \
                   --hostname cb --timezone America/New_York
./osbuild/build.sh --no-compress         # skip .img.xz, ~4x faster, use this on ARM
./osbuild/build.sh --extra-pkgs "firefox-esr vlc"     # if you'd rather have them built in
```

`--no-compress` matters on Android: `xz -6 -T0` on a phone takes 20–60 minutes
and eats several GB of RAM. The raw `.img` is what you flash anyway.

**Speed note.** Debootstrap plus ~1000 packages on an x86_64 Android device:
**5–15 minutes**. On aarch64 with emulation: hours — go to §8.

---

## 6. Flash it — pick the safe target

### 6a. To a USB stick or SD card (recommended, zero risk)

Exit the chroot twice (`exit`, `exit`) so you are back in Termux, plugin the USB
stick, then:

```bash
su -
ls /dev/block/ | grep -E 'sd[a-z]$'            # your stick, e.g. sda
cat /sys/block/sda/size                        # sectors; 8GB stick = 15104512
ls -l /dev/block/by-name/ | grep -i sd         # sometimes a friendlier name
IMG=/data/data/com.termux/files/home/tinywin/out/tinywin-20261117.img
sha256sum $IMG                                 # must match the .sha256 file
dd if=$IMG of=/dev/block/sda bs=4M conv=fsync  # 6 GB → 3–6 min on USB 2.0
sync
```

Then `sync` again, unplug, and boot the Chromebook from it (press `Ctrl+L` or
`Esc`+`Ctrl+L` at the developer screen for the legacy path, `Ctrl+U`/boot menu
for the USB in UEFI mode — see `GUIDE.md` §3).

### 6b. To the internal eMMC (the real install)

**Do not `dd` to `mmcblk0` from the same device that is running Android on it.**
You would be overwriting the disk while the kernel is using it — the write
usually dies half-way and the machine boots nothing. Use one of these instead:

1. **Boot the USB stick, then run “Install tinywin to internal disk”** from the
   tinywin desktop (Start menu → System). It partitions the eMMC, copies the
   running system, installs both bootloaders, and grows the filesystem to the
   whole 64 GB. This is the supported route and the one `GUIDE.md` §6 documents.
2. **From a second device over ADB** while the Chromebook sits in the developer
   screen:
   ```bash
   adb shell su -c 'dd of=/dev/block/mmcblk0 bs=4M'  < tinywin-20261117.img
   ```
3. **From this device, but to the Chromebook's eMMC**, only if the eMMC is
   attached as a *separate* block device (e.g. an SD card reader) — check
   `cat /sys/block/mmcblk0/size` is 125829120 (64 GB in 512-byte sectors) and
   that `mount | grep mmcblk0` shows nothing mounted from it.

---

## 7. First boot on the Chromebook

1. Firmware: this machine supports both RW_LEGACY and UEFI Full ROM. **UEFI Full
   ROM is what the image is verified against** (`GUIDE.md` §3 has the routes and
   the write-protect requirements).
2. Boot. GRUB menu (2 s) → tinywin splash → auto-login as `tinywin`.
3. WiFi: click the tray network icon → pick your network → password.
4. Run **Updates** once (Start menu → System). First run pulls the newest
   packages; a reboot may be requested.
5. `passwd` in a terminal to change the default password.
6. Copy your browser over (from a USB stick or another device, via Thunar), then
   double-click it → **Install app** → it lands in the Start menu.

---

## 8. aarch64 phone only: build the amd64 image with qemu-user

You are emulating only the *target's* maintainer scripts — the build tools
themselves (debootstrap, sgdisk, mtools, grub) run natively on the phone's ARM64
core. That is why this finishes in hours rather than days.

```bash
# in Termux
pkg install proot-distro
su -c id                     # must print uid=0(root)
cd ~/tinywin
./tools/build-foreign-arch.sh --out /data/local/tmp/tinywin-out
```

What the script does, step by step (read it — it is 120 lines):

1. installs an **arm64 Debian 13 chroot** via `proot-distro install debian`
   (helper only; the image being built is amd64),
2. as root, bind-mounts `/proc`, `/sys`, `/dev` into it and mounts
   `binfmt_misc` — the kernel feature that lets an arm64 kernel execute an
   x86_64 ELF by handing it to `qemu-x86_64-static`,
3. installs `debootstrap`, `gdisk`, `mtools`, `dosfstools`, `e2fsprogs`,
   `grub-pc-bin`, `grub-efi-amd64-bin`, `qemu-user-static`, `binfmt-support`
   **inside** that chroot,
4. enables the `qemu-x86_64` binfmt handler and proves it works by running an
   amd64 `/bin/true`,
5. runs `./osbuild/build.sh --arch amd64 --no-compress` with the kit bind-mounted
   at `/kit` and the output at `/out`.

Practical notes for a Snapdragon 888:

* **Plug the charger in.** Hours of 8-core emulation drains fast and throttles.
* `termux-wake-lock` in a second Termux session, and keep the screen off but the
  device awake — Android will otherwise kill the build.
* `--no-compress` is not optional here: `xz -T0` would add 20–60 minutes.
* Expect `debootstrap` (~20–40 min) to be the slowest phase; package postinst
  scripts are the second. Nothing is wrong if a single package sits on
  "Setting up …" for ten minutes.
* Free space: ~9 GB on `/data` (chroot 1.5 GB + rootfs 2.7 GB + image 2.9 GB).
* Time: **1.5–3 h**. If it fails at `debootstrap` with `Exec format error`, your
  kernel lacks `binfmt_misc` — use §8b instead.

## 8b. Any phone: let GitHub's x86_64 runner do it (~15 min, no emulation)

This is the least-effort route on an arm64 phone: someone else's x86_64 CPU does
the work, and you get a finished `.img.xz` to download.

**Make the repo public, not private.** Private repos get 500 MB of Actions
storage and the artifact is ~730 MB (the workflow will fail at upload);
public repos have no such limit, and everything in the kit is just build
scripts — the default password is documented anyway.

```bash
# in Termux, in the tinywin folder
pkg install gh git
gh auth login                 # GitHub.com -> HTTPS -> paste a token (gh guides you)
gh repo create tinywin --public --source=. --push
gh workflow run build-image.yml
sleep 5; gh run list --limit 1
```

`gh` will show the run; wait for it (`gh run watch`) — about 12 minutes, most of
it `xz` compressing. When it is green:

```bash
gh run download --name tinywin-image      # -> tinywin-YYYYMMDD.img.xz + .sha256
sha256sum -c tinywin-*.img.sha256
ls -lh tinywin-*.img.xz                   # ~730 MB
```

Then flash it straight through the decompressor (USB stick in OTG):

```bash
su -                                        # or: tsu
xz -dc tinywin-*.img.xz > /dev/block/sda    # CONFIRM sda is the stick first!
sync
```

Or, without `gh`: repo → **Actions** → *Build tinywin image* → **Run workflow**,
then download the `tinywin-image` artifact from the run page with any browser.

### Why the workflow uses a Debian container

The runner is Ubuntu 24.04, whose `debootstrap` predates Debian 13 and cannot
bootstrap trixie. The workflow therefore runs the build inside `debian:trixie`
(where `debootstrap`, `grub-pc-bin`, `grub-efi-amd64-bin`, `mtools`, `sgdisk`
are all the same versions the reference build used) on a bind-mounted checkout:

```yaml
docker run --rm -v "$PWD":/kit -v "$PWD/out":/out -w /kit \
  -e SIZE="$SIZE" debian:trixie bash -c 'apt-get install …; ./osbuild/build.sh …'
```

Note what it does *not* ask for: `--privileged`, loop devices, or mounts. The
loop-free assembly is what makes this work inside a plain container.

`out/build.log`, the `.img.xz`, its `.sha256` and (on failure) the log are all
attached to the run as artifacts.

## 9. When something goes wrong

| Symptom in Termux | Cause | Fix |
|---|---|---|
| `debootstrap: command not found` | you are in Termux, not the chroot | `su -` → `chroot $D /bin/bash` (§3) |
| `ls: cannot access '.../installed-rootfs/debian/etc/debian_version'` | proot-distro 5.x stores containers in `containers/debian/rootfs` | use the path in §2, or `bash tools/find-chroot.sh` |
| `/data/data/com.termux/files/usr/bin/su` → `Permission denied` | Termux's own `su` shim shadows the system one | `pkg install tsu`, then use `tsu` instead of `su` |
| `chroot: failed to run command '/bin/bash': Permission denied` | not real root, or PRoot instead of chroot | use `tsu` / `/system/bin/su`; PRoot cannot chroot into a second rootfs |
| `mount: /proc: permission denied` | restricted `su` | `su -mm`, then continue (§3 note) |
| `sgdisk: command not found` | tools installed outside the chroot | §4 |
| `W: Failed to fetch …` during debootstrap | DNS | `echo 'nameserver 1.1.1.1' > $D/etc/resolv.conf` and retry |
| `No space left on device` in `/build` | image is 2.9 GB + rootfs 2.7 GB + work files | build in `/data/local/tmp` (needs ~7 GB) or use `--size 4G` |
| `dd: /dev/block/sda: Permission denied` | not root | `su -` before `dd` |
| Chromebook shows `GRUB loading…` then nothing | legacy/SeaBIOS path is unverified | switch to UEFI Full ROM, or ask for the syslinux variant |
| Chromebook boots to the GRUB menu but the kernel panics | USB written from the `.xz` by mistake | write the raw `.img`, or `xz -dc tinywin.img.xz > /dev/block/sda` |

---

## 10. Cleaning up (get your space back)

```bash
# inside the chroot
exit
# as root
umount $D/dev/pts $D/dev $D/sys $D/proc 2>/dev/null
rm -rf /data/local/tmp/tinywin-build /build/out/*.img
su -c 'du -sh $D /data/data/com.termux/files/home/tinywin/out'
```

Keep the `.img` if you still need to flash it; delete the work directory (2.7 GB)
and the chroot (~1.5 GB) once the Chromebook boots.

---

## What this route does *not* need

* `losetup`, `mount -o loop`, `parted` on loop devices — the builder never
  mounts a partition. (This was the single change that made Android possible.)
* a PC, an SD-card adapter, or a cross-compiler.
* `qemu-system-x86_64` — that is only for testing the image on a desktop Linux
  box (`tools/qemu-test.sh`), and it is optional.
