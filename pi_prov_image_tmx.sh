#!/bin/bash
# Raspberry Pi 5 Offline Image Builder for Termux (Debian Trixie)
# NATIVE USER-SPACE INJECTION (No root, no loopback required)

set -e

echo "=========================================================="
echo " Termux Native Offline Image Builder"
echo "=========================================================="
echo ""

# Ensure required core packages are installed
for cmd in mcopy fdisk openssl; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found."
        echo "Please run: pkg install mtools util-linux openssl-tool"
        exit 1
    fi
done

# ---------------------------------------------------------
# Phase 0: Dependency Checks (PV and Whiptail)
# ---------------------------------------------------------
USE_PROGRESS_UI=false
MISSING_TOOLS=()

if ! command -v pv &>/dev/null; then
    MISSING_TOOLS+=("pv")
fi
if ! command -v whiptail &>/dev/null; then
    MISSING_TOOLS+=("whiptail")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "Optional progress indicator dependencies missing: ${MISSING_TOOLS[*]}"
    read -p "Would you like to try installing them now via package manager? [y/N]: " INSTALL_TOOLS
    if [[ "$INSTALL_TOOLS" =~ ^[Yy] ]]; then
        echo "Attempting to install ${MISSING_TOOLS[*]}..."
        if command -v pkg &>/dev/null; then
            pkg install -y "${MISSING_TOOLS[@]}" || true
        elif command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y "${MISSING_TOOLS[@]}" || true
        else
            echo "Package manager not recognized. Skipping automatic installation."
        fi
    fi
fi

if command -v pv &>/dev/null && command -v whiptail &>/dev/null; then
    USE_PROGRESS_UI=true
    echo "Progress indicators enabled (pv + whiptail)."
else
    echo "Falling back to standard output / simple progress logs."
fi
echo ""

# ---------------------------------------------------------
# Phase 1: Output & Temp Setup
# ---------------------------------------------------------
read -p "Enter desired output image name (e.g. custom-pi5.img): " OUTPUT_IMG
if [[ "$OUTPUT_IMG" != *.img ]]; then
    OUTPUT_IMG="${OUTPUT_IMG}.img"
fi

if [ -f "$OUTPUT_IMG" ]; then
    read -p "File '$OUTPUT_IMG' already exists. Overwrite? [y/N]: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then echo "Aborting."; exit 1; fi
    rm -f "$OUTPUT_IMG"
fi

TMP_DIR="$PWD/pi_build_tmp"
mkdir -p "$TMP_DIR"
# Ensure we clean up temp files if script exits or fails
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------
# Phase 2: Configuration Gathering
# ---------------------------------------------------------
echo ""
echo "--- General Configuration ---"
read -p "New Raspberry Pi Username: " RPI_USER
read -s -p "New Password: " RPI_PASS
echo ""
read -p "New Raspberry Pi Hostname [Default: raspberrypi]: " RPI_HOSTNAME
RPI_HOSTNAME="${RPI_HOSTNAME:-raspberrypi}"

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

read -p "Wi-Fi Country Code [Default: GB]: " WIFI_COUNTRY
WIFI_COUNTRY="${WIFI_COUNTRY:-GB}"
WIFI_COUNTRY=$(echo "$WIFI_COUNTRY" | tr '[:lower:]' '[:upper:]')

read -p "Copy final image to Android Download folder (~/storage/downloads)? [y/N]: " EXPORT_DOWNLOADS

echo ""
echo "--- Wi-Fi Networks ---"
declare -a WIFI_SSIDS
declare -a WIFI_PASSWORDS
declare -a WIFI_PRIORITIES

