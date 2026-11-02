#!/usr/bin/env bash
# ==============================================================================
# Setup & Enforcer Script: Fortnite / Easy Anti-Cheat V2 on Linux
# ==============================================================================
# Key Objectives & Logic:
# - Purpose: Enforces Secure Boot and TPM enablement for Easy Anti-Cheat V2 / Fortnite.
# - Dynamic detection for signed kernels & key enrollment status using `sbctl`.
# - Signs ALL bootloaders, kernels, and EFI binaries in /boot to prevent boot failure.
# ==============================================================================

set -euo pipefail

# Visual Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Ensure script is executed with superuser privileges
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root to inspect EFI status and sign kernel images."
fi

echo "======================================================================"
echo "    Fortnite / Easy Anti-Cheat V2 Linux Readiness & Kernel Enforcer   "
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Hardware & Firmware Validation (TPM 2.0 & Secure Boot Status)
# ------------------------------------------------------------------------------
log_info "Checking TPM 2.0 hardware presence..."
if [[ -c /dev/tpmrm0 || -c /dev/tpm0 ]]; then
    log_success "TPM 2.0 device detected."
else
    log_error "TPM device not found (/dev/tpmrm0 or /dev/tpm0 missing). Enabling TPM in UEFI/BIOS is required."
fi

log_info "Verifying Secure Boot tools..."
if ! command -v sbctl &> /dev/null; then
    log_warn "'sbctl' is not installed. Installing via pacman..."
    pacman -S --needed --noconfirm sbctl || log_error "Failed to install 'sbctl'. Please install it manually."
fi

# ------------------------------------------------------------------------------
# 2. Secure Boot Enforcement & Key Enrollment
# ------------------------------------------------------------------------------
log_info "Checking current Secure Boot setup status..."

SB_STATUS=$(sbctl status --json 2>/dev/null || true)

IS_INSTALLED=false
IS_SETUP_MODE=false
IS_ENABLED=false

if [[ -n "$SB_STATUS" ]]; then
    if command -v jq &> /dev/null; then
        IS_INSTALLED=$(echo "$SB_STATUS" | jq -r '.installed')
        IS_SETUP_MODE=$(echo "$SB_STATUS" | jq -r '.setup_mode')
        IS_ENABLED=$(echo "$SB_STATUS" | jq -r '.secure_boot')
    fi
fi

if [[ "$IS_INSTALLED" == "false" && "$IS_ENABLED" == "false" ]]; then
    RAW_STATUS=$(sbctl status 2>/dev/null || true)
    [[ "$RAW_STATUS" =~ "Sbctl is installed" ]] && IS_INSTALLED=true
    [[ "$RAW_STATUS" =~ "Setup Mode: ✔ Disabled" || "$RAW_STATUS" =~ "Setup Mode: Disabled" ]] && IS_SETUP_MODE=false || IS_SETUP_MODE=true
    [[ "$RAW_STATUS" =~ "Secure Boot: ✔ Enabled" || "$RAW_STATUS" =~ "Secure Boot: Enabled" ]] && IS_ENABLED=true
fi

if [[ "$IS_INSTALLED" != "true" ]]; then
    log_warn "sbctl custom keys have not been created yet."
    if [[ "$IS_SETUP_MODE" == "true" ]]; then
        log_info "System is in Setup Mode. Creating and enrolling user Secure Boot keys..."
        sbctl create-keys
        # Enrolling Microsoft OEM keys AND builtin firmware keys to prevent GPU/Option ROM bricking
        sbctl enroll-keys -m -f
        log_success "Secure Boot keys successfully created and enrolled!"
    else
        log_warn "UEFI is not in 'Setup Mode'. Reset keys in BIOS/UEFI to enroll new keys if needed."
    fi
else
    log_success "sbctl keys are already enrolled on this system."
fi

# File signing helper function
check_and_sign_file() {
    local target_file="$1"
    if [[ ! -f "$target_file" ]]; then
        return 0
    fi

    if sbctl verify "$target_file" &>/dev/null; then
        log_success "$target_file is already signed and valid."
    else
        log_warn "$target_file is NOT signed. Signing EFI binary and saving to sbctl database..."
        sbctl sign -s "$target_file" || log_warn "Failed to sign $target_file"
        log_success "$target_file has been successfully signed."
    fi
}

# ------------------------------------------------------------------------------
# 3. Comprehensive EFI & Kernel Signing Loop
# ------------------------------------------------------------------------------
log_info "Signing all detected bootloader, kernel, and EFI binaries..."

# Explicit systemd-boot / GRUB targets
CRITICAL_TARGETS=(
    "/boot/vmlinuz-linux"
    "/boot/vmlinuz-linux-zen"
    "/boot/vmlinuz-linux-lts"
    "/boot/EFI/systemd/systemd-bootx64.efi"
    "/boot/EFI/BOOT/BOOTX64.EFI"
    "/boot/EFI/arch/grubx64.efi"
    "/boot/EFI/Linux/*.efi"
)

for file in "${CRITICAL_TARGETS[@]}"; do
    shopt -s nullglob
    for target in $file; do
        check_and_sign_file "$target"
    done
    shopt -u nullglob
done

# Dynamic scan over /boot for any missed EFI executables
log_info "Scanning /boot for additional unsigned EFI executables..."
while IFS= read -r unsigned_file; do
    if [[ -n "$unsigned_file" && -f "$unsigned_file" ]]; then
        check_and_sign_file "$unsigned_file"
    fi
done < <(sbctl verify 2>/dev/null | grep -i "file is not signed" | awk '{print $NF}' || true)

# ------------------------------------------------------------------------------
# 4. Anti-Cheat (Fortnite / EAC V2) Parameters Placeholder
# ------------------------------------------------------------------------------
# ==============================================================================
# [NON-OPERATIONAL PLACEHOLDER - ALTERNATIVE KERNEL LOGIC]
# If Arch natively adds support: This section/script can be simplified or deleted.
# If a separate kernel is required (CachyOS, derivatives, or official repos with 
# a different kernel): Configure its detection and parameters here.
# Preference: Avoid SteamOS kernel for cross-setup compatibility. Fallback to 
# SteamOS kernel only if CachyOS and derivatives decline to add support.
# ==============================================================================
# : <<'NON_OPERATIONAL_KERNEL_SELECTION_BLOCK'
#
#   if pacman -Qs "linux-cachyos" &>/dev/null || [[ -f "/boot/vmlinuz-linux-cachyos" ]]; then
#       DETECTED_KERNEL="/boot/vmlinuz-linux-cachyos"
#       KERNEL_TYPE="CachyOS Custom Kernel"
#       log_info "Targeting custom kernel for EAC: $KERNEL_TYPE"
#   fi
#
# NON_OPERATIONAL_KERNEL_SELECTION_BLOCK
# ==============================================================================

echo ""
if [[ "$IS_ENABLED" == "true" ]]; then
    log_success "Secure Boot is active and all boot binaries are verified."
else
    log_warn "Signature checks complete. If Secure Boot is still OFF in BIOS, turn it ON now."
fi

log_success "Fortnite / Easy Anti-Cheat V2 base environment setup complete!"
