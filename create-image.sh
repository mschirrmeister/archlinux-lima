#!/usr/bin/env bash

# STATIC Arch Linux ARM Installation Image Creator

set -e
# set -x  # Print every command before executing (for debugging)

# Version for the create-image.sh script
SCRIPT_VERSION="v1.0"

if [[ "$1" == "--version" ]]; then
  echo "create-image.sh $SCRIPT_VERSION"
  exit 0
fi

# Prevent running on macOS (Darwin)
if [[ "$(uname)" == "Darwin" ]]; then
  echo "[ERROR] This script must be run inside a Linux environment (e.g., a Lima VM)."
  echo "macOS lacks required tools and kernel features. Exiting for safety."
  exit 1
fi

# Only allow Debian/Ubuntu or Arch Linux
if ! { [ -f /etc/lsb-release ] || [ -x "$(command -v apt-get)" ] || [ -f /etc/arch-release ]; }; then
  RED='\033[0;31m'
  NC='\033[0m'
  echo -e "${RED}[ERROR] This script supports only Debian/Ubuntu or Arch Linux. Exiting.${NC}"
  exit 1
fi

# --- Dependency checks (Arch & Debian/Ubuntu, supports different package names) ---
declare -A cmd_pkg_map_deb=(
    [parted]=parted
    [mkfs.fat]=dosfstools
    [arch-chroot]=arch-install-scripts
    [bsdtar]=libarchive-tools
    [qemu-img]=qemu-utils
)

declare -A cmd_pkg_map_arch=(
    [parted]=parted
    [mkfs.fat]=dosfstools
    [arch-chroot]=arch-install-scripts
    [bsdtar]=libarchive
    [qemu-img]=qemu-img
)

if [ -f /etc/lsb-release ] || [ -x "$(command -v apt-get)" ]; then
    pkg_map="cmd_pkg_map_deb"
    install_cmd() { sudo apt-get update && sudo apt-get install -y "$1"; }
elif [ -f /etc/arch-release ]; then
    pkg_map="cmd_pkg_map_arch"
    install_cmd() { sudo pacman -Sy --noconfirm "$1"; }
else
    echo "Unsupported distro: could not determine package manager. Exiting."
    exit 1
fi

for cmd in $(eval "echo \${!$pkg_map[@]}"); do
    pkg=$(eval "echo \${$pkg_map[$cmd]}")
    echo "Checking for $cmd (provided by $pkg)..."
    if ! command -v "$cmd" &>/dev/null; then
        echo "$cmd not found, installing package $pkg..."
        install_cmd "$pkg"
        # Verify install
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: $cmd still not found after installing $pkg!"
            exit 1
        else
            echo "$cmd successfully installed."
        fi
    else
        echo "$cmd already present."
    fi
done

# --- Static configuration ---
BUILD_SUFFIX="${BUILD_SUFFIX:-0}"
IMAGE_NAME="Arch-Linux-aarch64-cloudimg-$(date '+%Y%m%d').${BUILD_SUFFIX}.img"
COMPRESS=1
VMIMAGES=(qcow2 vmdk)
ROOTFS_URL="http://de3.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ADREPO_URL="https://api.github.com/repos/kwankiu/archlinux-installer/releases/tags/kernel"
ROOTFS_FILE=$(basename "$ROOTFS_URL")
WORKDIR=/tmp/lima/output

# --- Color output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
colorecho() {
    color="$1"; text="$2"; echo -e "${color}${text}${NC}";
}

# --- QEMU user-mode emulation check (for x86_64 hosts) ---
system_arch=$(uname -m)
colorecho "$GREEN" "System architecture is $system_arch"
if [ "$system_arch" == "x86_64" ]; then
    if ! [ -e "/usr/bin/qemu-aarch64-static" ]; then
        colorecho "$YELLOW" "qemu-aarch64-static is not found, trying to install..."
        if [ -f /etc/lsb-release ] || [ -x "$(command -v apt-get)" ]; then
            # Debian/Ubuntu-based
            sudo apt-get update
            # Install binfmt-support as it is required for update-binfmts to work
            sudo apt-get install -y qemu-user-static binfmt-support
            sudo update-binfmts --enable qemu-aarch64
        elif [ -f /etc/arch-release ]; then
            # Arch Linux
            sudo pacman -S qemu-user-static --noconfirm
            # binfmt is automatically registered
        else
            colorecho "$RED" "Error: qemu-aarch64-static is not installed and could not determine package manager."
            exit 1
        fi
    fi
    # On most distros, binfmt is registered automatically. Manual registration is rarely needed now.
