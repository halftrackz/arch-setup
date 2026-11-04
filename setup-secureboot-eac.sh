#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

FLAG_FILE="/etc/hasranbefore/true.txt"
BACKUP_DIR="/etc/hasranbefore"

# Core function to write presets, build UKIs, move 10_linux to the flag folder, set up 05_custom, and regenerate GRUB
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

  # Ensure backup directory exists
  mkdir -p "$BACKUP_DIR"

  # Move 10_linux into the flag folder directory as 10_linux.bak so GRUB ignores it completely
  if [ -f /etc/grub.d/10_linux ]; then
    echo "[+] Moving /etc/grub.d/10_linux to $BACKUP_DIR/10_linux.bak..."
    mv /etc/grub.d/10_linux "$BACKUP_DIR/10_linux.bak"
  elif [ -f "$BACKUP_DIR/10_linux.bak" ]; then
    echo "[+] $BACKUP_DIR/10_linux.bak already exists. Skipping move."
  fi

  echo "[+] Overwriting /etc/mkinitcpio.d/linux.preset with correct UKI paths..."
  mkdir -p /boot/EFI/Linux

  cat << 'EOF' > /etc/mkinitcpio.d/linux.preset
# mkinitcpio preset file for the 'linux' package

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

default_uki="/boot/EFI/Linux/arch-linux.efi"
fallback_uki="/boot/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

  echo "[+] Generating UKI bundles via mkinitcpio..."
  mkinitcpio -P

  echo "[+] Reinstalling GRUB with shim verification bypassed and TPM support..."
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --modules="tpm" --disable-shim-lock

  # Clean up old conflicting custom files
  rm -f /etc/grub.d/40_custom /etc/grub.d/41_custom /etc/grub.d/05_custom_uki

  echo "[+] Creating clean top-priority custom GRUB script in /etc/grub.d/05_custom..."
  cat << 'EOF' > /etc/grub.d/05_custom
#!/bin/sh
exec tail -n +3 $0

cat << 'EOF'
menuentry 'Arch Linux' --class arch --class gnu-linux --class gnu --class os {
    insmod efi_gop
    echo "Booting 'Arch Linux'"
    sleep 1
    echo "Loading Linux, linux ..."
    sleep 1
    echo "Loading initial ramdisk ..."
    sleep 1
    chainloader /EFI/Linux/arch-linux.efi
}

submenu 'Advanced options for Arch Linux' $menuentry_id_option 'gnulinux-advanced' {
    menuentry 'Arch Linux, with Linux linux' --class arch --class gnu-linux --class gnu --class os {
        insmod efi_gop
        echo "Booting 'Arch Linux'"
        sleep 1
        echo "Loading Linux, linux ..."
        sleep 1
        echo "Loading initial ramdisk ..."
        sleep 1
        chainloader /EFI/Linux/arch-linux.efi
    }
    menuentry 'Arch Linux, with Linux linux (recovery mode)' --class arch --class gnu-linux --class gnu --class os {
        insmod efi_gop
        echo "Booting 'Arch Linux'"
        sleep 1
        echo "Loading Recovery Arch Kernel!"
        sleep 1
        echo "Loading initial ramdisk ..."
        sleep 1
        chainloader /EFI/Linux/arch-linux-fallback.efi
    }
}
EOF
EOF
  chmod +x /etc/grub.d/05_custom

  echo "[+] Updating main GRUB configuration..."
  grub-mkconfig -o /boot/grub/grub.cfg

  echo "[+] Ensuring automatic pacman post-transaction hook is up to date..."
  mkdir -p /etc/pacman.d/hooks
  HOOK_FILE="/etc/pacman.d/hooks/sbctl.hook"

  read -r -d '' EXPECTED_HOOK << 'HOOKEOF' || true
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
HOOKEOF

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
      echo "[+] Running quick update: verifying UKI presets, backup, 05_custom menu, and GRUB..."
      apply_configs_and_rebuild
      echo "[SUCCESS] UKI presets, static loading messages, and GRUB have been updated successfully!"
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

SB_STATUS=$(sbctl status | grep "Setup Mode" | awk '{print $3}')
if [ "$SB_STATUS" = "Disabled" ] || [ "$SB_STATUS" = "false" ]; then
  echo "[-] ERROR: Setup Mode is currently disabled in your motherboard's NVRAM."
  exit 1
else
  echo "[+] Setup Mode is verified as Enabled. Proceeding with key enrollment..."
fi

echo "[+] Step 4: Creating and enrolling custom Secure Boot keys..."
sbctl create-keys || true
sbctl enroll-keys --microsoft

echo "[+] Step 6: Executing config setup, UKI builds, and GRUB deployment..."
apply_configs_and_rebuild

echo "[+] Step 7: Signing generated UKI EFI binaries and bootloaders..."
[ -f /boot/EFI/Linux/arch-linux.efi ] && sbctl sign -s /boot/EFI/Linux/arch-linux.efi
[ -f /boot/EFI/Linux/arch-linux-fallback.efi ] && sbctl sign -s /boot/EFI/Linux/arch-linux-fallback.efi
[ -f /boot/EFI/GRUB/grubx64.efi ] && sbctl sign -s /boot/EFI/GRUB/grubx64.efi
[ -f /boot/grub/x86_64-efi/core.efi ] && sbctl sign -s /boot/grub/x86_64-efi/core.efi

echo "[+] Step 8: Creating initial run flag file..."
mkdir -p "$BACKUP_DIR"
echo "true" > "$FLAG_FILE"

echo "[SUCCESS] Complete setup, key enrollment, UKI generation, and GRUB custom menu setup are complete!"
