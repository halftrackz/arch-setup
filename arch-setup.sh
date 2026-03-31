#!/bin/bash
# Arch Linux post-install setup script
# Must be run as root

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

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
sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# 3. Install KDE Plasma, flatpak + apps
pacman -S --noconfirm plasma-meta kde-gtk-config breeze-gtk \
    konsole nemo kate gwenview okular mpv ark elisa flatpak \
    steam kdeconnect kcalc discord sddm
systemctl enable sddm
# Add repos to flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# 4. Install PipeWire (enable for user after first login via linger)
pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
loginctl enable-linger "$username"
# Services will auto-start on first login via socket activation.
# To enable them explicitly for the user session:
su - "$username" -c "
    export XDG_RUNTIME_DIR=/run/user/$(id -u $username)
    systemctl --user enable pipewire pipewire-pulse wireplumber
" || echo "Warning: Could not enable user PipeWire services. They will activate on first login."

# 5. GPU drivers
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

    # Enable NVIDIA DRM modeset for Wayland
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /etc/default/grub

    # Rebuild GRUB and initramfs
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P

    # Vulkan for NVIDIA
    pacman -S --noconfirm vulkan-icd-loader lib32-vulkan-icd-loader

elif [[ "$gpu" =~ ^[Aa]md$ ]]; then
    pacman -S --noconfirm xf86-video-amdgpu mesa mesa-vdpau \
        vulkan-radeon lib32-mesa lib32-vulkan-radeon
else
    echo "Invalid GPU selection. Exiting."
    exit 1
fi

# 6. Install yay (must be built as non-root)
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

read -rp "Setup complete! Reboot now? [y/N]: " reboot_now
if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
    reboot
fi
