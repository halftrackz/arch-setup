#!/usr/bin/env bash
# ==============================================================================
# Setup & Enforcer Script: Fortnite / Easy Anti-Cheat V2 on Linux
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
   log_error "This script must be run as root."
fi

echo "======================================================================"
echo "    Fortnite / Easy Anti-Cheat V2 Linux Readiness & Kernel Enforcer   "
echo "======================================================================"

# 1. Hardware checks
log_info "Verifying Secure Boot tools..."
command -v sbctl &>/dev/null || pacman -S --needed --noconfirm sbctl

# 2. Key Check
if ! sbctl status --json | grep -q '"installed":true'; then
    log_info "Enrolling Secure Boot custom keys..."
    sbctl create-keys
    sbctl enroll-keys -m -f
fi

# 3. Force Sign Critical Targets (Registers them directly into sbctl database)
log_info "Forcing signature and registration of all critical boot binaries..."

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

# Wildcard backup for any other kernels
shopt -s nullglob
for kernel in /boot/vmlinuz-*; do
    if [[ -f "$kernel" ]]; then
        log_info "Signing kernel: $kernel"
        sbctl sign -s "$kernel"
    fi
done
shopt -u nullglob

log_success "All binaries successfully signed and registered!"
sbctl verify
