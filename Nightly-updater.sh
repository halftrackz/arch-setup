#!/bin/bash
set -e

SCRIPT_PATH="/usr/local/bin/system-update.sh"
SERVICE_PATH="/etc/systemd/system/system-update.service"
TIMER_PATH="/etc/systemd/system/system-update.timer"
SUDOERS_DROPIN="/etc/sudoers.d/system-update-yay"
LOG_DIR="/var/log/nightly-update-errors"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this installation script as root (sudo)."
  exit 1
fi

echo "=== [1/7] Detecting Non-Root System Users ==="

# Get regular users with home directories in /home and UID >= 1000
mapfile -t USERS < <(awk -F: '$3 >= 1000 && $6 ~ /^\/home/ {print $1}' /etc/passwd)

USER_COUNT=${#USERS[@]}

if [ "$USER_COUNT" -eq 0 ]; then
  echo "Error: No regular users found with a home directory in /home."
  exit 1
elif [ "$USER_COUNT" -eq 1 ]; then
  TARGET_USER="${USERS[0]}"
  echo "Auto-detected single user: $TARGET_USER"
else
  echo "Multiple users detected on system:"
  for i in "${!USERS[@]}"; do
    echo "  $((i+1))) ${USERS[$i]}"
  done

  while true; do
    read -p "Select the user to run yay (1-$USER_COUNT): " SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$USER_COUNT" ]; then
      TARGET_USER="${USERS[$((SELECTION-1))]}"
      break
    else
      echo "Invalid selection. Please enter a number between 1 and $USER_COUNT."
    fi
  done
  echo "Selected user: $TARGET_USER"
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

echo "=== [2/7] Creating Log Directory at $LOG_DIR ==="
mkdir -p "$LOG_DIR"
chmod 0750 "$LOG_DIR"

echo "=== [3/7] Checking Sudoers Configuration for $TARGET_USER ==="

if sudo -l -U "$TARGET_USER" 2>/dev/null | grep -q "NOPASSWD: ALL"; then
  echo "User $TARGET_USER already has full passwordless root privileges. Skipping sudoers modification."
else
  echo "Configuring passwordless pacman privileges for $TARGET_USER in $SUDOERS_DROPIN..."
  echo "$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "$SUDOERS_DROPIN"
  chmod 0440 "$SUDOERS_DROPIN"
  
  if visudo -cf "$SUDOERS_DROPIN" > /dev/null 2>&1; then
    echo "Sudoers drop-in successfully verified."
  else
    echo "Error: Sudoers rule syntax check failed! Removing file."
    rm -f "$SUDOERS_DROPIN"
    exit 1
  fi
fi

echo "=== [4/7] Writing system update script to $SCRIPT_PATH ==="

cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
set -e

LOG_DIR="$LOG_DIR"
TARGET_USER="$TARGET_USER"
TARGET_HOME="$TARGET_HOME"

# Error Handler function to record failures
log_error() {
  local exit_code=\$1
  local line_no=\$2
  local last_cmd=\$3
  local log_file="\$LOG_DIR/update-error-\$(date +%Y%m%d-%H%M%S).log"
  
  mkdir -p "\$LOG_DIR"
  {
    echo "=================================================="
    echo "Nightly Update Failure Report"
    echo "Timestamp : \$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Failed Cmd: \$last_cmd"
    echo "Line No.  : \$line_no"
    echo "Exit Code : \$exit_code"
    echo "=================================================="
  } >> "\$log_file"
  echo "ERROR: Nightly update step failed. Details written to \$log_file" >&2
}

# Trap ERR signals to automatically execute log_error
trap 'log_error \$? \$LINENO "\$BASH_COMMAND"' ERR

# Capture epoch timestamp 5 seconds prior to compensate for FAT32 / NTP clock adjustments
UPDATE_START_TIME=\$((\$(date +%s) - 5))

# Wait up to 30 seconds for active network connectivity before failing
echo "Checking network connectivity..."
MAX_RETRIES=10
RETRY_COUNT=0
until ping -c 1 archlinux.org >/dev/null 2>&1 || [ \$RETRY_COUNT -ge \$MAX_RETRIES ]; do
  RETRY_COUNT=\$((RETRY_COUNT + 1))
  echo "Waiting for network connection... (\$RETRY_COUNT/\$MAX_RETRIES)"
  sleep 3
done

if [ \$RETRY_COUNT -ge \$MAX_RETRIES ]; then
  echo "Error: Network connectivity unavailable after \$MAX_RETRIES attempts." >&2
  false
fi

# Ensure pacman database isn't locked by a stalled process
if [ -f /var/lib/pacman/db.lck ]; then
  echo "Warning: /var/lib/pacman/db.lck exists. Checking if pacman is actively running..."
  if ! pgrep -x pacman > /dev/null 2>&1; then
    echo "Stale pacman lockfile found with no active process. Removing /var/lib/pacman/db.lck..."
    rm -f /var/lib/pacman/db.lck
  fi
fi

echo "=== [1/3] Running pacman system update ==="
/usr/bin/pacman -Syu --noconfirm

echo "=== [2/3] Running yay (AUR updates) ==="
YAY_BIN=\$(command -v yay || echo "")
if [ -z "\$YAY_BIN" ] && [ -x /usr/local/bin/yay ]; then
  YAY_BIN="/usr/local/bin/yay"
elif [ -z "\$YAY_BIN" ] && [ -x /usr/bin/yay ]; then
  YAY_BIN="/usr/bin/yay"
fi

if [ -n "\$YAY_BIN" ]; then
  # Flags --nodiffmenu --noeditmenu force yay to stay non-interactive in systemd background runs
  if ! HOME="\$TARGET_HOME" XDG_CACHE_HOME="\$TARGET_HOME/.cache" /usr/bin/runuser -u "\$TARGET_USER" -- \
    "\$YAY_BIN" -Sua --noconfirm --needed --nodiffmenu --noeditmenu --no-use-ask; then
      echo "Warning: yay AUR update encountered errors." >&2
      mkdir -p "\$LOG_DIR"
      echo "[\$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Warning: yay update failed or finished with non-zero exit code." >> "\$LOG_DIR/aur-warnings.log"
  fi
else
  echo "yay not found in PATH or standard bin directories. Skipping AUR updates."
fi

echo "=== [3/3] Checking Flatpak updates ==="
if command -v flatpak &>/dev/null; then
  if ! flatpak update -y; then
    echo "Warning: Flatpak update encountered errors." >&2
    mkdir -p "\$LOG_DIR"
    echo "[\$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Warning: Flatpak update failed or finished with non-zero exit code." >> "\$LOG_DIR/flatpak-warnings.log"
  fi
else
  echo "Flatpak not installed. Skipping."
fi

echo "=== Updates complete! Checking reboot conditions... ==="

NEED_REBOOT=0
RUNNING_KERNEL=\$(uname -r)

# 1. Check if running kernel package was updated or uninstalled
if [ ! -f "/usr/lib/modules/\$RUNNING_KERNEL/pkgbase" ]; then
  echo "[TRIGGER] Running kernel package was replaced/updated."
  NEED_REBOOT=1
fi

# 2. Check if initramfs, kernel images, or UKIs were created/modified during this update run
shopt -s nullglob
BOOT_IMAGES=(/boot/initramfs-*.img /boot/vmlinuz-* /boot/EFI/Linux/*.efi)
shopt -u nullglob

for img in "\${BOOT_IMAGES[@]}"; do
  if [ -f "\$img" ]; then
    MOD_TIME=\$(stat -c %Y "\$img" 2>/dev/null || echo 0)
    if [ "\$MOD_TIME" -ge "\$UPDATE_START_TIME" ]; then
      echo "[TRIGGER] Boot image (\$(basename "\$img")) was modified during update."
      NEED_REBOOT=1
      break
    fi
  fi
done

# 3. Check if driver modules were updated/built during this update run
if [ "\$NEED_REBOOT" -eq 0 ] && [ -d "/usr/lib/modules/\$RUNNING_KERNEL/" ]; then
  UPDATED_DRIVERS=\$(find /usr/lib/modules/\$RUNNING_KERNEL/ -type f -newermt "@\$UPDATE_START_TIME" 2>/dev/null | wc -l || echo 0)
  if [ "\$UPDATED_DRIVERS" -gt 0 ]; then
    echo "[TRIGGER] \$UPDATED_DRIVERS kernel drivers/modules were modified or compiled during update."
    NEED_REBOOT=1
  fi
fi

if [ "\$NEED_REBOOT" -eq 1 ]; then
  echo "Reboot trigger detected. Initiating system reboot..."
  /usr/bin/systemctl reboot
else
  echo "No kernel, initramfs, microcode, or driver changes detected. Service finished without rebooting."
fi
EOF

chmod 755 "$SCRIPT_PATH"

echo "=== [5/7] Creating systemd service ==="

cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Nightly System and AUR Update Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
TimeoutStartSec=infinity
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

echo "=== [6/7] Creating systemd timer ==="

cat << EOF > "$TIMER_PATH"
[Unit]
Description=Timer for Nightly System and AUR Update Service

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "=== [7/7] Reloading and Enabling Systemd Services ==="
systemctl daemon-reload
systemctl enable --now system-update.timer

echo "=== Setup complete! Scheduled daily at 4:30 AM for user '$TARGET_USER'. ==="
echo "Logs will be written to $LOG_DIR if failures occur."

read -p "Would you like to test the update service now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting system-update.service..."
    systemctl start system-update.service
else
    echo "Skipping immediate test run."
fi