while true; do
    read -p "Enter WiFi SSID (leave blank to finish): " ssid
    if [ -z "$ssid" ]; then break; fi
    read -p "Enter WiFi Password for '$ssid' (leave blank for OPEN): " pass
    read -p "Set connection priority [Default: 10]: " prio
    
    WIFI_SSIDS+=("$ssid")
    WIFI_PASSWORDS+=("$pass")
    WIFI_PRIORITIES+=("${prio:-10}")
    echo "Added '$ssid' to list."
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
    1) URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest" ;;
    2) URL="https://downloads.raspberrypi.com/raspios_arm64_latest" ;;
    3) 
        shopt -s nullglob; LOCAL_FILES=( *.xz ); shopt -u nullglob
        if [ ${#LOCAL_FILES[@]} -gt 0 ]; then
            echo ""; echo "Local .xz files found:"
            for i in "${!LOCAL_FILES[@]}"; do echo "$((i+1))) ${LOCAL_FILES[$i]}"; done
            MANUAL_OPT=$(( ${#LOCAL_FILES[@]} + 1 ))
            echo "$MANUAL_OPT) Enter manual path"
            read -p "Selection: " SUB_CHOICE
            if [[ "$SUB_CHOICE" =~ ^[0-9]+$ ]] && [ "$SUB_CHOICE" -le "${#LOCAL_FILES[@]}" ]; then
                IMG_PATH="${LOCAL_FILES[$((SUB_CHOICE-1))]}"
            else
                read -p "Enter full path to .xz file: " IMG_PATH
            fi
        else
            read -p "Enter full path to .xz file: " IMG_PATH
        fi
        ;;
    *) echo "Invalid choice."; exit 1 ;;
esac

if [ "$IMG_CHOICE" -eq 1 ] || [ "$IMG_CHOICE" -eq 2 ]; then
    DOWNLOAD_DIR="$PWD/pi_downloads"
    mkdir -p "$DOWNLOAD_DIR"
    echo "Downloading to $DOWNLOAD_DIR..."
    if [ "$USE_PROGRESS_UI" = true ]; then
        REMOTE_HEADERS=$(wget --spider --server-response "$URL" 2>&1)
        REDIRECT_URL=$(echo "$REMOTE_HEADERS" | grep -i "Location:" | tail -n 1 | awk '{print $2}' | tr -d '\r')
        if [ -n "$REDIRECT_URL" ]; then
            FILE_NAME=$(basename "$REDIRECT_URL" | cut -d'?' -f1)
        else
            FILE_NAME="pi_os_image.xz"
        fi
        CONTENT_LENGTH=$(echo "$REMOTE_HEADERS" | grep -i "Content-Length:" | tail -n 1 | awk '{print $2}' | tr -d '\r')

        OUT_FILE="$DOWNLOAD_DIR/$FILE_NAME"
        if [ -n "$CONTENT_LENGTH" ] && [[ "$CONTENT_LENGTH" =~ ^[0-9]+$ ]]; then
            ( wget -qO- "$URL" | pv -n -s "$CONTENT_LENGTH" > "$OUT_FILE" ) 2>&1 | whiptail --gauge "Downloading Raspberry Pi OS image..." 6 60 0
        else
            ( wget -qO- "$URL" | pv -n > "$OUT_FILE" ) 2>&1 | whiptail --gauge "Downloading Raspberry Pi OS image..." 6 60 0
        fi
        IMG_PATH="$OUT_FILE"
    else
        wget -q --show-progress --trust-server-names -P "$DOWNLOAD_DIR" "$URL"
        IMG_PATH=$(ls -t "$DOWNLOAD_DIR"/*.xz | head -n 1)
    fi
fi

echo ""
echo "Extracting $IMG_PATH to $OUTPUT_IMG..."
if [ "$USE_PROGRESS_UI" = true ]; then
    ( pv -n "$IMG_PATH" | xzcat > "$OUTPUT_IMG" ) 2>&1 | whiptail --gauge "Extracting base image..." 6 60 0
else
    xzcat "$IMG_PATH" > "$OUTPUT_IMG"
fi

# ---------------------------------------------------------
# Phase 4: Generate Configuration Files Locally
# ---------------------------------------------------------
echo ""
echo "Generating configurations in Termux..."

# 1. User & SSH Setup
ENCRYPTED_PASS=$(echo "$RPI_PASS" | openssl passwd -6 -stdin)
echo "$RPI_USER:$ENCRYPTED_PASS" > "$TMP_DIR/userconf.txt"
touch "$TMP_DIR/ssh"
if [ -n "$SSH_PUB_KEY" ]; then
    echo "$SSH_PUB_KEY" > "$TMP_DIR/injected_authorized_keys"
fi

# 2. Network Manager Profiles
for i in "${!WIFI_SSIDS[@]}"; do
    SSID="${WIFI_SSIDS[$i]}"
    PASS="${WIFI_PASSWORDS[$i]}"
    PRIO="${WIFI_PRIORITIES[$i]}"
    UUID_CONFIG=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo $(date +%s%N))
    
    cat <<EOF > "$TMP_DIR/${SSID}.nmconnection"
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
$([[ -n "$PASS" ]] && echo -e "auth-alg=open\nkey-mgmt=wpa-psk\npsk=$PASS" || echo "key-mgmt=none")

[ipv4]
method=auto
[ipv6]
method=auto
EOF
done

# Fallback Hotspot Profile
UUID_HOTSPOT=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "hotspot-uuid")
cat <<EOF > "$TMP_DIR/Fallback-Hotspot.nmconnection"
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

# 3. First-Boot Injection Script (Runs exactly once on the Pi)
cat << 'EOF' > "$TMP_DIR/firstrun.sh"
#!/bin/bash
# Remount just to be safe
mount -o remount,rw /
mount -o remount,rw /boot/firmware 2>/dev/null || mount -o remount,rw /boot

NM_DIR="/etc/NetworkManager/system-connections"
mkdir -p "$NM_DIR"
# Move all profiles from boot partition to NM directory
mv /boot/firmware/*.nmconnection "$NM_DIR/" 2>/dev/null || mv /boot/*.nmconnection "$NM_DIR/" 2>/dev/null
chmod 600 "$NM_DIR"/*.nmconnection

# Create Network Fallback Script
cat << 'INNER_EOF' > /usr/local/bin/network-fallback.sh
#!/bin/bash
CHECK_HOST="1.1.1.1"
sleep 45
if ! ping -c 2 -W 3 "$CHECK_HOST" > /dev/null 2>&1; then
    nmcli connection up "Fallback-Hotspot"
fi
INNER_EOF
chmod +x /usr/local/bin/network-fallback.sh

# Create and enable systemd service for fallback
cat << 'INNER_EOF' > /etc/systemd/system/network-fallback.service
[Unit]
Description=Network Fallback Service
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/network-fallback.sh

[Install]
WantedBy=multi-user.target
INNER_EOF
ln -sf /etc/systemd/system/network-fallback.service /etc/systemd/system/multi-user.target.wants/network-fallback.service

EOF

# Inject Hostname and Wi-Fi Country configuration into firstrun.sh
cat << EOF >> "$TMP_DIR/firstrun.sh"
# Configure Hostname
echo "$RPI_HOSTNAME" > /etc/hostname
if [ -f /etc/hosts ]; then
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$RPI_HOSTNAME/g" /etc/hosts
fi

# Force NetworkManager wireless state to enabled
mkdir -p /var/lib/NetworkManager
cat << EOF_NM > /var/lib/NetworkManager/NetworkManager.state
[main]
NetworkingEnabled=true
WirelessEnabled=true
WWANEnabled=true
EOF_NM
chmod 600 /var/lib/NetworkManager/NetworkManager.state

# Unblock Wi-Fi and set country code natively
/usr/sbin/rfkill unblock wifi
/usr/bin/raspi-config nonint do_wifi_country $WIFI_COUNTRY
/usr/bin/nmcli radio wifi on
EOF

if [[ "$ENABLE_VNC" =~ ^[Yy] ]]; then
    cat << 'EOF' >> "$TMP_DIR/firstrun.sh"
# Enable VNC Server
raspi-config nonint do_vnc 0

EOF
fi

# Append dynamic variables to the script
cat << EOF >> "$TMP_DIR/firstrun.sh"
# Set up SSH Keys
USER_HOME="/home/$RPI_USER"
mkdir -p "\$USER_HOME/.ssh"
mv /boot/firmware/injected_authorized_keys "\$USER_HOME/.ssh/authorized_keys" 2>/dev/null || mv /boot/injected_authorized_keys "\$USER_HOME/.ssh/authorized_keys" 2>/dev/null
if [ -f "\$USER_HOME/.ssh/authorized_keys" ]; then
    chmod 700 "\$USER_HOME/.ssh"
    chmod 600 "\$USER_HOME/.ssh/authorized_keys"
    chown -R 1000:1000 "\$USER_HOME"
fi

# Restore cmdline.txt and self-destruct
mv /boot/firmware/cmdline.bak /boot/firmware/cmdline.txt 2>/dev/null || mv /boot/cmdline.bak /boot/cmdline.txt 2>/dev/null
rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh 2>/dev/null
EOF

# ---------------------------------------------------------
# Phase 5: MTOOLS Injection
# ---------------------------------------------------------
echo "--- Injecting files directly into image via mtools ---"

# Calculate the byte offset of the FAT32 boot partition
BOOT_START=$(fdisk -l "$OUTPUT_IMG" | sed -n '1,/Device/d; p' | head -n 1 | awk '{print $2}')
OFFSET=$(( BOOT_START * 512 ))

# Push static configurations
mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$TMP_DIR/userconf.txt" ::/
mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$TMP_DIR/ssh" ::/
if [ -f "$TMP_DIR/injected_authorized_keys" ]; then
    mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$TMP_DIR/injected_authorized_keys" ::/
fi
for nm_file in "$TMP_DIR"/*.nmconnection; do
    mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$nm_file" ::/
done
mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$TMP_DIR/firstrun.sh" ::/

# Modify cmdline.txt safely via extraction
mcopy -n -i "$OUTPUT_IMG@@$OFFSET" ::/cmdline.txt "$TMP_DIR/cmdline.txt"
cp "$TMP_DIR/cmdline.txt" "$TMP_DIR/cmdline.bak"

# Append the systemd.run hook to execute firstrun.sh and then reboot
sed -i 's/$/ systemd.run=\/boot\/firmware\/firstrun.sh systemd.run_success_action=reboot/' "$TMP_DIR/cmdline.txt"

mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$TMP_DIR/cmdline.bak" ::/
mcopy -o -i "$OUTPUT_IMG@@$OFFSET" "$TMP_DIR/cmdline.txt" ::/

if [[ "$EXPORT_DOWNLOADS" =~ ^[Yy] ]]; then
    DEST_DIR=""
    if [ -d "$HOME/storage/downloads" ]; then
        DEST_DIR="$HOME/storage/downloads"
    elif [ -d "/sdcard/Download" ]; then
        DEST_DIR="/sdcard/Download"
    fi

    if [ -n "$DEST_DIR" ]; then
        echo "Copying $OUTPUT_IMG to $DEST_DIR..."
        DEST_FILE="$DEST_DIR/$(basename "$OUTPUT_IMG")"
        if [ "$USE_PROGRESS_UI" = true ]; then
            IMG_SIZE=$(stat -c%s "$OUTPUT_IMG" 2>/dev/null || echo "")
            if [ -n "$IMG_SIZE" ] && [[ "$IMG_SIZE" =~ ^[0-9]+$ ]]; then
                ( pv -n -s "$IMG_SIZE" "$OUTPUT_IMG" > "$DEST_FILE" ) 2>&1 | whiptail --gauge "Exporting image to Downloads..." 6 60 0
            else
                ( pv -n "$OUTPUT_IMG" > "$DEST_FILE" ) 2>&1 | whiptail --gauge "Exporting image to Downloads..." 6 60 0
            fi
        else
            cp "$OUTPUT_IMG" "$DEST_DIR/"
        fi
        echo "Copied image to $DEST_FILE"
    else
        echo "Warning: Android Download directory (~/storage/downloads or /sdcard/Download) not accessible."
        echo "Run 'termux-setup-storage' to grant storage permission if needed."
    fi
fi

echo "=========================================================="
echo "✅ Success! Your custom Termux image is ready: $OUTPUT_IMG"
echo "Flash this to your SD card using a tool like Pi Imager or Etcher on Android."
echo "NOTE: Because of the injection method, the Pi will boot once, process"
echo "your configurations silently, reboot automatically, and then be fully ready."
echo "=========================================================="
