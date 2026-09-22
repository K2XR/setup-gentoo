#!/bin/bash
# =============================================================================
# Assisted Gentoo Linux installer
#
# Prompts (with defaults, Enter accepts the default):
#   * keyboard layout (keymap), timezone, locale
#   * hostname, extra user + passwords (root and user)
#   * target disk (with confirmation before wiping)
#
# Fixed (binary-first):
#   * init: OpenRC, network via dhcpcd + iwd (Wi-Fi)
#   * precompiled kernel: sys-kernel/gentoo-kernel-bin (initramfs via dracut)
#   * bootloader: GRUB (UEFI or BIOS auto-detected)
#   * linux-firmware installed before the kernel (GPU/Wi-Fi in initramfs)
#   * emerge prefers official binaries (getbinpkg + binhost)
#
# Interactive use:   sudo ./setup-gentoo.sh
# Non-interactive use (accepts all defaults / env):
#                   sudo YES=1 ./setup-gentoo.sh
# Supported env: HOSTNAME KEYMAP TZONE LOCALE USERNAME ROOT_PASS USER_PASS
#                 DISK MIRROR STAGE3_URL
# =============================================================================

set -euo pipefail

# ---------- help / list options ----------
usage() {
cat <<'USAGE'
Usage: sudo ./setup-gentoo.sh [OPTIONS]

Assisted Gentoo installer (setup-alpine style). Without options it asks
everything interactively; Enter accepts the [default].

Options:
  -h, --help            Show this help and exit
  -l, --list-options    List all env vars / defaults and exit
  -y, --yes             Non-interactive (same as YES=1), accept all defaults
  --dry-run             Show resolved config and exit without touching disks
  VAR=value ...         Set any option as argument (e.g. HOSTNAME=pc DISK=/dev/vda)

All options (env var, default):
  HOSTNAME    (gentoo)                 Machine hostname
  KEYMAP      (us)                     Console keymap (us, us-intl, br-abnt2, de, ...)
  TZONE       (America/New_York)       Timezone under /usr/share/zoneinfo
  LOCALE      (en_US.UTF-8)            Primary locale (en_US.UTF-8 always generated too)
  USERNAME    (empty)                  Extra user; empty = root only
  ROOT_PASS   (gentoo)                 Root password (prompted hidden if unset)
  USER_PASS   (gentoo)                 Password for USERNAME (prompted if USERNAME set)
  DISK        (none, required)         Target disk, e.g. /dev/sda, /dev/nvme0n1
  FULL_FIRMWARE (unset)                Keep all firmware blobs (needs a bigger disk)
  MIRROR      (https://distfiles.gentoo.org)
  STAGE3_URL  (latest openrc)          Override stage3 tarball URL
  YES=1       (unset)                  Non-interactive mode

Examples:
  sudo ./setup-gentoo.sh
  sudo ./setup-gentoo.sh --list-options
  sudo ./setup-gentoo.sh HOSTNAME=pc USERNAME=john DISK=/dev/vda
  sudo YES=1 DISK=/dev/vda ./setup-gentoo.sh
USAGE
}

list_options() {
    printf '%-12s default: %s\n' \
        "HOSTNAME" "${HOSTNAME:-gentoo}" \
        "KEYMAP" "${KEYMAP:-us}" \
        "TZONE" "${TZONE:-America/New_York}" \
        "LOCALE" "${LOCALE:-en_US.UTF-8}" \
        "USERNAME" "${USERNAME:-(empty = root only)}" \
        "ROOT_PASS" "${ROOT_PASS:-(prompted)}" \
        "USER_PASS" "${USER_PASS:-(prompted if USERNAME set)}" \
        "DISK" "${DISK:-(none, required)}" \
        "FULL_FIRMWARE" "${FULL_FIRMWARE:-(unset = trim datacenter/SoC blobs)}" \
        "MIRROR" "${MIRROR:-https://distfiles.gentoo.org}" \
        "STAGE3_URL" "${STAGE3_URL:-(latest stage3-amd64-openrc)}" \
        "YES" "${YES:-(unset)}"
}

DRY_RUN=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        -l|--list-options) list_options; exit 0 ;;
        -y|--yes) NONINTERACTIVE=1; YES=1 ;;
        --dry-run) DRY_RUN=1; NONINTERACTIVE=1; YES=1 ;;
        *=*) export "${arg%%=*}=${arg#*=}"
             [ "${arg%%=*}" = "HOSTNAME" ] && _HOSTNAME_FROM_CLI=1 ;;
        *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
    esac
