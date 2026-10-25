#!/bin/bash
# Arch Linux post-install setup script
# Must be run as root

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Cleanup trap to ensure temporary sudoers file is ALWAYS removed on exit/failure
cleanup() {
    rm -f /etc/sudoers.d/99-temporary-nopasswd
}
trap cleanup EXIT

# Ask for username
read -rp "Enter the username you want to create: " username

# 1. Enable multilib
if grep -q '^\[multilib\]' /etc/pacman.conf; then
    sed -i '/^\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf
    echo "multilib enabled."
else
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    echo "multilib section added."
fi
pacman -Syu --noconfirm

# 2. Add user and enable sudo
useradd -m -G wheel -s /bin/bash "$username"
echo "Set password for $username:"
passwd "$username"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Temporarily allow wheel group passwordless sudo for automated AUR/makepkg builds
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-temporary-nopasswd

# 3. Install KDE Plasma, flatpak + apps
pacman -S --noconfirm plasma-meta kde-gtk-config breeze-gtk \
    konsole nemo kate gwenview okular mpv ark elisa flatpak \
    steam kdeconnect kcalc discord sddm sddm-kcm nano
systemctl enable sddm
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 4. Install PipeWire
pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa wireplumber
loginctl enable-linger "$username"
su - "$username" -c "
    export XDG_RUNTIME_DIR=/run/user/$(id -u $username)
    systemctl --user enable pipewire pipewire-pulse wireplumber
" || echo "Warning: Could not enable user PipeWire services. They will activate on first login."

# 5. GPU drivers
pacman -S --noconfirm linux-headers
read -rp "Which GPU do you have? (nvidia/amd): " gpu

if [[ "$gpu" =~ ^[Nn]vidia$ ]]; then
    read -rp "Is this a hybrid laptop (Intel/AMD + NVIDIA)? [y/N]: " hybrid
    if [[ "$hybrid" =~ ^[Yy]$ ]]; then
        pacman -S --noconfirm nvidia-open nvidia-utils lib32-nvidia-utils nvidia-prime
    else
        pacman -S --noconfirm nvidia-open nvidia-utils lib32-nvidia-utils
    fi

    # Blacklist Nouveau
    cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

    # Bootloader Check & GRUB Switch Logic
    if [[ ! -f /etc/default/grub ]]; then
        echo "GRUB bootloader not detected."
        
        old_bl="unknown"
        if bootctl status &>/dev/null || [[ -d /boot/loader ]] || [[ -d /efi/loader ]]; then
            old_bl="systemd-boot"
            echo "Detected old bootloader: systemd-boot"
        else
            echo "Couldn't find old bootloader."
        fi

        read -rp "Would you like to switch to GRUB? [y/N]: " switch_grub
        if [[ "$switch_grub" =~ ^[Yy]$ ]]; then
            echo "Switching to GRUB..."
            
            if [[ "$old_bl" == "systemd-boot" ]]; then
                echo "Removing systemd-boot..."
                bootctl remove 2>/dev/null || rm -rf /boot/EFI/systemd /boot/loader /efi/EFI/systemd /efi/loader /boot/efi/EFI/systemd /boot/efi/loader
            fi

            pacman -S --noconfirm grub efibootmgr
            
            efi_mount="/boot"
            if mountpoint -q /boot/efi; then
                efi_mount="/boot/efi"
            elif mountpoint -q /efi; then
                efi_mount="/efi"
            fi

            grub-install --target=x86_64-efi --efi-directory="$efi_mount" --bootloader-id=GRUB
            mkdir -p /boot/grub
            grub-mkconfig -o /boot/grub/grub.cfg
        else
            echo "User declined switching to GRUB. Exiting."
            exit 1
        fi
    fi

    # Enable NVIDIA DRM modeset for Wayland via GRUB
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P

    pacman -S --noconfirm vulkan-icd-loader lib32-vulkan-icd-loader

elif [[ "$gpu" =~ ^[Aa]md$ ]]; then
    pacman -S --noconfirm mesa mesa-vdpau vulkan-radeon lib32-mesa lib32-vulkan-radeon
else
    echo "Invalid GPU selection. Exiting."
    exit 1
fi

# 6. Install yay (built as non-root with temp nopasswd)
pacman -S --needed --noconfirm base-devel git
BUILD_DIR="$(mktemp -d)"
git clone https://aur.archlinux.org/yay-git.git "$BUILD_DIR/yay-git"
chown -R "$username:$username" "$BUILD_DIR"
su - "$username" -c "cd '$BUILD_DIR/yay-git' && makepkg -si --noconfirm"
rm -rf "$BUILD_DIR"

# 7. Install browsers
pacman -S --noconfirm chromium
su - "$username" -c "yay -S --noconfirm brave-bin"

# 8. Bluetooth support
pacman -S --noconfirm bluez bluez-utils
systemctl enable --now bluetooth

# Explicit cleanup before success
rm -f /etc/sudoers.d/99-temporary-nopasswd
trap - EXIT

read -rp "Setup complete! Reboot now? [y/N]: " reboot_now
if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
    reboot
fi
