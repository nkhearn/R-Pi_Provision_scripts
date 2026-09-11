#!/bin/bash
# Raspberry Pi 5 Offline Image Builder (Debian Trixie)
# Features: Local Image Scan, Loopback Mounting, Config Injection, Optional VNC Enablement

set -e

echo "=========================================================="
echo " Raspberry Pi Offline Image Builder"
echo "=========================================================="
echo ""

# ---------------------------------------------------------
# Phase 1: Output File Selection
# ---------------------------------------------------------
read -p "Enter desired output image name (e.g. custom-pi5.img): " OUTPUT_IMG
if [[ "$OUTPUT_IMG" != *.img ]]; then
    OUTPUT_IMG="${OUTPUT_IMG}.img"
fi

if [ -f "$OUTPUT_IMG" ]; then
    read -p "File '$OUTPUT_IMG' already exists. Overwrite? [y/N]: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
        echo "Aborting."
        exit 1
    fi
    rm -f "$OUTPUT_IMG"
fi

# ---------------------------------------------------------
# Phase 2: Configuration Gathering
# ---------------------------------------------------------
echo ""
echo "--- General Configuration ---"
read -p "New Raspberry Pi Username: " RPI_USER
read -s -p "New Password: " RPI_PASS
echo ""

SSH_PUB_KEY=""
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    read -p "Found SSH key in ~/.ssh/id_ed25519.pub. Inject it? [Y/n]: " USE_KEY
    if [[ ! "$USE_KEY" =~ ^[Nn] ]]; then SSH_PUB_KEY=$(cat "$HOME/.ssh/id_ed25519.pub"); fi
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    read -p "Found SSH key in ~/.ssh/id_rsa.pub. Inject it? [Y/n]: " USE_KEY
    if [[ ! "$USE_KEY" =~ ^[Nn] ]]; then SSH_PUB_KEY=$(cat "$HOME/.ssh/id_rsa.pub"); fi
fi
if [ -z "$SSH_PUB_KEY" ]; then
    read -p "Paste SSH Public Key (optional, leave blank to skip): " SSH_PUB_KEY
fi

read -p "Enable VNC service on first boot? [y/N]: " ENABLE_VNC

echo ""
echo "--- Wi-Fi Networks ---"
declare -a WIFI_SSIDS
declare -a WIFI_PASSWORDS
declare -a WIFI_PRIORITIES

while true; do
    read -p "Enter WiFi SSID (leave blank to finish adding networks): " ssid
    if [ -z "$ssid" ]; then
        break
    fi
    read -p "Enter WiFi Password for '$ssid' (leave blank for OPEN): " pass
    read -p "Set connection priority [Default: 10] (Higher = preferred): " prio
    
    WIFI_SSIDS+=("$ssid")
    WIFI_PASSWORDS+=("$pass")
    WIFI_PRIORITIES+=("${prio:-10}")
    echo "Added '$ssid' to injection list."
    echo ""
done

# ---------------------------------------------------------
# Phase 3: Source Image Selection
# ---------------------------------------------------------
echo ""
echo "--- Source Image Selection ---"
echo "Select base image to use:"
echo "1) Download Raspberry Pi OS Lite (64-bit)"
echo "2) Download Raspberry Pi OS Desktop (64-bit)"
echo "3) Use a local .xz image"
read -p "Selection [1/2/3]: " IMG_CHOICE

