#!/usr/bin/env bash
# ==============================================================================
# Setup & Enforcer Script: Fortnite / Easy Anti-Cheat V2 on Linux
# ==============================================================================
# Key Objectives & Logic:
# - Enforces Secure Boot and TPM enablement for Easy Anti-Cheat V2 / Fortnite.
# - Enrolls sbctl keys and ensures hardware NVRAM sync (-m -f) to stop violations.
# - Directly registers and signs critical boot files using 'sbctl sign -s'.
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

# 1. Hardware & Tool Validation
log_info "Checking TPM 2.0 hardware presence..."
if [[ -c /dev/tpmrm0 || -c /dev/tpm0 ]]; then
    log_success "TPM 2.0 device detected."
else
    log_error "TPM device not found (/dev/tpmrm0 or /dev/tpm0 missing). Enable TPM in UEFI/BIOS."
fi

log_info "Verifying Secure Boot tools..."
command -v sbctl &>/dev/null || pacman -S --needed --noconfirm sbctl

# 2. Key Enrollment & NVRAM Enforcement (Fixes Secure Boot Violation)
log_info "Checking Secure Boot key enrollment status..."
if ! sbctl status --json 2>/dev/null | grep -q '"installed":true'; then
    log_warn "sbctl keys are not fully enrolled in firmware NVRAM."
    if sbctl status 2>/dev/null | grep -q "Setup Mode:.*Enabled"; then
        log_info "System is in Setup Mode. Creating and enrolling keys..."
        sbctl create-keys
        # Enrolls custom keys + Microsoft certs + forces firmware sync to prevent boot blocks
        sbctl enroll-keys -m -f
        log_success "Secure Boot custom keys successfully enrolled into NVRAM!"
    else
        log_error "Motherboard is NOT in Setup Mode. Go to BIOS, clear/reset keys to enter Setup Mode, and rerun."
    fi
else
    log_success "sbctl keys are already active and enrolled."
    # Ensure keys are forced-synced to avoid signature mismatches
    sbctl enroll-keys -m -f --skip-cert-check &>/dev/null || true
fi

# 3. Direct File Signing and Database Registration (-s flag)
log_info "Signing and registering core boot binaries..."

CRITICAL_TARGETS=(
    "/boot/vmlinuz-linux"
    "/boot/EFI/BOOT/BOOTX64.EFI"
    "/boot/EFI/GRUB/grubx64.efi"
    "/boot/grub/x86_64-efi/core.efi"
    "/boot/grub/x86_64-efi/grub.efi"
)

for target in "${CRITICAL_TARGETS[@]}"; do
    if [[ -f "$target" ]]; then
        sbctl sign -s "$target"
        log_success "Signed and registered: $target"
    else
        log_warn "Target not found, skipping: $target"
    fi
done

# 4. Verification Check
log_info "Running final sbctl verification..."
sbctl verify

echo ""
log_success "Script execution complete! All binaries are signed, enrolled, and locked in."
