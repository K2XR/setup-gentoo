# Gentoo Automated Installer (`setup-gentoo.sh`)

> 🎸 **Projeto Vibe-Codado** — Um instalador automatizado e direto ao ponto para Gentoo Linux, criado com foco em simplicidade e agilidade.

---

### Features

- 🚀 **Automated Partioning & Firmware Detection:** Automatically detects whether your system uses UEFI (GPT + EFI partition) or BIOS/Legacy (MBR + ext4 root partition).
- 📦 **Latest Stage3 Release:** Automatically fetches and verifies the latest `stage3-amd64-openrc` tarball from official Gentoo mirrors.
- ⚡ **Precompiled Kernel:** Installs `sys-kernel/gentoo-kernel-bin` along with `dracut` for initramfs generation, bypassing hours of manual kernel compilation.
- 🌐 **Networking & Tools:** Installs `dhcpcd` and `NetworkManager` (`nmtui`) out of the box for easy network configuration.
- ⚙️ **Optimized Defaults:**
  - **Init System:** OpenRC
  - **Hostname:** `gentoo`
  - **Timezone:** `America/Sao_Paulo` (configurable)
  - **Locale:** `pt_BR.UTF-8` (with `en_US.UTF-8` generated)
  - **Portage:** Automatically synchronizes via `emerge-webrsync`, selects the latest stable profile, and configures parallel compilation (`MAKEOPTS="-j$(nproc)"`).

---

### Requirements

- A live USB / rescue environment running Linux (Gentoo live USB, Arch ISO, Ubuntu, etc.) with `root` privileges.
- Required tools in the live environment: `parted`, `mkfs.ext4`, `mkfs.vfat`, `tar`, `curl`, `lsblk`, `blkid`, `sha512sum`, `chroot`.
- Active internet connection.

---

### Usage

1. Clone or download the script to your live environment:
   ```bash
   git clone <repository-url>
   cd Downloads
   ```

2. Make sure the script is executable:
   ```bash
   chmod +x setup-gentoo.sh
   ```

3. Run the installer as `root`:
   ```bash
   sudo ./setup-gentoo.sh
   ```
   *(Optional)* If you want to set a custom root password during installation:
   ```bash
   sudo ROOT_PASS="your_secure_password" ./setup-gentoo.sh
   ```

4. Follow the interactive prompt to select your target installation disk (e.g., `/dev/sda` or `/dev/nvme0n1`).

5. Once completed, reboot into your new Gentoo system:
   ```bash
   reboot
   ```

⚠️ **WARNING:** This script will erase all data, partitions, and bootloaders on the selected disk. Use with caution and never run it on your host/primary system unless you intend to completely wipe it.