done

MIRROR="${MIRROR:-https://distfiles.gentoo.org}"
CHROOT_DIR="/mnt/gentoo"
NONINTERACTIVE="${YES:-${NONINTERACTIVE:-}}"

# ---------- utilities ----------
cecho()  { printf '\e[1;32m[*]\e[0m %s\n' "$1"; }
cwarn()  { printf '\e[1;33m[!]\e[0m %s\n' "$1"; }
cfatal() { printf '\e[1;31m[X]\e[0m %s\n' "$1" >&2; exit 1; }
q()      { printf '\e[1;36m>>>\e[0m %s' "$1"; }

# prompt with default; respects preset env and YES=1 mode
# ask VAR "Prompt" "default"
ask() {
    local var="$1" prompt="$2" def="$3" cur
    eval "cur=\"\${$var:-}\""
    if [ -n "${NONINTERACTIVE}" ]; then
        eval "$var=\"\${$var:-$def}\""
        return
    fi
    if [ -n "$cur" ]; then
        return  # env already provided a value, do not prompt
    fi
    local ans
    if ! read -r -p "$(q "$prompt [$def]: ")" ans; then echo; exit 1; fi
    ans="${ans:-$def}"
    eval "$var=\"\$ans\""
}

# password prompt (hidden); skips if env is already set
ask_pass() {
    local var="$1" prompt="$2" cur
    eval "cur=\"\${$var:-}\""
    if [ -n "$cur" ]; then return; fi
    if [ -n "${NONINTERACTIVE}" ]; then
        eval "$var=\"gentoo\""
        cwarn "$var not set, using default 'gentoo' (change it after install)."
        return
    fi
    local a b
    read -r -s -p "$(q "$prompt: ")" a; echo
    if [ -z "$a" ]; then eval "$var=\"gentoo\""; cwarn "Empty password, using 'gentoo'."; return; fi
    read -r -s -p "$(q "Confirm: ")" b; echo
    [ "$a" = "$b" ] || cfatal "Passwords do not match."
    eval "$var=\"\$a\""
}

trap 'umount -R "$CHROOT_DIR" 2>/dev/null || umount -l "$CHROOT_DIR" 2>/dev/null || true' EXIT

if [ -z "$DRY_RUN" ] && [ "$(id -u)" -ne 0 ]; then cfatal "Run as root: sudo $0"; fi

for cmd in parted partprobe mkfs.ext4 tar curl lsblk blkid sha512sum chroot; do
    command -v "$cmd" >/dev/null 2>&1 || cfatal "Missing command in live environment: $cmd"
done

echo "=== setup-gentoo ==="
echo "Press Enter to accept the value in [brackets]."
echo

# ---------- 0) questionnaire ----------
# HOSTNAME is auto-exported by most shells (live env hostname), so ignore it
# unless explicitly passed as CLI arg (VAR=value) or YES env.
if [ -z "${_HOSTNAME_FROM_CLI:-}" ] && [ "${HOSTNAME:-}" = "$(cat /proc/sys/kernel/hostname 2>/dev/null)" ]; then
    unset HOSTNAME
fi
ask HOSTNAME "Machine hostname" "${HOSTNAME:-gentoo}"
ask KEYMAP  "Keyboard layout (e.g.: us, us-intl, br-abnt2, de, es, fr)" "${KEYMAP:-us}"

cwarn "Hint: To find available options, you can open another TTY (Ctrl+Alt+F2)."
cwarn "- Timezones: grep 'Your_City' timezones.txt (or cat timezones.txt)"
cwarn "- Locales: eselect locale list"

