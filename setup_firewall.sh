#!/bin/bash
set -e
# Firewall setup script - home zone configuration
# Generated from firewall-cmd output
# Install and start firewalld if not present
if ! command -v firewall-cmd &>/dev/null; then
    pacman -S --noconfirm firewalld
fi

systemctl enable --now firewalld

# Wait until firewalld is ready
until firewall-cmd --state &>/dev/null; do
    sleep 1
done

ZONE="home"

echo "Configuring firewall zone: $ZONE"

# ── Services ──────────────────────────────────────────────────────────────────
SERVICES=(dhcpv6-client ipp mdns samba-client ssh)
for svc in "${SERVICES[@]}"; do
    firewall-cmd --permanent --zone=$ZONE --add-service="$svc"
done

# ── Custom TCP ports (9942-9945) ───────────────────────────────────────────────
for port in 9942 9944 9945; do
    firewall-cmd --permanent --zone=$ZONE --add-port="${port}/tcp"
done

# ── Custom UDP ports (9942-9945) ───────────────────────────────────────────────
for port in 9942 9944 9945; do
    firewall-cmd --permanent --zone=$ZONE --add-port="${port}/udp"
done

# ── Steam/Game TCP ports (27014-27050) ────────────────────────────────────────
for port in $(seq 27014 27050); do
    firewall-cmd --permanent --zone=$ZONE --add-port="${port}/tcp"
done

# ── Steam/Game UDP ports (27000-27100) ────────────────────────────────────────
for port in $(seq 27000 27100); do
    firewall-cmd --permanent --zone=$ZONE --add-port="${port}/udp"
done

# ── Zone settings ─────────────────────────────────────────────────────────────
firewall-cmd --permanent --zone=$ZONE --set-target=default
firewall-cmd --permanent --zone=$ZONE --remove-icmp-block-inversion 2>/dev/null || true
firewall-cmd --permanent --zone=$ZONE --add-forward

# ── Reload to apply ───────────────────────────────────────────────────────────
firewall-cmd --reload

echo "Done. Current $ZONE zone config:"
firewall-cmd --zone=$ZONE --list-all
