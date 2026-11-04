#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

FLAG_FILE="/etc/hasranbefore/true.txt"

# Core function to write presets, build UKIs, set up custom GRUB menu, and regenerate GRUB
apply_configs_and_rebuild() {
  echo "[+] Checking NVIDIA GPU and proprietary driver configuration..."
  read -p "[?] Do you have an NVIDIA GPU with proprietary drivers installed? [y/N]: " nvidia_choice
  EXTRA_PARAMS=""
  case "$nvidia_choice" in
    y|Y )
      echo "[+] Configuring parameters for NVIDIA (nvidia-drm.modeset=1)..."
      EXTRA_PARAMS=" nvidia-drm.modeset=1"
      ;;
    * )
      echo "[+] Skipping NVIDIA specific parameters."
      ;;
  esac

  # Append nvidia parameter to GRUB command line if chosen and missing
  CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub 2>/dev/null | cut -d'"' -f2 || true)
  if [[ "$CURRENT_CMDLINE" != *"nvidia-drm.modeset=1"* ]] && [ -n "$EXTRA_PARAMS" ]; then
    NEW_CMDLINE="${CURRENT_CMDLINE}${EXTRA_PARAMS}"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" /etc/default/grub
  fi

  # Set clean timeout to 5 seconds and enable os-prober for Windows
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub 2>/dev/null || echo "GRUB_TIMEOUT=5" >> /etc/default/grub
  sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub 2>/dev/null || echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

  # Disable default 10_linux script so we don't get duplicate/default entries cluttering the menu
  if [ -x /etc/grub.d/10_linux ]; then
    echo "[+] Disabling default 10_linux script to prevent duplicate entries..."
    chmod -x /etc/grub.d/10_linux
  fi

  echo "[+] Overwriting /etc/mkinitcpio.d/linux.preset with correct UKI paths..."
  mkdir -p /boot/EFI/Linux

  cat << 'EOF' > /etc/mkinitcpio.d/linux.preset
# mkinitcpio preset file for the 'linux' package

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
#ALL_kerneldest="/boot/vmlinuz-linux"

#PRESETS=('default')
PRESETS=('default' 'fallback')

#default_config="/etc/mkinitcpio.conf"
#default_image="/boot/initramfs-linux.img"
default_uki="/boot/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

#fallback_config="/etc/mkinitcpio.conf"
##fallback_image="/boot/initramfs-linux-fallback.img"
fallback_uki="/boot/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

  echo "[+] Generating UKI bundles via mkinitcpio..."
  mkinitcpio -P

  echo "[+] Reinstalling GRUB with shim verification bypassed and TPM support..."
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --modules="tpm" --disable-shim-lock

  echo "[+] Writing clean custom GRUB menu entries in /etc/grub.d/40_custom..."
  cat << 'EOF' > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 $0

menuentry 'Arch Linux' --class arch --class gnu-linux --class gnu --class os {
    insmod efi_gop
    insmod efi_uga
    chainloader /EFI/Linux/arch-linux.efi
}

submenu 'Advanced options for Arch Linux' $menuentry_id_option 'gnulinux-advanced' {
    menuentry 'Arch Linux, with Linux linux' --class arch --class gnu-linux --class gnu --class os {
        insmod efi_gop
        insmod efi_uga
        chainloader /EFI/Linux/arch-linux.efi
    }
    menuentry 'Arch Linux, with Linux linux (recovery mode)' --class arch --class gnu-linux --class gnu --class os {
        insmod efi_gop
        insmod efi_uga
        chainloader /EFI/Linux/arch-linux-fallback.efi
    }
}
EOF
  chmod +x /etc/grub.d/40_custom

  echo "[+] Updating main GRUB configuration..."
  grub-mkconfig -o /boot/grub/grub.cfg

  echo "[+] Ensuring automatic pacman post-transaction hook is up to date..."
  mkdir -p /etc/pacman.d/hooks
  HOOK_FILE="/etc/pacman.d/hooks/sbctl.hook"

  read -r -d '' EXPECTED_HOOK << 'EOF' || true
[Trigger]
Operation = Upgrade
Type = Package
Target = linux
Target = grub
Target = mkinitcpio

[Action]
Description = Automatically rebuilding UKIs and signing EFI binaries for Secure Boot...
When = PostTransaction
Exec = /bin/sh -c 'mkinitcpio -P && sbctl sign-all && grub-mkconfig -o /boot/grub/grub.cfg'
EOF

  if [ -f "$HOOK_FILE" ] && [ "$(cat "$HOOK_FILE")" = "$EXPECTED_HOOK" ]; then
    echo "[+] Pacman hook already exists and matches. Skipping recreation."
  else
    echo "[+] Writing pacman post-transaction hook..."
    echo "$EXPECTED_HOOK" > "$HOOK_FILE"
  fi
}

# Check if we have run before and handle the quick fix branch
if [ -f "$FLAG_FILE" ]; then
  echo "[+] Previous run flag detected at $FLAG_FILE."
  read -p "[?] Do you only want to update/fix GRUB and UKIs without re-enrolling keys or signing? [y/N]: " choice
  case "$choice" in 
    y|Y )
      echo "[+] Running quick update: verifying UKI presets, menu entries, and GRUB (skipping key signing)..."
      apply_configs_and_rebuild
      echo "[SUCCESS] UKI presets, GRUB custom menu, and bootloader have been verified and updated successfully!"
      exit 0
      ;;
    * )
      echo "[+] Proceeding with full installation routine..."
      ;;
  esac
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

echo "[+] Step 4: Creating and enrolling custom Secure Boot keys (with Microsoft OptionROM allowance)..."
sbctl create-keys || true
sbctl enroll-keys --microsoft

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

echo "[+] Step 6: Executing config setup, UKI builds, and GRUB deployment..."
apply_configs_and_rebuild

echo "[+] Step 7: Signing generated UKI EFI binaries and bootloaders..."
[ -f /boot/EFI/Linux/arch-linux.efi ] && sbctl sign -s /boot/EFI/Linux/arch-linux.efi
[ -f /boot/EFI/Linux/arch-linux-fallback.efi ] && sbctl sign -s /boot/EFI/Linux/arch-linux-fallback.efi
[ -f /boot/EFI/GRUB/grubx64.efi ] && sbctl sign -s /boot/EFI/GRUB/grubx64.efi
[ -f /boot/grub/x86_64-efi/core.efi ] && sbctl sign -s /boot/grub/x86_64-efi/core.efi

echo "[+] Step 8: Creating initial run flag file so future executions prompt..."
mkdir -p /etc/hasranbefore
echo "true" > "$FLAG_FILE"

echo "[+] Step 9: Verifying final sbctl database status..."
sbctl verify

echo "[SUCCESS] Complete setup, key enrollment, UKI generation, and GRUB menu setup are complete!"
