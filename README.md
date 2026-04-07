# Arch Linux Post-Install Setup Script

A root-level bash script that automates common post-installation tasks on a fresh Arch Linux system.

## What it does

- **Enables multilib** — Safely adds or uncomments the multilib repository in `pacman.conf` for 32-bit package support
- **Creates a user** — Sets up a new user with wheel group membership and passwordless sudo
- **Installs KDE Plasma** — Full Plasma desktop with a curated set of apps including Steam, Discord, and KDE Connect
- **Installs Flatpak** — Adds Flatpak with the Flathub repository pre-configured and ready to use after reboot
- **Configures PipeWire** — Installs and enables PipeWire, PulseAudio compatibility, JACK, and WirePlumber via linger
- **GPU drivers** — Prompts for NVIDIA or AMD, with hybrid laptop detection for NVIDIA (installs `nvidia-prime`), Nouveau blacklisting, and Wayland DRM modeset configuration
- **Installs yay** — Builds the AUR helper from source correctly as a non-root user
- **Installs browsers** — Chromium via pacman, Brave via AUR
- **Bluetooth** — Installs and enables bluez
- **Reboot prompt** — Asks before rebooting rather than forcing it
## Usage
```bash
sudo bash arch-setup.sh
```
## Firewall

An independent script (`setup_firewall.sh`) configures and installs `firewalld` for the `home` zone with the following:

- **Services:** `dhcpv6-client`, `ipp`, `mdns`, `samba-client`, `ssh`
- **Optional — ALVR:** 9942, 9944, 9945 (TCP & UDP)
- **Optional — Steam dedicated servers:** TCP 27014–27050, UDP 27000–27100


```bash
sudo bash setup_firewall.sh
```

> Does not require firewalld to be installed manually, but does require you to be on your home network for proper configuration.

## Notes

- Must be run as root on a fresh Arch install with GRUB as the bootloader (arch-setup.sh only)
- `setup_firewall.sh` can be run independently on any existing Arch install
- NVIDIA support targets the stock `linux` kernel via `nvidia-open`
- If you use `linux-lts` or `linux-zen`, swap `nvidia-open` for `nvidia-open-dkms`