ask TZONE   "Timezone (e.g.: America/New_York)" "${TZONE:-America/New_York}"
ask LOCALE  "Primary locale (e.g.: en_US.UTF-8)" "${LOCALE:-en_US.UTF-8}"
ask USERNAME "Extra user (empty = root only)" "${USERNAME:-}"

ask_pass ROOT_PASS "Root password"
if [ -n "${USERNAME:-}" ]; then
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || cfatal "Invalid username: $USERNAME"
    ask_pass USER_PASS "Password for user $USERNAME"
fi

echo
cecho "Summary: hostname=$HOSTNAME keymap=$KEYMAP timezone=$TZONE locale=$LOCALE user=${USERNAME:-(root only)}"

if [ -n "$DRY_RUN" ]; then
    echo "--- resolved config (dry-run, nothing will be touched) ---"
    list_options
    cecho "disk: ${DISK:-(not set)}"
    exit 0
fi

# ---------- 1) disk selection ----------
cecho "Available disks:"
lsblk -dpn -o NAME,SIZE,MODEL | grep -v '^/dev/loop' || true
echo

if [ -n "${DISK:-}" ]; then
    [ -b "$DISK" ] || cfatal "DISK='$DISK' does not exist."
else
    if [ -n "${NONINTERACTIVE}" ]; then cfatal "Set DISK=/dev/... in YES=1 mode."; fi
    while :; do
        if ! read -r -p "$(q "Disk to use [e.g.: /dev/vda]: ")" DISK; then echo; exit 1; fi
        DISK="${DISK// /}"
        [ -n "$DISK" ] || continue
        [ -b "$DISK" ] && break
        cwarn "Disk '$DISK' does not exist. Pick one from the list above."
    done
fi
export DISK

if mount | grep -q "^$DISK"; then
    cfatal "$DISK is mounted/in use by the live system. Pick another disk."
fi

# --- disk size sanity check (recommendation only, never aborts) ---
DISK_BYTES=$(lsblk -dbn -o SIZE "$DISK" 2>/dev/null || echo 0)
if [ "$DISK_BYTES" -lt $((8*1024*1024*1024)) ]; then
    cwarn "$DISK is smaller than 8 GiB. The install peaks around ~7 GB"
    cwarn "(stage3 + portage tree + linux-firmware + kernel unpack) and"
    cwarn "will likely run out of space. A disk of 12+ GiB is recommended."
elif [ "$DISK_BYTES" -lt $((12*1024*1024*1024)) ]; then
    cwarn "$DISK is smaller than 12 GiB. It usually fits, but a bigger"
    cwarn "disk is recommended for comfort."
fi

cwarn "WARNING: ALL data on $DISK will be ERASED!"
if [ -z "${NONINTERACTIVE}" ]; then
    read -r -p "$(q "Confirm wiping $DISK? [yes/NO]: ")" CONFIRM
    [ "${CONFIRM:-}" = "yes" ] || { echo "Aborted."; exit 1; }
fi
echo

# ---------- 2) UEFI / BIOS detection ----------
if [ -d /sys/firmware/efi ]; then
    EFI="yes"
    cecho "UEFI firmware detected (EFI partition + GPT)."
else
    EFI="no"
    cecho "BIOS/legacy firmware detected (MBR)."
fi
export EFI

case "$DISK" in
    *[0-9]) SUF="p" ;;   # e.g.: /dev/nvme0n1 -> p1
    *)      SUF=""  ;;   # e.g.: /dev/vda -> 1
esac

cecho "Install plan for $DISK:"
[ "$EFI" = "yes" ] && cecho "  ${DISK}${SUF}1 -> EFI (fat32, 512 MiB)"
cecho "  ${DISK}${SUF}2 -> root (ext4, rest of disk)" || cecho "  ${DISK}${SUF}1 -> root (ext4, whole disk)"

# ---------- 3) partitioning ----------
if [ "$EFI" = "yes" ]; then
    command -v mkfs.vfat >/dev/null 2>&1 || cfatal "Missing mkfs.vfat (dosfstools) in live environment."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart EFI fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart root ext4 513MiB 100%
    EFI_PART="${DISK}${SUF}1"
    ROOT_PART="${DISK}${SUF}2"