case $IMG_CHOICE in
    1) URL="https://downloads.raspberrypi.com/raspios_lite_arm64/latest" ;;
    2) URL="https://downloads.raspberrypi.com/raspios_arm64/latest" ;;
    3) 
        shopt -s nullglob
        LOCAL_FILES=( *.xz )
        shopt -u nullglob

        if [ ${#LOCAL_FILES[@]} -gt 0 ]; then
            echo ""
            echo "Local .xz files found in current directory:"
            for i in "${!LOCAL_FILES[@]}"; do
                echo "$((i+1))) ${LOCAL_FILES[$i]}"
            done
            MANUAL_OPT=$(( ${#LOCAL_FILES[@]} + 1 ))
            echo "$MANUAL_OPT) Enter a manual path"
            
            read -p "Selection [1-$MANUAL_OPT]: " SUB_CHOICE
            if [[ "$SUB_CHOICE" =~ ^[0-9]+$ ]] && [ "$SUB_CHOICE" -ge 1 ] && [ "$SUB_CHOICE" -le "${#LOCAL_FILES[@]}" ]; then
                IMG_PATH="${LOCAL_FILES[$((SUB_CHOICE-1))]}"
            elif [ "$SUB_CHOICE" -eq "$MANUAL_OPT" ]; then
                read -p "Enter full path to .xz file: " LOCAL_IMG
                if [ ! -f "$LOCAL_IMG" ]; then echo "File not found!"; exit 1; fi
                IMG_PATH="$LOCAL_IMG"
            else
                echo "Invalid choice."
                exit 1
            fi
        else
            echo "No local .xz files found in the current directory."
            read -p "Enter full path to .xz file: " LOCAL_IMG
            if [ ! -f "$LOCAL_IMG" ]; then echo "File not found!"; exit 1; fi
            IMG_PATH="$LOCAL_IMG"
        fi
        ;;
    *) echo "Invalid choice."; exit 1 ;;
esac

if [ "$IMG_CHOICE" -eq 1 ] || [ "$IMG_CHOICE" -eq 2 ]; then
    DOWNLOAD_DIR="$PWD/pi_downloads"
    mkdir -p "$DOWNLOAD_DIR"
    echo "Downloading to $DOWNLOAD_DIR..."
    wget -q --show-progress --trust-server-names -P "$DOWNLOAD_DIR" "$URL"
    IMG_PATH=$(ls -t "$DOWNLOAD_DIR"/*.xz | head -n 1)
fi

# ---------------------------------------------------------
# Phase 4: Extract and Mount via Loopback
# ---------------------------------------------------------
echo ""
echo "Extracting $IMG_PATH to $OUTPUT_IMG..."
xzcat "$IMG_PATH" > "$OUTPUT_IMG"

echo "Attaching $OUTPUT_IMG to loop device..."
LOOP_DEV=$(sudo losetup -P -f --show "$OUTPUT_IMG")
if [ -z "$LOOP_DEV" ]; then
    echo "Error: Failed to attach loop device."
    exit 1
fi

echo "Waiting for partition mappings to settle..."
sudo partprobe "$LOOP_DEV"
sleep 2

PART_BOOT="${LOOP_DEV}p1"
PART_ROOT="${LOOP_DEV}p2"

MNT_BOOT="/tmp/pi_img_boot"
MNT_ROOT="/tmp/pi_img_root"

sudo mkdir -p "$MNT_BOOT" "$MNT_ROOT"
sudo mount "$PART_BOOT" "$MNT_BOOT"
sudo mount "$PART_ROOT" "$MNT_ROOT"

# ---------------------------------------------------------
# Phase 5: Configuration Injection
# ---------------------------------------------------------
echo ""
echo "--- Injecting Configuration ---"

# 1. Enable SSH and create User
sudo touch "$MNT_BOOT/ssh"
ENCRYPTED_PASS=$(echo "$RPI_PASS" | openssl passwd -6 -stdin)
echo "$RPI_USER:$ENCRYPTED_PASS" | sudo tee "$MNT_BOOT/userconf.txt" > /dev/null

# 2. Network Manager Wi-Fi Profiles
NM_DIR="$MNT_ROOT/etc/NetworkManager/system-connections"
sudo mkdir -p "$NM_DIR"

for i in "${!WIFI_SSIDS[@]}"; do
    SSID="${WIFI_SSIDS[$i]}"
    PASS="${WIFI_PASSWORDS[$i]}"
    PRIO="${WIFI_PRIORITIES[$i]}"
    UUID_CONFIG=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    
    if [ -n "$PASS" ]; then
        sudo tee "$NM_DIR/${SSID}.nmconnection" > /dev/null <<EOF
[connection]
id=$SSID
uuid=$UUID_CONFIG
type=wifi
autoconnect=true
autoconnect-priority=$PRIO

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$PASS

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    else
        sudo tee "$NM_DIR/${SSID}.nmconnection" > /dev/null <<EOF
[connection]
id=$SSID
uuid=$UUID_CONFIG
type=wifi
autoconnect=true
autoconnect-priority=$PRIO

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=none

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    fi
    sudo chmod 600 "$NM_DIR/${SSID}.nmconnection"
    echo "Injected Wi-Fi: $SSID (Priority $PRIO)"
done

# 3. Fallback AP Profile & Script
UUID_HOTSPOT=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
sudo tee "$NM_DIR/Fallback-Hotspot.nmconnection" > /dev/null <<EOF
[connection]
id=Fallback-Hotspot
uuid=$UUID_HOTSPOT
type=wifi
autoconnect=false

[wifi]
mode=ap
ssid=Pi5-Setup-AP
band=bg
channel=1

[wifi-security]
key-mgmt=wpa-psk
psk=RaspberryPi

[ipv4]
method=shared

[ipv6]
method=auto
EOF
sudo chmod 600 "$NM_DIR/Fallback-Hotspot.nmconnection"
sudo chown -R root:root "$NM_DIR"

sudo tee "$MNT_ROOT/usr/local/bin/network-fallback.sh" > /dev/null <<'EOF'
#!/bin/bash
CHECK_HOST="1.1.1.1"
WAIT_SECONDS=45
sleep $WAIT_SECONDS
if ! ping -c 2 -W 3 "$CHECK_HOST" > /dev/null 2>&1; then
    nmcli connection up "Fallback-Hotspot"
fi
EOF
sudo chmod +x "$MNT_ROOT/usr/local/bin/network-fallback.sh"

sudo tee "$MNT_ROOT/etc/systemd/system/network-fallback.service" > /dev/null <<'EOF'
[Unit]
Description=Multi-stage Network Fallback Service
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/network-fallback.sh

[Install]
WantedBy=multi-user.target
EOF
sudo mkdir -p "$MNT_ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf "/etc/systemd/system/network-fallback.service" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/network-fallback.service"

# 4. RFKill & Country Code
sudo mkdir -p "$MNT_ROOT/etc/wpa_supplicant"
sudo tee "$MNT_ROOT/etc/wpa_supplicant/wpa_supplicant.conf" > /dev/null <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=GB
EOF
sudo rm -f "$MNT_ROOT/var/lib/systemd/rfkill/"*
echo "Wi-Fi soft-block cleared and country code set to GB."

# 5. Inject SSH Key
if [ -n "$SSH_PUB_KEY" ]; then
    sudo mkdir -p "$MNT_ROOT/home/$RPI_USER/.ssh"
    echo "$SSH_PUB_KEY" | sudo tee "$MNT_ROOT/home/$RPI_USER/.ssh/authorized_keys" > /dev/null
    sudo chmod 700 "$MNT_ROOT/home/$RPI_USER/.ssh"
    sudo chmod 600 "$MNT_ROOT/home/$RPI_USER/.ssh/authorized_keys"
    # Ensure standard UID:GID for the primary user
    sudo chown -R 1000:1000 "$MNT_ROOT/home/$RPI_USER"
fi

# 6. First-Boot VNC Enablement (Optional)
if [[ "$ENABLE_VNC" =~ ^[Yy] ]]; then
    sudo tee "$MNT_ROOT/etc/systemd/system/first-boot-vnc.service" > /dev/null <<'EOF'
[Unit]
Description=Enable VNC on First Boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/raspi-config nonint do_vnc 0
ExecStartPost=/bin/systemctl disable first-boot-vnc.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo ln -sf "/etc/systemd/system/first-boot-vnc.service" "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/first-boot-vnc.service"
    echo "Injected first-boot script to natively enable VNC service."
fi

# ---------------------------------------------------------
# Phase 6: Cleanup & Unmount
# ---------------------------------------------------------
echo ""
echo "Syncing filesystem to ensure writes are finalized..."
sync

sudo umount "$MNT_BOOT" || true
sudo umount "$MNT_ROOT" || true
sudo losetup -d "$LOOP_DEV" || true

echo "=========================================================="
echo "✅ Success! Your custom image is ready: $OUTPUT_IMG"
echo "You can flash this to an SD card later using dd, for example:"
echo "sudo dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress"
echo "=========================================================="
