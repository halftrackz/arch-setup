# Arch Linux Post-Install Setup Script

A root-level bash script that automates common post-installation tasks on a fresh Arch Linux system.

## What it does

- **Enables multilib** — Safely adds or uncomments the multilib repository in `pacman.conf` for 32-bit package support
- **Creates a user** — Sets up a new user with wheel group membership and passwordless sudo
- **Installs KDE Plasma** — Full Plasma desktop with a curated set of apps including Steam, Discord, and KDE Connect
- **Configures PipeWire** — Installs and enables PipeWire, PulseAudio compatibility, JACK, and WirePlumber via linger
- **GPU drivers** — Prompts for NVIDIA or AMD, with hybrid laptop detection for NVIDIA (installs `nvidia-prime`), Nouveau blacklisting, and Wayland DRM modeset configuration
- **Installs yay** — Builds the AUR helper from source correctly as a non-root user
- **Installs browsers** — Chromium via pacman, Brave via AUR
- **Bluetooth** — Installs and enables bluez
- **Reboot prompt** — Asks before rebooting rather than forcing it

## Firewall

A companion script (`setup_firewall_home.sh`) configures `firewalld` for the `home` zone with the following:

- **Services:** `dhcpv6-client`, `ipp`, `mdns`, `samba-client`, `ssh`
- **Custom ports:** 9942, 9944, 9945 (TCP & UDP)
- **Steam/game ports:** TCP 27014–27050, UDP 27000–27100

Run it after the main setup:

```bash
sudo bash setup_firewall_home.sh
```

> Requires `firewalld` to be installed and running (`systemctl enable --now firewalld`).

## Usage

```bash
sudo bash arch-setup.sh
```

## Notes

- Must be run as root on a fresh Arch install with GRUB as the bootloader
- NVIDIA support targets the stock `linux` kernel via `nvidia-open`
- If you use `linux-lts` or `linux-zen`, swap `nvidia-open` for `nvidia-open-dkms`
