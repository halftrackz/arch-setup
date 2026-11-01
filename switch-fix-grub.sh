#!/bin/bash
# Standalone Arch Linux Bootloader & GRUB Fixer
# Must be run as root

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[-] This script must be run as root."
    exit 1
fi

echo "[*] Detecting current bootloader status..."

current_bl="unknown"
if [[ -f /etc/default/grub ]]; then
    current_bl="grub"
    echo "[+] Current bootloader detected: GRUB"
elif bootctl status &>/dev/null || [[ -d /boot/loader ]] || [[ -d /efi/loader ]]; then
    current_bl="systemd-boot"
    echo "[+] Current bootloader detected: systemd-boot"
else
    echo "[?] Unrecognized or missing bootloader configuration."
fi

# 1. Bootloader Switch / Fix Logic (only runs if NOT already GRUB)
if [[ "$current_bl" != "grub" ]]; then
    read -rp "[Confirmation Required] GRUB is not your active bootloader (Detected: $current_bl). Do you want to switch to GRUB, remove the old bootloader, and configure it? [y/N]: " confirm_grub
    if [[ "$confirm_grub" =~ ^[Yy]$ ]]; then
        echo "[*] Switching to GRUB..."

        if [[ "$current_bl" == "systemd-boot" ]]; then
            echo "[*] Removing systemd-boot files..."
            bootctl remove 2>/dev/null || true
            rm -rf /boot/EFI/systemd /boot/loader /efi/EFI/systemd /efi/loader /boot/efi/EFI/systemd /boot/efi/loader
        fi

        echo "[*] Installing GRUB and efibootmgr..."
        pacman -S --noconfirm grub efibootmgr

        efi_mount="/boot"
        if mountpoint -q /boot/efi; then
            efi_mount="/boot/efi"
        elif mountpoint -q /efi; then
            efi_mount="/efi"
        fi

        echo "[*] Installing GRUB to EFI directory: $efi_mount"
        grub-install --target=x86_64-efi --efi-directory="$efi_mount" --bootloader-id=GRUB
        mkdir -p /boot/grub
        grub-mkconfig -o /boot/grub/grub.cfg
        current_bl="grub"
        echo "[+] Successfully switched to GRUB!"
    else
        echo "[-] GRUB switch declined. Skipping bootloader replacement."
    fi
fi

# 2. GRUB Settings Tweaks (BootNext & OS Prober - asked if on GRUB)
if [[ "$current_bl" == "grub" ]] && [[ -f /etc/default/grub ]]; then
    grub_updated=false

    read -rp "[Prompt] Do you want to disable EFI BootNext entries from showing in the GRUB menu? [y/N]: " confirm_bootnext
    if [[ "$confirm_bootnext" =~ ^[Yy]$ ]]; then
        echo "GRUB_DISABLE_BOOTNEXT=true" >> /etc/default/grub
        grub_updated=true
        echo "[+] EFI BootNext entries disabled."

        read -rp "[Prompt] Since you adjusted BootNext, do you also want to enable os-prober to detect other operating systems (like Windows)? [y/N]: " confirm_osprober
        if [[ "$confirm_osprober" =~ ^[Yy]$ ]]; then
            pacman -S --noconfirm os-prober
            if grep -q "^#*GRUB_DISABLE_OS_PROBER" /etc/default/grub; then
                sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
            else
                echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
            fi
            grub_updated=true
            echo "[+] os-prober installed and enabled."
        fi
    fi

    if [[ "$grub_updated" == "true" ]]; then
        echo "[*] Re-generating GRUB configuration..."
        grub-mkconfig -o /boot/grub/grub.cfg
        echo "[+] GRUB configuration updated successfully."
    fi
else
    echo "[-] GRUB configuration file (/etc/default/grub) not found or GRUB is not active. Skipping tweaks."
fi

echo "[+] Standalone bootloader check & fix complete!"