fi

# --- Preparation ---
colorecho "$GREEN" "Creating output directory..."
mkdir -p $WORKDIR
cd $WORKDIR

colorecho "$GREEN" "Downloading Arch Linux ARM rootfs..."
curl -LJO "$ROOTFS_URL"

colorecho "$GREEN" "Creating image file..."
truncate -s 4G "$IMAGE_NAME"

colorecho "$GREEN" "Setting up loop device..."
LOOPDEV=$(sudo losetup -fP --show "$IMAGE_NAME")

colorecho "$GREEN" "Partitioning image..."
sudo parted -s $LOOPDEV mklabel gpt
sudo parted -s $LOOPDEV mkpart ESP fat32 1MiB 513MiB
sudo parted -s $LOOPDEV set 1 boot on
sudo parted -s $LOOPDEV set 1 esp on
sudo parted -s $LOOPDEV mkpart primary ext4 513MiB 100%

colorecho "$GREEN" "Formatting partitions..."
BOOTP="${LOOPDEV}p1"
ROOTP="${LOOPDEV}p2"
sudo mkfs.fat -F32 $BOOTP
sudo mkfs.ext4 -E lazy_itable_init=1,lazy_journal_init=1 $ROOTP

colorecho "$GREEN" "Mounting partitions..."
sudo mkdir -p /mnt/arch-root /mnt/arch-boot
sudo mount $ROOTP /mnt/arch-root
sudo mount $BOOTP /mnt/arch-boot

colorecho "$GREEN" "Extracting rootfs..."
sudo bsdtar -xpf "$ROOTFS_FILE" -C /mnt/arch-root
rm -f "$ROOTFS_FILE"

# --- Kernel Installation (linux-aarch64, cloud-init, cleanup) ---
colorecho "$GREEN" "Installing latest linux-aarch64 kernel and cloud-init ..."
sudo arch-chroot /mnt/arch-root /bin/bash <<'END'
# --- Color output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
colorecho() {
    color="$1"; text="$2"; echo -e "${color}${text}${NC}";
}

pacman-key --init
pacman-key --populate archlinuxarm

colorecho "$GREEN" "Updating pacman.conf to enable parallel downloads..."
sed -i 's/^#ParallelDownloads\s*=\s*\([0-9]\{1,3\}\)\?$/ParallelDownloads = 50/' /etc/pacman.conf

colorecho "$GREEN" "Updating mirrors..."
cp -p /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.save
echo 'Server = http://de3.mirror.archlinuxarm.org/$arch/$repo' | tee /etc/pacman.d/mirrorlist

colorecho "$GREEN" "Refresh package database..."
pacman -Sy --noconfirm

colorecho "$GREEN" "Installing latest linux-aarch64 kernel..."
pacman -Sy linux-aarch64 --needed --noconfirm --nodeps

colorecho "$GREEN" "Removing linux-firmware ..."
pacman -Rdd linux-firmware linux-firmware-whence --noconfirm

colorecho "$GREEN" "Running full system upgrade ..."
pacman -Syu --noconfirm

colorecho "$GREEN" "Installing cloud-init ..."
cloudinit_pkg="cloud-init-25.1.2-1-any.pkg.tar.zst"
curl -LO --output-dir /tmp/ "https://archive.archlinux.org/packages/c/cloud-init/$cloudinit_pkg"
pacman -U /tmp/"$cloudinit_pkg" --needed --noconfirm
rm -f /tmp/"$cloudinit_pkg"

colorecho "$GREEN" "Enabling cloud-init services ..."
systemctl enable cloud-init-main.service
systemctl enable cloud-final.service

colorecho "$GREEN" "Clearing package cache ..."
printf "y\ny\n" | pacman -Scc
END

