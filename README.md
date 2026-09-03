** Gentoo Automated Installer ** ("setup-gentoo.sh")

«Vibe-coded project. This installer was built with a focus on simplicity, automation, and getting a working Gentoo installation up and running with minimal manual intervention.»

A simple and straightforward automated installer for Gentoo Linux. It automates most of the initial installation process while keeping the configuration relatively minimal and easy to understand.

---

Features

- Automated Partitioning and Firmware Detection: Automatically detects whether the system is using UEFI or BIOS/Legacy firmware and configures the disk accordingly.
  - UEFI: GPT partition table with an EFI System Partition and an ext4 root partition.
  - BIOS/Legacy: MBR partition table with an ext4 root partition.
- Latest Stage 3 Release: Automatically downloads and verifies the latest "stage3-amd64-openrc" tarball from official Gentoo mirrors.
- Precompiled Kernel: Installs "sys-kernel/gentoo-kernel-bin" together with "dracut" for initramfs generation, avoiding the need for manual kernel compilation.
- Networking and Tools: Installs "dhcpcd" and NetworkManager, including "nmtui", for convenient network configuration.
- Optimized Defaults:
  - Init System: OpenRC
  - Hostname: "gentoo"
  - Timezone: "America/Sao_Paulo"
  - Locale: "pt_BR.UTF-8", with "en_US.UTF-8" also generated
  - Portage: Automatically synchronizes the Portage tree using "emerge-webrsync"
  - Profile: Automatically selects the latest stable profile
  - Parallel Compilation: Configures "MAKEOPTS" based on the number of available CPU cores

---

Requirements

The installer must be executed from a Linux live or rescue environment with root privileges.

Supported environments may include:

- Gentoo Live Environment
- Arch Linux ISO
- Ubuntu Live Environment
- Other Linux-based rescue environments

The live environment must provide the following tools:

- "parted"
- "mkfs.ext4"
- "mkfs.vfat"
- "tar"
- "curl"
- "lsblk"
- "blkid"
- "sha512sum"
- "chroot"

An active Internet connection is also required.

---

Usage

1. Download the installer

Clone the repository or download the script to your live environment:

git clone <repository-url>
cd <repository-directory>

2. Make the script executable

chmod +x setup-gentoo.sh

3. Run the installer

Execute the installer as root:

sudo ./setup-gentoo.sh

Alternatively, you can provide a custom root password through the "ROOT_PASS" environment variable:

sudo ROOT_PASS="your_secure_password" ./setup-gentoo.sh

4. Select the installation disk

The installer will display the available disks and ask you to select the target device.

For example:

/dev/sda
/dev/nvme0n1

Make sure you select the correct disk before continuing.

5. Reboot

Once the installation has completed successfully, reboot the system:

reboot

Remove the live USB before the system boots again.

---

Default Configuration

Setting| Default
Init System| OpenRC
Hostname| "gentoo"
Timezone| "America/Sao_Paulo"
Primary Locale| "pt_BR.UTF-8"
Additional Locale| "en_US.UTF-8"
Kernel| "sys-kernel/gentoo-kernel-bin"
Initramfs| "dracut"
Network Manager| NetworkManager
DHCP Client| "dhcpcd"
Portage Sync| "emerge-webrsync"

---

Warning

This installer will erase the selected disk.

All existing data, partitions, filesystems, and bootloaders on the selected disk may be permanently destroyed.

Double-check the selected disk before confirming the installation.

Do not run this script on a disk containing important data unless you intend to completely erase it.

Always keep a backup of important data before running the installer.

---

About This Project

This is a vibe-coded project.

The goal is not to replace the official Gentoo installation process or provide a universal installer. Instead, it is a personal automation project intended to simplify the repetitive parts of installing Gentoo.

The script may contain rough edges, assumptions, or bugs. Review the code before running it, especially if you are using unusual hardware, storage layouts, or firmware configurations.

Use it, modify it, break it, fix it, and improve it.