else
    parted -s "$DISK" mklabel msdos
    parted -s "$DISK" mkpart primary ext4 1MiB 100%
    parted -s "$DISK" set 1 boot on
    ROOT_PART="${DISK}${SUF}1"
    EFI_PART=""
fi

partprobe "$DISK" 2>/dev/null || true
for _ in $(seq 1 20); do [ -b "$ROOT_PART" ] && break; sleep 1; done
[ -b "$ROOT_PART" ] || cfatal "Partition $ROOT_PART did not appear. Aborting."

# ---------- 4) format and mount ----------
cecho "Formatting $ROOT_PART as ext4..."
mkfs.ext4 -F -L gentoo-root "$ROOT_PART"
if [ "$EFI" = "yes" ]; then
    cecho "Formatting $EFI_PART as FAT32..."
    mkfs.vfat -F 32 -n GENTOO-EFI "$EFI_PART"
fi

mkdir -p "$CHROOT_DIR"
mount "$ROOT_PART" "$CHROOT_DIR"
if [ "$EFI" = "yes" ]; then
    mount --mkdir "$EFI_PART" "$CHROOT_DIR/efi"
fi

# ---------- 5) download and extract stage3 (OpenRC, amd64) ----------
if [ -z "${STAGE3_URL:-}" ]; then
    cecho "Fetching latest stage3 from $MIRROR ..."
    TXT=$(curl -sf --ipv4 "$MIRROR/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt") \
        || cfatal "No internet access or mirror is down. Hint: if DNS only answers IPv6, switch DNS (echo 'nameserver 1.1.1.1' > /etc/resolv.conf) and run again."
    STAGE3_FILE=$(printf '%s\n' "$TXT" | awk '!/^#/ && $1 ~ /stage3-amd64-openrc.*\.(tar\.xz|tar\.zst)$/ {print $1; exit}')
    STAGE3_SHA=$(printf '%s\n' "$TXT" | awk '!/^#/ && $1 ~ /stage3-amd64-openrc.*\.(tar\.xz|tar\.zst)$/ {print $3; exit}')
    [ -n "$STAGE3_FILE" ] || cfatal "Stage3 not found in the release list."
    STAGE3_URL="$MIRROR/releases/amd64/autobuilds/$STAGE3_FILE"
else
    STAGE3_SHA=""
fi

cecho "Downloading $STAGE3_URL ..."
curl -fL --retry 3 --ipv4 -o "$CHROOT_DIR/stage3.tar.xz" "$STAGE3_URL"
if [ -n "$STAGE3_SHA" ]; then
    ( cd "$CHROOT_DIR" && printf '%s  stage3.tar.xz\n' "$STAGE3_SHA" | sha512sum -c - ) \
        || cfatal "Stage3 checksum failed."
fi

cecho "Extracting stage3 to $CHROOT_DIR ..."
tar -xpf "$CHROOT_DIR/stage3.tar.xz" --xattrs-include='*.*' --numeric-owner -C "$CHROOT_DIR"
rm -f "$CHROOT_DIR/stage3.tar.xz"

# ---------- 6) prepare chroot ----------
mount --rbind /dev "$CHROOT_DIR/dev"
mount --rbind /sys "$CHROOT_DIR/sys"
mount -t proc none "$CHROOT_DIR/proc"
mount --rbind /run "$CHROOT_DIR/run"
cp -L /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

# reuse the portage tree if the live environment is Gentoo
if [ -d /var/db/repos/gentoo ] && [ ! -d "$CHROOT_DIR/var/db/repos/gentoo" ]; then
    cecho "Copying portage repository from live environment..."
    cp -a /var/db/repos/gentoo "$CHROOT_DIR/var/db/repos/"
fi