# --- Copy boot files if needed ---
colorecho "$GREEN" "Copying boot partition files ..."
sudo cp -r /mnt/arch-root/boot/* /mnt/arch-boot/
sudo rm -rf /mnt/arch-root/boot/*

# --- Setting up boot partition ---
colorecho "$GREEN" "Mounting boot partition ..."
sudo mkdir -p /mnt/arch-root/boot
sudo mount $BOOTP /mnt/arch-root/boot

# alarm's linux-aarch64 kernel workaround
if [ -f /mnt/arch-root/boot/Image ]; then
    sudo mv /mnt/arch-root/boot/Image /mnt/arch-root/boot/vmlinuz-linux
fi

sudo arch-chroot /mnt/arch-root /bin/bash <<'END'
# --- Color output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
colorecho() {
    color="$1"; text="$2"; echo -e "${color}${text}${NC}";
}
colorecho "$GREEN" "Installing GRUB bootloader ..."
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy grub efibootmgr --noconfirm

colorecho "$GREEN" "Installing cloud-guest-utils for rootfs auto-resize ..."
pacman -Sy cloud-guest-utils --needed --noconfirm

colorecho "$GREEN" "Append the following cmdline to grub: "
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyAMA0\"/" /etc/default/grub

colorecho "$GREEN" "Installing GRUB ..."
grub-install --target=arm64-efi --efi-directory=/boot --removable
colorecho "$GREEN" "Generating GRUB config ..."
grub-mkconfig -o /boot/grub/grub.cfg

colorecho "$GREEN" "Updating mirrors..."
sed -i 's/^# Server/Server/' /etc/pacman.d/mirrorlist.save

colorecho "$GREEN" "Installing pacman-contrib..."
pacman -S pacman-contrib --needed --noconfirm

colorecho "$GREEN" "Ranking mirrors..."
rankmirrors -n 5 /etc/pacman.d/mirrorlist.save | grep -v '^\s*#' | tee /etc/pacman.d/mirrorlist

colorecho "$GREEN" "Clearing package cache ..."
printf "y\ny\n" | pacman -Scc
END

# --- Zero out free space in root partition to improve compressibility ---
colorecho "$GREEN" "Zeroing out free space in root partition ..."
sudo dd if=/dev/zero of=/mnt/arch-root/zero.fill bs=1M status=progress || true
sudo sync
sudo rm -f /mnt/arch-root/zero.fill

# --- Unmount boot if still mounted ---
if mountpoint -q /mnt/arch-root/boot; then
    sudo umount /mnt/arch-root/boot || sudo umount -l /mnt/arch-root/boot
fi

# --- Unmount partitions ---
colorecho "$GREEN" "Unmounting partitions ..."
sudo umount /mnt/arch-boot || sudo umount -l /mnt/arch-boot
sudo umount /mnt/arch-root || sudo umount -l /mnt/arch-root

sudo losetup --detach $LOOPDEV

# --- Create VM images ---
RAW_IMG="$IMAGE_NAME"
QCOW2_IMG="${IMAGE_NAME%.img}.qcow2"
VMDK_IMG="${IMAGE_NAME%.img}.vmdk"

colorecho "$GREEN" "Creating VM images ..."
sudo qemu-img convert -p -O qcow2 "$RAW_IMG" "$QCOW2_IMG"
sudo qemu-img convert -p -O vmdk "$RAW_IMG" "$VMDK_IMG"

if [ "$COMPRESS" = 1 ]; then
    colorecho "$GREEN" "Compressing images ..."
    sudo xz -T 0 --verbose "$RAW_IMG"
    sudo xz -T 0 --verbose "$QCOW2_IMG"
    sudo xz -T 0 --verbose "$VMDK_IMG"
fi

colorecho "$GREEN" "All images created:"
if [ "$COMPRESS" = 1 ]; then
    echo "  Raw:   $RAW_IMG.xz"
    echo "  QCOW2: $QCOW2_IMG.xz"
    echo "  VMDK:  $VMDK_IMG.xz"
else
    echo "  Raw:   $RAW_IMG"
    echo "  QCOW2: $QCOW2_IMG"
    echo "  VMDK:  $VMDK_IMG"
fi
colorecho "$GREEN" "Static build finished."

exit 0
