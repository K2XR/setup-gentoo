#!/bin/bash
# =============================================================================
# Instalador automático do Gentoo Linux (quase 100% interativo)
#
# Única interação: escolher o disco (com confirmação de formatação).
#
# Configurações fixas:
#   * hostname: gentoo
#   * apenas usuário root (senha padrão: "gentoo", mude via ROOT_PASS)
#   * init: OpenRC, rede via dhcpcd + iwd (Wi-Fi)
#   * kernel pré-compilado: sys-kernel/gentoo-kernel-bin (initramfs via dracut)
#   * bootloader: GRUB (UEFI ou BIOS detectados automaticamente)
#   * locale: pt_BR.UTF-8 (en_US.UTF-8 também gerado)
#   * fuso: America/Sao_Paulo (altere em TZONE abaixo)
#
# Uso: sudo ./instala-gentoo.sh          (ou defina ROOT_PASS="minha_senha")
# =============================================================================

set -euo pipefail

HOSTNAME="gentoo"
TZONE="America/Sao_Paulo"
ROOT_PASS="${ROOT_PASS:-gentoo}"
MIRROR="https://distfiles.gentoo.org"
CHROOT_DIR="/mnt/gentoo"

# ---------- utilidades ----------
cecho()  { printf '\e[1;32m[*]\e[0m %s\n' "$1"; }
cwarn()  { printf '\e[1;33m[!]\e[0m %s\n' "$1"; }
cfatal() { printf '\e[1;31m[X]\e[0m %s\n' "$1" >&2; exit 1; }

trap 'umount -R "$CHROOT_DIR" 2>/dev/null || umount -l "$CHROOT_DIR" 2>/dev/null || true' EXIT

[ "$(id -u)" -eq 0 ] || cfatal "Execute como root: sudo $0"

for cmd in parted partprobe mkfs.ext4 tar curl lsblk blkid sha512sum chroot; do
    command -v "$cmd" >/dev/null 2>&1 || cfatal "Faltando comando no ambiente: $cmd"
done

# ---------- 1) escolha do disco (única interação) ----------
cecho "Discos disponíveis:"
lsblk -dpn -o NAME,SIZE,MODEL | grep -v '^/dev/loop' || true
echo

PROMPT_DISK="$(printf '\e[1;36m>>>\e[0m Digite o disco a ser usado [ex.: /dev/vda]: ')"
while :; do
    if ! read -r -p "$PROMPT_DISK" DISK; then
        echo
        exit 1
    fi
    DISK="${DISK// /}"
    [ -n "$DISK" ] || continue
    [ -b "$DISK" ] && break
    cwarn "Disco '$DISK' não existe. Escolha um dos listados acima."
done
export DISK

if mount | grep -q "^$DISK"; then
    cfatal "$DISK está montado/em uso no sistema atual. Use outro disco."
fi

# aviso de formatação
cwarn "ATENÇÃO: TODO o conteúdo de $DISK será APAGADO (partições,"
cwarn "arquivos e bootloader). Risco iminente de perda de dados!"
echo

# ---------- 2) detecção UEFI / BIOS ----------
if [ -d /sys/firmware/efi ]; then
    EFI="yes"
    cecho "Firmware UEFI detectado (partição EFI + GPT)."
else
    EFI="no"
    cecho "Firmware BIOS/legacy detectado (MBR)."
fi
export EFI

case "$DISK" in
    *[0-9]) SUF="p" ;;   # ex.: /dev/nvme0n1 -> p1
    *)      SUF=""  ;;   # ex.: /dev/vda -> 1
esac

cecho "Plano de instalação em $DISK:"
[ "$EFI" = "yes" ] && cecho "  ${DISK}${SUF}1 -> EFI (fat32, 512 MiB)"
cecho "  ${DISK}${SUF}2 -> root (ext4, resto do disco)" || cecho "  ${DISK}${SUF}1 -> root (ext4, disco inteiro)"

# ---------- 3) particionar ----------
if [ "$EFI" = "yes" ]; then
    command -v mkfs.vfat >/dev/null 2>&1 || cfatal "Faltando mkfs.vfat (dosfstools) no ambiente."
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
[ -b "$ROOT_PART" ] || cfatal "Partição $ROOT_PART não apareceu. Abortando."

# ---------- 4) formatar e montar ----------
cecho "Formatando $ROOT_PART como ext4..."
mkfs.ext4 -F -L gentoo-root "$ROOT_PART"
if [ "$EFI" = "yes" ]; then
    cecho "Formatando $EFI_PART como FAT32..."
    mkfs.vfat -F 32 -n GENTOO-EFI "$EFI_PART"
fi

mkdir -p "$CHROOT_DIR"
mount "$ROOT_PART" "$CHROOT_DIR"
if [ "$EFI" = "yes" ]; then
    mount --mkdir "$EFI_PART" "$CHROOT_DIR/efi"
fi

# ---------- 5) baixar e extrair o stage3 (OpenRC, amd64) ----------
if [ -z "${STAGE3_URL:-}" ]; then
    cecho "Buscando o stage3 mais recente em $MIRROR ..."
    TXT=$(curl -sf --ipv4 "$MIRROR/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt") \
        || cfatal "Sem acesso à internet ou mirror fora do ar. Dica: se o DNS só responder IPv6, troque o DNS (echo 'nameserver 1.1.1.1' > /etc/resolv.conf) e rode de novo."
    STAGE3_FILE=$(printf '%s\n' "$TXT" | awk '!/^#/ && $1 ~ /stage3-amd64-openrc.*\.(tar\.xz|tar\.zst)$/ {print $1; exit}')
    STAGE3_SHA=$(printf '%s\n' "$TXT" | awk '!/^#/ && $1 ~ /stage3-amd64-openrc.*\.(tar\.xz|tar\.zst)$/ {print $3; exit}')
    [ -n "$STAGE3_FILE" ] || cfatal "Não encontrei o stage3 no arquivo de versões."
    STAGE3_URL="$MIRROR/releases/amd64/autobuilds/$STAGE3_FILE"