# fstab with UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
{
    echo "UUID=$ROOT_UUID / ext4 noatime 0 1"
    if [ "$EFI" = "yes" ]; then
        EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
        echo "UUID=$EFI_UUID /efi vfat defaults 0 2"
    fi
} > "$CHROOT_DIR/etc/fstab"

# ---------- 7) configuration script INSIDE the chroot ----------
export HOSTNAME TZONE LOCALE KEYMAP USERNAME ROOT_PASS USER_PASS
cat > "$CHROOT_DIR/root/install-in-chroot.sh" <<'CHROOT'
#!/bin/bash
set -euo pipefail
set +u
source /etc/profile
set -u

# --- portage tree ---
if [ ! -f /var/db/repos/gentoo/metadata/timestamp.chk ]; then
    echo "[*] Syncing portage (emerge-webrsync, may take a while)..."
    emerge-webrsync
fi

# --- latest stable profile ---
PROFILES=$(eselect profile list)
PROFILE=$(printf '%s\n' "$PROFILES" | awk '/\(stable\)/ {print $1; exit}' | tr -d '[]')
[ -n "$PROFILE" ] || PROFILE=1
eselect profile set "$PROFILE"
CUR_PROFILE=$(eselect profile show)
echo "[*] Selected profile: $(printf '%s\n' "$CUR_PROFILE" | head -n1)"

# --- locale (chosen primary + en_US fallback) ---
: "${LOCALE:=en_US.UTF-8}"
cat > /etc/locale.gen <<LOCALE
en_US.UTF-8 UTF-8
$LOCALE UTF-8
LOCALE
# avoid duplicates if primary is already en_US
awk '!seen[$0]++' /etc/locale.gen > /tmp/locale.gen && mv /tmp/locale.gen /etc/locale.gen
locale-gen
eselect locale set "$LOCALE" || eselect locale set en_US.UTF-8

