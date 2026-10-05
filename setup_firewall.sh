#!/bin/bash
set -e
# Firewall setup script - public zone configuration

# Install and start firewalld if not present
if ! command -v firewall-cmd &>/dev/null; then
    pacman -S --noconfirm firewalld
fi

systemctl enable --now firewalld

# Wait until firewalld is ready
until firewall-cmd --state &>/dev/null; do
    sleep 1
done

ZONE="public"

echo "Configuring firewall zone: $ZONE"

# ── Base Services ─────────────────────────────────────────────────────────────
SERVICES=(dhcpv6-client ipp mdns samba-client ssh)
for svc in "${SERVICES[@]}"; do
    firewall-cmd --permanent --zone="$ZONE" --add-service="$svc"
done

# ── Jellyfin Media Server ─────────────────────────────────────────────────────
read -rp "Is this a Jellyfin server? (y/N): " jelly
if [[ "${jelly,,}" == "y"* ]]; then
    echo "Opening Jellyfin ports..."
    firewall-cmd --permanent --zone="$ZONE" --add-port=8096/tcp
    firewall-cmd --permanent --zone="$ZONE" --add-port=8920/tcp
    firewall-cmd --permanent --zone="$ZONE" --add-port=1900/udp
    firewall-cmd --permanent --zone="$ZONE" --add-port=7359/udp
fi

# ── Primary Minecraft Server ──────────────────────────────────────────────────
read -rp "Is this a Minecraft server? (y/N): " mc
if [[ "${mc,,}" == "y"* ]]; then
    echo "Opening primary Minecraft ports (25565/tcp, 19132/udp)..."
    firewall-cmd --permanent --zone="$ZONE" --add-port=25565/tcp
    firewall-cmd --permanent --zone="$ZONE" --add-port=19132/udp
fi

# ── Secondary Minecraft Server ────────────────────────────────────────────────
read -rp "Are you running a 2nd Minecraft server? (y/N): " mc2
if [[ "${mc2,,}" == "y"* ]]; then
    echo "Opening secondary Minecraft server port (25566/tcp)..."
    firewall-cmd --permanent --zone="$ZONE" --add-port=25566/tcp
fi

# ── Sunshine Desktop Streaming ────────────────────────────────────────────────
read -rp "Are you running Sunshine (Moonlight Host)? (y/N): " sunshine
if [[ "${sunshine,,}" == "y"* ]]; then
    echo "Opening Sunshine streaming ports..."
    firewall-cmd --permanent --zone="$ZONE" --add-port=47984-47990/tcp
    firewall-cmd --permanent --zone="$ZONE" --add-port=47998-48010/udp
fi

# ── Custom ports (ALVR) ───────────────────────────────────────────────────────
read -rp "Are you using ALVR? (y/N): " alvr
if [[ "${alvr,,}" == "y"* ]]; then
    for port in 9942 9944 9945; do
        firewall-cmd --permanent --zone="$ZONE" --add-port="${port}/tcp"
        firewall-cmd --permanent --zone="$ZONE" --add-port="${port}/udp"
    done
fi

# ── Steam/Game ports ──────────────────────────────────────────────────────────
read -rp "Are you running Steam dedicated game servers? (y/N): " steam
if [[ "${steam,,}" == "y"* ]]; then
    firewall-cmd --permanent --zone="$ZONE" --add-port=27014-27050/tcp
    firewall-cmd --permanent --zone="$ZONE" --add-port=27000-27100/udp
fi

# ── Reload to apply ───────────────────────────────────────────────────────────
firewall-cmd --reload

echo "Done. Current $ZONE zone config:"
firewall-cmd --zone="$ZONE" --list-all