else
    STAGE3_SHA=""
fi

cecho "Baixando $STAGE3_URL ..."
curl -fL --retry 3 --ipv4 -o "$CHROOT_DIR/stage3.tar.xz" "$STAGE3_URL"
if [ -n "$STAGE3_SHA" ]; then
    ( cd "$CHROOT_DIR" && printf '%s  stage3.tar.xz\n' "$STAGE3_SHA" | sha512sum -c - ) \
        || cfatal "Checksum do stage3 falhou."
fi

cecho "Extraindo stage3 para $CHROOT_DIR ..."
tar -xpf "$CHROOT_DIR/stage3.tar.xz" --xattrs-include='*.*' --numeric-owner -C "$CHROOT_DIR"
rm -f "$CHROOT_DIR/stage3.tar.xz"

# ---------- 6) preparar o chroot ----------
mount --rbind /dev "$CHROOT_DIR/dev"
mount --rbind /sys "$CHROOT_DIR/sys"
mount -t proc none "$CHROOT_DIR/proc"
mount --rbind /run "$CHROOT_DIR/run"
cp -L /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

# reutiliza a árvore do portage caso o ambiente atual seja Gentoo
if [ -d /var/db/repos/gentoo ] && [ ! -d "$CHROOT_DIR/var/db/repos/gentoo" ]; then
    cecho "Copiando o repositório do portage do ambiente atual..."
    cp -a /var/db/repos/gentoo "$CHROOT_DIR/var/db/repos/"
fi

# fstab com UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
{
    echo "UUID=$ROOT_UUID / ext4 noatime 0 1"
    if [ "$EFI" = "yes" ]; then
        EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
        echo "UUID=$EFI_UUID /efi vfat defaults 0 2"
    fi
} > "$CHROOT_DIR/etc/fstab"

# ---------- 7) script de configuração DENTRO do chroot ----------
export HOSTNAME TZONE ROOT_PASS
cat > "$CHROOT_DIR/root/install-in-chroot.sh" <<'CHROOT'
#!/bin/bash
set -euo pipefail
set +u
source /etc/profile
set -u

# --- árvore do portage ---
if [ ! -f /var/db/repos/gentoo/metadata/timestamp.chk ]; then
    echo "[*] Sincronizando o portage (emerge-webrsync, pode demorar)..."
    emerge-webrsync
fi

# --- profile estável mais recente ---
PROFILES=$(eselect profile list)
PROFILE=$(printf '%s\n' "$PROFILES" | awk '/\(stable\)/ {print $1; exit}' | tr -d '[]')
[ -n "$PROFILE" ] || PROFILE=1
eselect profile set "$PROFILE"
CUR_PROFILE=$(eselect profile show)
echo "[*] Profile selecionado: $(printf '%s\n' "$CUR_PROFILE" | head -n1)"

# --- locale ---
cat > /etc/locale.gen <<'LOCALE'
en_US.UTF-8 UTF-8
pt_BR.UTF-8 UTF-8
LOCALE
locale-gen
eselect locale set pt_BR.UTF-8

# --- fuso horário ---
ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
echo "$TZONE" > /etc/timezone

# --- hostname ---
echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost $HOSTNAME
::1         localhost $HOSTNAME
HOSTS

# --- senha do root ---
ROOT_HASH=$(openssl passwd -6 "$ROOT_PASS")
sed -i "s|^root:[^:]*|root:$ROOT_HASH|" /etc/shadow

# --- make.conf ---
cat > /etc/portage/make.conf <<MAKE
COMMON_FLAGS="-O2 -pipe"
MAKEOPTS="-j$(nproc)"
EMERGE_DEFAULT_OPTS="--ask=n --quiet"
ACCEPT_LICENSE="*"
MAKE

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

# --- pacotes: kernel pré-compilado, grub, dhcpcd, iwd, linux-firmware ---
echo "[*] Instalando pacotes (grub, gentoo-kernel-bin, dhcpcd, iwd, linux-firmware)..."
USE="dracut" emerge sys-boot/grub sys-kernel/gentoo-kernel-bin net-misc/dhcpcd net-wireless/iwd sys-kernel/linux-firmware
if [ "$EFI" = "yes" ]; then
    emerge sys-boot/efibootmgr
fi

# --- initramfs (fallback, caso não tenha sido gerada) ---
if ! ls /boot/initramfs-* >/dev/null 2>&1; then
    echo "[*] Gerando initramfs com dracut..."
    dracut --force
fi

# --- bootloader ---
if [ "$EFI" = "yes" ]; then
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB \
        || grub-install --target=x86_64-efi --efi-directory=/efi --removable
else
    grub-install "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# --- serviços ---
rc-update add dhcpcd default
rc-update add iwd default

# --- limpeza ---
rm -f /root/install-in-chroot.sh
env-update
echo "[*] Configuração dentro do chroot concluída."
CHROOT

# ---------- 8) executar ----------
cecho "Executando a instalação dentro do chroot (isso leva alguns minutos)..."
chroot "$CHROOT_DIR" /bin/bash /root/install-in-chroot.sh

# ---------- 9) finalizar ----------
umount -R "$CHROOT_DIR"
trap - EXIT
cecho "Instalação concluída!"
cecho "  - hostname: $HOSTNAME"
cecho "  - usuário: root (senha: $ROOT_PASS)"
cecho "  - reinicie com: reboot"