# --- timezone ---
if [ -e "/usr/share/zoneinfo/$TZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
    echo "$TZONE" > /etc/timezone
else
    echo "[!] Timezone '$TZONE' is invalid, falling back to UTC."
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo "UTC" > /etc/timezone
fi

# --- keyboard (console) ---
: "${KEYMAP:=us}"
echo "keymap=\"$KEYMAP\"" > /etc/conf.d/keymaps
rc-update add keymaps boot 2>/dev/null || true

# --- hostname ---
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost $HOSTNAME
::1         localhost $HOSTNAME
HOSTS

# --- root password ---
ROOT_HASH=$(openssl passwd -6 "$ROOT_PASS")
sed -i "s|^root:[^:]*|root:$ROOT_HASH|" /etc/shadow

# --- make.conf (binary-first: prefer official binary packages) ---
cat > /etc/portage/make.conf <<MAKE
COMMON_FLAGS="-O2 -pipe"
MAKEOPTS="-j$(nproc)"
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature"
EMERGE_DEFAULT_OPTS="--ask=n --quiet --getbinpkg --quiet-build=y"
ACCEPT_LICENSE="*"
BINPKG_FORMAT="gpkg"
MAKE

mkdir -p /etc/portage/binrepos.conf
cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<'BINHOST'
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
BINHOST

mkdir -p /etc/portage/package.accept_keywords
cat > /etc/portage/package.accept_keywords/gentoo-kernel-bin <<'EOF'
sys-kernel/gentoo-kernel-bin ~amd64
virtual/dist-kernel ~amd64
sys-kernel/installkernel ~amd64
EOF

mkdir -p /etc/iwd
cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=true
EOF

# free distfiles + build dirs between steps (matters on small disks)
clean_pkg_leftovers() {
    rm -rf /var/tmp/portage/*
    rm -f /var/cache/distfiles/*
    rm -rf /var/cache/binpkgs/*
}

# --- firmware first (GPU/Wi-Fi) so it is present in the initramfs ---
echo "[*] Installing linux-firmware (GPU/Wi-Fi)..."
emerge sys-kernel/linux-firmware

# --- trim firmware: datacenter NICs/HBAs + ARM SoCs are dead weight on
# --- amd64 desktops/VMs (~800 MB). Desktop GPUs + Wi-Fi are kept.
# --- Skip with FULL_FIRMWARE=1 (needs a bigger disk).
if [ -z "${FULL_FIRMWARE:-}" ]; then
    echo "[*] Trimming datacenter/SoC firmware blobs (FULL_FIRMWARE=1 to keep)..."
    rm -rf /lib/firmware/qcom /lib/firmware/netronome /lib/firmware/mellanox \
        /lib/firmware/qed /lib/firmware/qlogic /lib/firmware/cavium \
        /lib/firmware/dpaa2 /lib/firmware/liquidio /lib/firmware/cxgb3 \
        /lib/firmware/cxgb4 /lib/firmware/bnx2 /lib/firmware/bnx2x \
        /lib/firmware/tehuti /lib/firmware/vxge /lib/firmware/sxg \
        /lib/firmware/slicoss /lib/firmware/tigon /lib/firmware/amlogic \
        /lib/firmware/meson /lib/firmware/rockchip /lib/firmware/arm \
        /lib/firmware/imx /lib/firmware/nxp /lib/firmware/powervr
fi
clean_pkg_leftovers

# --- kernel first, alone: its unpack needs ~2.5 GB free at once ---
echo "[*] Installing kernel (gentoo-kernel-bin)..."
USE="dracut" emerge sys-kernel/gentoo-kernel-bin
clean_pkg_leftovers

# --- bootloader + network ---
echo "[*] Installing packages (grub, dhcpcd, iwd)..."
USE="dracut" emerge sys-boot/grub net-misc/dhcpcd net-wireless/iwd
if [ "$EFI" = "yes" ]; then
    emerge sys-boot/efibootmgr
fi
clean_pkg_leftovers

# --- sudo (best-effort: needed only if an extra user was created) ---
if [ -n "${USERNAME:-}" ]; then
    echo "[*] Installing sudo..."
    emerge app-admin/sudo || echo "[!] sudo failed to emerge; install it later with: emerge app-admin/sudo"
    clean_pkg_leftovers
fi

# --- extra user (wheel group + sudo) ---
if [ -n "${USERNAME:-}" ]; then
    echo "[*] Creating user $USERNAME ..."
    useradd -m -G wheel,audio,video -s /bin/bash "$USERNAME"
    USER_HASH=$(openssl passwd -6 "${USER_PASS:-gentoo}")
    sed -i "s|^$USERNAME:[^:]*|$USERNAME:$USER_HASH|" /etc/shadow
    # enable %wheel via sudo (only if sudo actually installed)
    if [ -f /etc/sudoers ]; then
        sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    else
        echo "[!] sudo not installed; user $USERNAME has no sudo. Run later: emerge app-admin/sudo"
    fi
fi

# --- initramfs (regenerate to embed linux-firmware) ---
echo "[*] Regenerating initramfs with dracut (includes firmware)..."
dracut --force --hostonly --add-drivers "amdgpu radeon i915 xe nouveau ath10k ath11k ath12k iwlwifi iwlmvm btusb xhci_pci nvme" || dracut --force

# --- bootloader ---
if [ "$EFI" = "yes" ]; then
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB \
        || grub-install --target=x86_64-efi --efi-directory=/efi --removable
else
    grub-install "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# --- services ---
rc-update add dhcpcd default
rc-update add iwd default

# --- cleanup ---
rm -f /root/install-in-chroot.sh
env-update
echo "[*] Configuration inside chroot finished."
CHROOT

# ---------- 8) run ----------
cecho "Running installation inside chroot (this takes a few minutes)..."
chroot "$CHROOT_DIR" /bin/bash /root/install-in-chroot.sh

# ---------- 9) finish ----------
umount -R "$CHROOT_DIR"
trap - EXIT
cecho "Installation complete!"
cecho "  - hostname: $HOSTNAME | keymap: $KEYMAP | timezone: $TZONE | locale: $LOCALE"
if [ -n "${USERNAME:-}" ]; then cecho "  - user: $USERNAME (+ root)"; else cecho "  - user: root (password set during install)"; fi
cecho "  - reboot with: reot"
