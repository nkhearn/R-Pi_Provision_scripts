# Raspberry Pi 5 Headless Provisioning Suite

A collection of Bash scripts designed to fully automate the initial headless configuration of Raspberry Pi OS (Debian Trixie). 

Whether you are flashing directly to an SD card on a Linux desktop, building a custom `.img` file on a server, or generating a ready-to-flash image directly on an unrooted Android device using Termux, this suite provides the exact workflow you need.

## ✨ Features

All three scripts inject a comprehensive headless configuration into the Raspberry Pi OS image:
* **User & Security:** Sets up the primary user and securely hashes the password.
* **Custom Hostname:** Prompt-driven hostname configuration (defaults to `raspberrypi`).
* **SSH Key Injection:** Automatically detects and injects local `ed25519` or `rsa` public keys, or allows manual pasting.
* **Advanced Networking (NetworkManager):** Configures multiple Wi-Fi SSIDs with priority tiers and customizable Wi-Fi country code.
* **Fallback Hotspot:** Injects a custom `systemd` service. If the Pi cannot reach the internet after 45 seconds, it automatically broadcasts a fallback Wi-Fi Hotspot (`Pi5-Setup-AP`) so you can SSH in.
* **Optional VNC Enablement:** Prompt-driven option to trigger `raspi-config` on first boot to natively enable the VNC service.

---

## 🛠️ The Scripts

### 1. `pi_prov_direct.sh` (Direct to Drive)
**Best for:** Standard Linux desktop/server users with an SD card or USB drive plugged in.
* **How it works:** Downloads or uses a local `.xz` Pi OS image, extracts it, and writes it directly to the target block device (e.g., `/dev/sda`). It verifies safety to prevent accidentally overwriting the host root system drive, natively mounts boot and root partitions to inject configurations, safely unmounts, and ejects the target drive.
* **Requirements:** A Linux environment with `sudo` privileges.

### 2. `pi_prov_image.sh` (Offline Image Builder)
**Best for:** Creating reusable, pre-configured `.img` files on a Linux machine to flash later.
* **How it works:** Extracts the source `.xz` image to a raw `.img` file. It uses Linux loopback devices (`losetup`) and `partprobe` to mount the image's internal partitions. It injects configurations (including hostname and Wi-Fi country code), detaches loop devices, and optionally compresses the final image with `xz`.
* **Requirements:** A Linux environment with `sudo` privileges and loopback kernel module support.

### 3. `pi_prov_image_tmx.sh` (Termux / Unrooted Android Native)
**Best for:** Mobile users building custom images on Android without root access.
* **How it works:** Because unrooted Android cannot use `mount` or `losetup`, this script operates entirely in user-space. It uses `mtools` to inject configurations directly into the FAT32 boot partition of the `.img` file. It then patches the kernel's `cmdline.txt` with a `systemd.run` hook. On the Pi's very first boot, it executes an injected script, sets hostname and Wi-Fi regulatory domain, moves all network and SSH configurations into the protected `ext4` root partition natively, optionally enables VNC, and reboots itself. Optionally exports the finished image directly to the Android shared Download folder (`~/storage/downloads`).
* **Requirements:** Termux. No root required.

---

## 📦 Prerequisites

**For Linux (Scripts 1 & 2):**
Ensure you have standard system utilities installed (most are pre-installed on Debian/Ubuntu):
```bash
sudo apt install wget xz-utils util-linux parted openssl
```
