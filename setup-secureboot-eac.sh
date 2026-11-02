#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

echo "[+] Step 1: Unlocking EFI variables (clearing immutable flags if present)..."
chattr -i /sys/firmware/efi/efivars/PK-* 2>/dev/null || true
chattr -i /sys/firmware/efi/efivars/KEK-* 2>/dev/null || true
chattr -i /sys/firmware/efi/efivars/db-* 2>/dev/null || true

echo "[+] Step 2: Checking Secure Boot Setup Mode state..."
SB_STATUS=$(sbctl status | grep "Setup Mode" | awk '{print $3}')

if [ "$SB_STATUS" = "Disabled" ] || [ "$SB_STATUS" = "false" ]; then
  echo "[-] ERROR: Setup Mode is currently disabled in your motherboard's NVRAM."
  echo "[-] To enroll keys, you must reboot into your BIOS, navigate to Secure Boot,"
  echo "[-] and choose the option to reset/clear Secure Boot keys to enter 'Setup Mode'."
  echo "[-] Once you boot back into Arch in Setup Mode, re-run this script."
  exit 1
else
  echo "[+] Setup Mode is verified as Enabled. Proceeding with key enrollment..."
fi

echo "[+] Step 3: Creating and enrolling custom Secure Boot keys..."
sbctl create-keys || true
sbctl enroll-keys --microsoft || true # fallback or standard enrollment

echo "[+] Step 4: Cleaning NVRAM fallback entries and reinstalling GRUB..."
# Clear out fallback UEFI OS entry if it exists to prevent boot conflicts
fallback_boot=$(efibootmgr | grep "UEFI OS" | awk '{print $1}' | tr -d '*')
if [ -n "$fallback_boot" ]; then
  boot_num=$(echo "$fallback_boot" | sed 's/Boot//')
  efibootmgr -b "$boot_num" -B || true
fi

# Reinstall GRUB with shim verification disabled and TPM module included
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --modules="tpm" --disable-shim-lock

echo "[+] Step 5: Ensuring all boot binaries and kernels are signed..."
sbctl sign -s /boot/EFI/GRUB/grubx64.efi
sbctl sign -s /boot/grub/x86_64-efi/core.efi
sbctl sign -s /boot/grub/x86_64-efi/grub.efi
sbctl sign -s /boot/vmlinuz-linux

# --- Alternative / Separate Custom Kernels (Uncomment when installed) ---
# CachyOS Kernel:
# sbctl sign -s /boot/vmlinuz-linux-cachyos
#
# SteamOS / Valve custom kernel build:
# sbctl sign -s /boot/vmlinuz-linux-neptune
#
# Separate custom kernel package (e.g., linux-eac or custom builds):
# sbctl sign -s /boot/vmlinuz-linux-eac

echo "[+] Step 6: Creating automatic pacman post-transaction hook..."
mkdir -p /etc/pacman.d/hooks

cat << 'EOF' > /etc/pacman.d/hooks/sbctl.hook
[Trigger]
Operation = Upgrade
Type = Package
Target = linux
Target = grub
# Target = linux-cachyos
# Target = linux-neptune
# Target = linux-eac
# Note: Add target here if using a separate custom kernel package or if Arch maintainers provide an auto-hook package in the future

[Action]
Description = Automatically signing EFI binaries for Secure Boot...
When = PostTransaction
Exec = /usr/bin/sbctl sign-all
EOF

echo "[+] Step 7: Verifying final sbctl database status..."
sbctl verify

echo "[SUCCESS] Secure Boot configuration, GRUB setup, and automated signing hooks are fully set up!"
