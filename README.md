# Raspberry Pi 5 Headless Provisioning Suite

A collection of Bash scripts designed to fully automate the initial headless configuration of Raspberry Pi OS (Debian Trixie, 64-bit).

Whether you are flashing directly to an SD card or USB drive on a Linux desktop, building a custom `.img` file on a server, or generating a ready-to-flash image directly on an unrooted Android device using Termux, this suite provides a seamless and completely automated workflow.

---

## ✨ Features & Suite Overview

All three scripts inject a comprehensive headless configuration into the Raspberry Pi OS image:

* **User & Security Setup:** Configures the primary user and securely hashes the user password using SHA-512 via OpenSSL (`openssl passwd -6`).
* **Custom Hostname:** Prompt-driven hostname configuration (defaults to `raspberrypi`), updating both `/etc/hostname` and `/etc/hosts`.
* **SSH Key Injection:** Automatically detects local `ed25519` or `rsa` public keys in `~/.ssh/` or allows manual key pasting, setting correct `0700`/`0600` permissions and ownership.
* **Advanced Multi-Network Wi-Fi (NetworkManager):** Configures multiple Wi-Fi SSIDs with priority tiers and customizable Wi-Fi country codes directly into NetworkManager (`/etc/NetworkManager/system-connections/`).
* **Pre-seeded NetworkManager State:** Pre-configures `/var/lib/NetworkManager/NetworkManager.state` to ensure wireless and networking radios are enabled on first boot (`NetworkingEnabled=true`, `WirelessEnabled=true`).
* **Native First-Boot Wi-Fi & Country Unblock:** Injects a one-time `first-boot-wifi.service` that unblocks Wi-Fi via `rfkill unblock wifi` and sets the regulatory domain natively using `raspi-config nonint do_wifi_country`.
* **Fallback Hotspot AP:** Injects a custom `network-fallback.service`. If the Raspberry Pi cannot reach the internet after 45 seconds, it automatically broadcasts a fallback Wi-Fi Hotspot (`Pi5-Setup-AP`, password: `RaspberryPi`) so you can SSH in.
* **Optional VNC Enablement:** Prompt-driven option to inject a one-time first-boot service (`first-boot-vnc.service`) that enables the VNC service natively via `raspi-config nonint do_vnc 0`.
* **Dynamic Progress Indicators:** Checks for `pv` and `whiptail` to display visual progress gauges during download, extraction, writing, and compression, with an option to install them automatically or fall back to standard console output.

---

## 🛠️ Script Details & Recent Fixes

### 1. `pi_prov_direct.sh` (Direct Block Device Writer)
**Best for:** Standard Linux desktop or server environments with an SD card or USB drive attached.
* **How it works:** Prompts to download the latest official Raspberry Pi OS 64-bit image or select a local `.xz` archive. Verifies target safety to prevent overwriting the system root disk. Unmounts active partitions on the target drive, refreshes partition tables (`partprobe` & `udevadm settle`), mounts boot and root partitions directly to `/tmp/pi_boot` and `/tmp/pi_root`, injects all system and network configurations, syncs, safely unmounts, and ejects the target drive.
* **Key Fixes & Refinements:**
  - Resolved OS download failures by updating image fetch endpoints to `raspios_lite_arm64_latest` and `raspios_arm64_latest`.
  - Added strict system disk safety checks to protect host root partitions.
  - Ensured active partition unmounting prior to writing or table re-probing.

### 2. `pi_prov_image.sh` (Offline Image Builder)
**Best for:** Creating pre-configured, reusable `.img` or compressed `.img.xz` files on Linux servers or workstations.
* **How it works:** Extracts the base `.xz` image into a raw `.img` file, attaches it to a loopback device (`losetup -P`), mounts internal boot and root partitions to `/tmp/pi_img_boot` and `/tmp/pi_img_root`, injects all configuration files, cleans up loop devices, and optionally compresses the output image with multi-threaded `xz` (`xz -T0`).
* **Key Fixes & Refinements:**
  - Updated image download URLs to fix 404 errors during direct download.
  - Enhanced loopback partition detection and clean unmounting logic.
  - Added progress UI support for extraction, downloading, and `xz` compression.

### 3. `pi_prov_image_tmx.sh` (Termux / Unrooted Android Native Builder)
**Best for:** Building custom Raspberry Pi OS images on mobile devices without root access.
* **How it works:** Runs entirely in user-space using `mtools`, `fdisk`, and `openssl-tool`. Calculates the byte offset of the FAT32 boot partition using `fdisk`, copies configuration profiles and a `firstrun.sh` script onto the boot partition via `mcopy`, and patches `cmdline.txt` with `systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot`. On initial boot, the Pi executes `firstrun.sh` to move network profiles into the `ext4` root partition, set hostname, unblock wireless radios, configure Wi-Fi country code, setup SSH keys and optional VNC, restore `cmdline.txt`, and reboot into a fully provisioned state.
* **Key Fixes & Refinements:**
  - **Fixed Silent Download Failure:** Corrected the Raspberry Pi OS download URL endpoint from `/latest` (which returned 404 Not Found) to `_latest` (`raspios_lite_arm64_latest` / `raspios_arm64_latest`).
  - **Export Support:** Added prompt option to export the finished image to Android's shared Download folder (`~/storage/downloads` or `/sdcard/Download`).
  - **Dependency Verification:** Validates user-space tools (`mtools`, `util-linux`, `openssl-tool`) at startup.

---

## 📦 Prerequisites & Quick Start

### For Linux (`pi_prov_direct.sh` & `pi_prov_image.sh`)
Ensure standard system utilities and dependencies are installed:
```bash
sudo apt-get update && sudo apt-get install -y wget xz-utils util-linux parted openssl pv whiptail
```

Run either script with sudo/root privileges:
```bash
sudo ./pi_prov_direct.sh
# OR
sudo ./pi_prov_image.sh
```

### For Termux / Android (`pi_prov_image_tmx.sh`)
Install required user-space packages (no root required):
```bash
pkg update && pkg install -y mtools util-linux openssl-tool wget xz-utils pv whiptail
```

To enable exporting to Android shared storage, set up storage permissions first:
```bash
termux-setup-storage
```

Run the builder script:
```bash
./pi_prov_image_tmx.sh
```
