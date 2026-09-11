#!/bin/bash
# Raspberry Pi 5 (64-bit) Master Provisioner
# Features: Write Skip, Local Image Scan, Multiple Wi-Fi, Fallback Hotspot, Dynamic Mounts, RFKill Fix

set -e

echo "=========================================================="
echo " Raspberry Pi Master Provisioner (Debian Trixie)"
echo "=========================================================="
echo ""

# ---------------------------------------------------------
# Phase 1: Mode Selection
# ---------------------------------------------------------
read -p "Do you want to (W)rite a new OS image or (I)nject config to an existing drive? [W/I]: " MODE
if [[ ! "$MODE" =~ ^[WwIi] ]]; then
    echo "Invalid choice. Exiting."
    exit 1
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
# Phase 3: Target Device Selection
# ---------------------------------------------------------
echo ""
echo "--- Target Block Device Selection ---"
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS | grep -vi loop
echo ""
read -p "Enter the target block device name (e.g. sdb, mmcblk0): " TARGET_DEV
TARGET_PATH="/dev/$TARGET_DEV"

if [ ! -b "$TARGET_PATH" ]; then
    echo "Error: $TARGET_PATH is not a valid block device."
    exit 1
fi

# ---------------------------------------------------------
# Phase 4: Download & Write (If selected)
# ---------------------------------------------------------
if [[ "$MODE" =~ ^[Ww] ]]; then
    echo "----------------------------------------------------------"
    echo "!!! DANGER !!!"
    echo "You are about to securely wipe and overwrite ALL data on:"
    echo "Device: $TARGET_PATH"
    echo "----------------------------------------------------------"
    read -p "Type 'YES' to confirm and start writing: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborting."
        exit 1
    fi

    echo "Select image to download/use:"
    echo "1) Raspberry Pi OS Lite (64-bit)"
    echo "2) Raspberry Pi OS Desktop (64-bit)"
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
        DOWNLOAD_DIR="$HOME/mnt/usb"
        mkdir -p "$DOWNLOAD_DIR"
        echo "Downloading to $DOWNLOAD_DIR..."
        wget -q --show-progress --trust-server-names -P "$DOWNLOAD_DIR" "$URL"
        IMG_PATH=$(ls -t "$DOWNLOAD_DIR"/*.xz | head -n 1)
    fi

    echo "Writing image to $TARGET_PATH..."
    xzcat "$IMG_PATH" | sudo dd of="$TARGET_PATH" bs=4M status=progress conv=fsync

    echo "Probing partitions to refresh kernel tables..."
    sudo partprobe "$TARGET_PATH"
    echo "Waiting for desktop auto-mounter to settle..."
    sleep 5
fi

# ---------------------------------------------------------
# Phase 5: Dynamic Partition Mounting
# ---------------------------------------------------------
if [[ "$TARGET_DEV" =~ [0-9]$ ]]; then
    PART_BOOT="${TARGET_PATH}p1"
    PART_ROOT="${TARGET_PATH}p2"
else
    PART_BOOT="${TARGET_PATH}1"
    PART_ROOT="${TARGET_PATH}2"
fi

echo ""
echo "--- Locating Partitions ---"

MOUNTED_BOOT=$(findmnt -n -o TARGET "$PART_BOOT" || true)
MOUNTED_ROOT=$(findmnt -n -o TARGET "$PART_ROOT" || true)

if [ -n "$MOUNTED_BOOT" ]; then
    MNT_BOOT="$MOUNTED_BOOT"
    echo "Boot partition already mounted at: $MNT_BOOT"
else
    MNT_BOOT="/tmp/pi_boot"
    sudo mkdir -p "$MNT_BOOT"
    sudo mount "$PART_BOOT" "$MNT_BOOT"
    echo "Boot partition manually mounted to: $MNT_BOOT"
fi

if [ -n "$MOUNTED_ROOT" ]; then
    MNT_ROOT="$MOUNTED_ROOT"
    echo "Root partition already mounted at: $MNT_ROOT"
else
    MNT_ROOT="/tmp/pi_root"
    sudo mkdir -p "$MNT_ROOT"
    sudo mount "$PART_ROOT" "$MNT_ROOT"
    echo "Root partition manually mounted to: $MNT_ROOT"
fi

# ---------------------------------------------------------
# Phase 6: Configuration Injection
# ---------------------------------------------------------
echo ""
echo "--- Injecting Configuration ---"

sudo touch "$MNT_BOOT/ssh"
ENCRYPTED_PASS=$(echo "$RPI_PASS" | openssl passwd -6 -stdin)
echo "$RPI_USER:$ENCRYPTED_PASS" | sudo tee "$MNT_BOOT/userconf.txt" > /dev/null

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

UUID_OPEN=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
sudo tee "$NM_DIR/Fallback-Open-WiFi.nmconnection" > /dev/null <<EOF
[connection]
id=Fallback-Open-WiFi
uuid=$UUID_OPEN
type=wifi
autoconnect=true
autoconnect-priority=5

[wifi]
mode=infrastructure

[wifi-security]
key-mgmt=none

[ipv4]
method=auto

[ipv6]
method=auto
EOF
sudo chmod 600 "$NM_DIR/Fallback-Open-WiFi.nmconnection"

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
echo "Network Fallback: Waiting $WAIT_SECONDS seconds..."
sleep $WAIT_SECONDS
if ping -c 2 -W 3 "$CHECK_HOST" > /dev/null 2>&1; then
    exit 0
fi
nmcli connection up "Fallback-Hotspot"
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

sudo mkdir -p "$MNT_ROOT/etc/wpa_supplicant"
sudo tee "$MNT_ROOT/etc/wpa_supplicant/wpa_supplicant.conf" > /dev/null <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=GB
EOF
sudo rm -f "$MNT_ROOT/var/lib/systemd/rfkill/"*
echo "Wi-Fi soft-block cleared and country code set to GB."

if [ -n "$SSH_PUB_KEY" ]; then
    sudo mkdir -p "$MNT_ROOT/home/$RPI_USER/.ssh"
    echo "$SSH_PUB_KEY" | sudo tee "$MNT_ROOT/home/$RPI_USER/.ssh/authorized_keys" > /dev/null
    sudo chmod 700 "$MNT_ROOT/home/$RPI_USER/.ssh"
    sudo chmod 600 "$MNT_ROOT/home/$RPI_USER/.ssh/authorized_keys"
    sudo chown -R 1000:1000 "$MNT_ROOT/home/$RPI_USER"
fi

# ---------------------------------------------------------
# Phase 7: Cleanup
# ---------------------------------------------------------
echo ""
echo "Syncing filesystem to ensure writes are finalized..."
sync

sudo umount "$MNT_BOOT" || true
sudo umount "$MNT_ROOT" || true

echo "=========================================================="
echo "✅ Success! The drive is provisioned and cleanly unmounted."
echo "You can safely eject it, plug it into the Pi 5, and boot up."
