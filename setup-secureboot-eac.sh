#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

echo "[+] Step 1: Checking and installing sbctl if missing..."
if ! pacman -Qi sbctl &>/dev/null; then
  echo "[+] sbctl is not installed. Installing via pacman..."
  pacman -S --noconfirm sbctl
else
  echo "[+] sbctl is already installed."
fi

echo "[+] Step 2: Unlocking EFI variables (clearing immutable flags if present)..."
chattr -i /sys/firmware/efi/efivars/PK-* 2>/dev/null || true
chattr -i /sys/firmware/efi/efivars/KEK-* 2>/dev/null || true
chattr -i /sys/firmware/efi/efivars/db-* 2>/dev/null || true

echo "[+] Step 3: Checking Secure Boot Setup Mode state..."
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

echo "[+] Step 4: Creating and enrolling custom Secure Boot keys..."
sbctl create-keys || true
sbctl enroll-keys || true

echo "[+] Step 5: Cleaning NVRAM stale fallback entries..."
fallback_boot=$(efibootmgr | grep "UEFI OS" | awk '{print $1}' | tr -d '*')
if [ -n "$fallback_boot" ]; then
  for boot_item in $fallback_boot; do
    boot_num=$(echo "$boot_item" | sed 's/Boot//')
    efibootmgr -b "$boot_num" -B || true
  done
fi

grub_boot=$(efibootmgr | grep "GRUB" | awk '{print $1}' | tr -d '*')
if [ -n "$grub_boot" ]; then
  for boot_item in $grub_boot; do
    boot_num=$(echo "$boot_item" | sed 's/Boot//')
    efibootmgr -b "$boot_num" -B || true
  done
fi

echo "[+] Step 6: Reinstalling GRUB with shim verification bypassed and TPM support..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --modules="tpm" --disable-shim-lock

echo "[+] Step 7: Dynamically signing all local boot binaries, kernels, microcode, and initramfs files..."
# Sign GRUB core and EFI binaries
[ -f /boot/EFI/GRUB/grubx64.efi ] && sbctl sign -s /boot/EFI/GRUB/grubx64.efi
[ -f /boot/grub/x86_64-efi/core.efi ] && sbctl sign -s /boot/grub/x86_64-efi/core.efi
[ -f /boot/grub/x86_64-efi/grub.efi ] && sbctl sign -s /boot/grub/x86_64-efi/grub.efi

# Loop and sign all standard and custom kernels
for kernel in /boot/vmlinuz-*; do
  [ -f "$kernel" ] && sbctl sign -s "$kernel"
done

# Loop and sign all initramfs images
for initramfs in /boot/initramfs-*.img; do
  [ -f "$initramfs" ] && sbctl sign -s "$initramfs"
done

# Loop and sign CPU microcode files (intel-ucode, amd-ucode)
for ucode in /boot/*-ucode.img; do
  [ -f "$ucode" ] && sbctl sign -s "$ucode"
done

# --- Alternative / Separate Custom Kernels (Uncomment when installed) ---
# sbctl sign -s /boot/vmlinuz-linux-cachyos
# sbctl sign -s /boot/vmlinuz-linux-neptune
# sbctl sign -s /boot/vmlinuz-linux-eac

echo "[+] Step 8: Creating automatic pacman post-transaction hook..."
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

[Action]
Description = Automatically signing EFI binaries and boot files for Secure Boot...
When = PostTransaction
Exec = /usr/bin/sbctl sign-all
EOF

echo "[+] Step 9: Verifying final sbctl database status..."
sbctl verify

echo "[SUCCESS] sbctl installation, Secure Boot configuration, GRUB setup, and dynamic signing loops are fully set up!"
