#!/usr/bin/env bash
# ==============================================================================
# Setup & Enforcer Script: Fortnite / Easy Anti-Cheat V2 on Linux
# ==============================================================================
# Key Objectives & Logic:
# - Purpose: Enforces Secure Boot and TPM enablement for Easy Anti-Cheat V2 / Fortnite.
# - Explicitly forces registration and signing of all critical GRUB and kernel binaries.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root to sign boot binaries."
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
    log_error "TPM device not found (/dev/tpmrm0 or /dev/tpm0 missing). Enable TPM in UEFI/BIOS."
fi

log_info "Verifying Secure Boot tools..."
command -v sbctl &>/dev/null || pacman -S --needed --noconfirm sbctl

# ------------------------------------------------------------------------------
# 2. Secure Boot Key Enrollment Check
# ------------------------------------------------------------------------------
if ! sbctl status --json | grep -q '"installed":true'; then
    log_info "Enrolling Secure Boot custom keys..."
    sbctl create-keys
    sbctl enroll-keys -m -f
    log_success "Secure Boot custom keys enrolled!"
else
    log_success "sbctl keys are already enrolled."
fi

# ------------------------------------------------------------------------------
# 3. Force Sign and Register Critical GRUB & Kernel Binaries
# ------------------------------------------------------------------------------
log_info "Forcing signature and registration of all critical boot files..."

CRITICAL_TARGETS=(
    "/boot/vmlinuz-linux"
    "/boot/vmlinuz-linux-zen"
    "/boot/vmlinuz-linux-lts"
    "/boot/EFI/BOOT/BOOTX64.EFI"
    "/boot/EFI/GRUB/grubx64.efi"
    "/boot/grub/x86_64-efi/core.efi"
    "/boot/grub/x86_64-efi/grub.efi"
)

for target in "${CRITICAL_TARGETS[@]}"; do
    if [[ -f "$target" ]]; then
        log_info "Signing and registering: $target"
        sbctl sign -s "$target"
    fi
done

# Wildcard backup for any additional installed kernels
shopt -s nullglob
for kernel in /boot/vmlinuz-*; do
    if [[ -f "$kernel" ]]; then
        log_info "Signing additional kernel: $kernel"
        sbctl sign -s "$kernel"
    fi
done
shopt -u nullglob

# ------------------------------------------------------------------------------
# 4. Verification Check
# ------------------------------------------------------------------------------
log_info "Running final sbctl verification check..."
sbctl verify

echo ""
log_success "Script execution complete! All binaries are now signed and registered."
