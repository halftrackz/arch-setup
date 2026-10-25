#!/bin/bash
set -eo pipefail

# ── Trap SIGINT (Ctrl+C) to exit cleanly without swallowing signal ─────────
trap 'echo -e "\nScript aborted by user."; exit 130' INT

# ── Root Privilege Check ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

# ── Interactive Terminal Check ────────────────────────────────────────────────
if [[ ! -t 0 ]]; then
    echo "Error: Script requires an interactive terminal (TTY)." >&2
    exit 1
fi

# ── Install firewalld if missing (Arch Linux) ─────────────────────────────────
if ! command -v firewall-cmd &>/dev/null; then
    if [[ -f /var/lib/pacman/db.lck ]]; then
        echo "Error: Pacman database is locked (/var/lib/pacman/db.lck)." >&2
        exit 1
    fi
    echo "Installing firewalld..."
    pacman -S --noconfirm firewalld
fi

systemctl enable --now firewalld

# ── Wait for daemon startup (safe arithmetic under set -e) ───────────────────
echo "Waiting for firewalld service..."
TIMEOUT=15
while ! firewall-cmd --state &>/dev/null; do
    sleep 1
    TIMEOUT=$((TIMEOUT - 1)) || true
    if [[ "$TIMEOUT" -le 0 ]]; then
        echo "Error: firewalld failed to start within 15 seconds." >&2
        exit 1
    fi
done

# ── Detect Active Zone safely ─────────────────────────────────────────────────
RAW_ZONE=$(firewall-cmd --get-active-zones 2>/dev/null | grep -v '^[[:space:]]' | head -n1 | awk '{print $1}' || true)
ZONE="${RAW_ZONE:-public}"
echo "Configuring firewall zone: $ZONE"

# Helper functions to add permanent rules and report failures
add_port() {
    if ! firewall-cmd --permanent --zone="$ZONE" --add-port="$1" &>/dev/null; then
        echo "Error: Failed to add port $1 to zone $ZONE." >&2
    fi
}

add_svc() {
    if ! firewall-cmd --permanent --zone="$ZONE" --add-service="$1" &>/dev/null; then
        echo "Error: Failed to add service $1 to zone $ZONE." >&2
    fi
}

# LAN-only port helper for 192.168.0.0/16
add_lan_port() {
    local port="$1"
    local proto="$2"

    if ! firewall-cmd --permanent --zone="$ZONE" \
        --add-rich-rule="rule family=\"ipv4\" source address=\"192.168.0.0/16\" port port=\"$port\" protocol=\"$proto\" accept" \
        &>/dev/null; then
        echo "Error: Failed to add LAN-only rule for $port/$proto to zone $ZONE." >&2
    fi
}

# Safe input handler using underscored namerefs (prevents circular scope traps)
prompt_yn() {
    local __prompt_text="$1"
    local -n __var_ref="$2"
    read -rp "$__prompt_text" __var_ref || true
}

# Strict (y/N) evaluator
is_yes() {
    local input="${1,,}"
    [[ "$input" =~ ^(y|yes)$ ]]
}

# ── Jellyfin Media Server ─────────────────────────────────────────────────────
prompt_yn "Is this a Jellyfin server? (y/N) [default: N]: " jelly
if is_yes "${jelly:-n}"; then
    echo "Opening Jellyfin port (8096/tcp)..."
    add_port "8096/tcp"
fi

# ── Minecraft Servers ─────────────────────────────────────────────────────────
prompt_yn "Are you running a Minecraft server? (y/N) [default: N]: " mc
if is_yes "${mc:-n}"; then
    echo "Opening Minecraft port (25565/tcp)..."
    add_port "25565/tcp"

    prompt_yn "Are you running a second Minecraft server? (y/N) [default: N]: " mc2
    if is_yes "${mc2:-n}"; then
        echo "Opening second Minecraft port (25566/tcp)..."
        add_port "25566/tcp"
    fi
fi

# ── Sunshine Desktop Streaming ────────────────────────────────────────────────
prompt_yn "Are you running Sunshine (Moonlight Host)? (y/N) [default: N]: " sunshine
if is_yes "${sunshine:-n}"; then
    echo "Opening Sunshine streaming ports (LAN only)..."
    add_lan_port "47984-47990" "tcp"
    add_lan_port "48010" "tcp"
    add_lan_port "47998-48000" "udp"
fi

# ── Custom ports (ALVR) ───────────────────────────────────────────────────────
prompt_yn "Are you using ALVR? (y/N) [default: N]: " alvr
if is_yes "${alvr:-n}"; then
    echo "Opening ALVR ports..."
    for port in 9942 9943 9944 9945; do
        add_port "${port}/tcp"
        add_port "${port}/udp"
    done
fi

# ── Steam Link / SteamVR ──────────────────────────────────────────────────────
prompt_yn "Are you using Steam Link / SteamVR streaming? (y/N) [default: N]: " steamvr
if is_yes "${steamvr:-n}"; then
    echo "Opening Steam Link / SteamVR ports (LAN only)..."
    add_lan_port "27031" "udp"
    add_lan_port "27036" "udp"
    add_lan_port "27036" "tcp"
    add_lan_port "27037" "tcp"
    add_lan_port "10400-10401" "udp"
fi

# ── Steam/Game ports ──────────────────────────────────────────────────────────
prompt_yn "Are you running Steam dedicated game servers? (y/N) [default: N]: " steam
if is_yes "${steam:-n}"; then
    echo "Opening Steam server ports..."
    add_port "27014-27050/tcp"
    add_port "27000-27100/udp"
fi

# ── Reload & Verify ───────────────────────────────────────────────────────────
echo "Reloading firewall rule definitions..."
if ! firewall-cmd --reload; then
    echo "Error: Failed to reload firewalld." >&2
    exit 1
fi

echo "Done. Active zone ($ZONE) configuration:"
if ! firewall-cmd --zone="$ZONE" --list-all; then
    echo "Error: Failed to display the active zone configuration." >&2
    exit 1
fi
