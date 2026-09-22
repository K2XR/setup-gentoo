# setup-gentoo.sh

> ⚠️ **Vibe-coded, use at your own risk.** This script was written fast with AI help, not carefully engineered. It works on my machines, but it can absolutely eat your disk or break on weird hardware. Read it before running.

A `setup-alpine`-style installer for Gentoo (OpenRC): asks a few questions, then does the boring part for you.

## What it does

- Asks hostname, keymap (`us`), timezone (`America/New_York`), locale (`en_US.UTF-8`), extra user + passwords — Enter accepts the `[default]`
- Auto-detects UEFI/BIOS, partitions and formats the disk you pick (asks `yes` before wiping)
- Installs latest stage3 (OpenRC, amd64), `gentoo-kernel-bin` + `dracut`, `linux-firmware` (GPU/Wi-Fi), GRUB, `dhcpcd` + `iwd`, `sudo`
- Binary-first Portage (`getbinpkg` + official binhost), so it downloads binaries when available instead of compiling everything

## Usage

```sh
sudo ./setup-gentoo.sh
```

Non-interactive (VMs/testing):

```sh
sudo YES=1 DISK=/dev/vda HOSTNAME=pc USERNAME=user ./setup-gentoo.sh
```

Needs a Linux live env with root, internet, and: `parted mkfs.ext4 mkfs.vfat tar curl lsblk blkid chroot`.

## Warning

**It wipes `$DISK` completely.** Double-check the disk, back up your stuff.

I don't recommend using on a real machine for daily drive, only use this script when you want to use gentoo for tests or on a VM
