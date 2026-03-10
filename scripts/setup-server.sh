#!/usr/bin/env bash
# =============================================================================
# setup-server.sh
#
# Automated setup for the Snapcast SERVER on Raspberry Pi 4.
#
# What this script does:
#   1. Updates the system
#   2. Installs snapserver + snapclient (for local headphone-jack playback)
#   3. Installs raspotify (Spotify Connect via librespot)
#   4. Creates the FIFO pipe and configures librespot to write to it
#   5. Configures snapserver to read from the FIFO
#   6. Configures the local snapclient to output via the 3.5 mm jack
#   7. Forces analog audio output on Pi 4 (disables auto-select to HDMI)
#   8. Disables WiFi power management (persistent)
#   9. Tunes TCP keep-alive parameters
#  10. Enables unattended-upgrades for automatic security patches
#  11. Installs a watchdog service that auto-restarts Snapcast components
#  12. Enables and starts all services
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/setup-server.sh | sudo bash
#   — or —
#   sudo bash setup-server.sh
#
# Tested on: Raspberry Pi OS Lite (Bookworm / Bullseye), Raspberry Pi 4
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these if your setup differs
# ---------------------------------------------------------------------------
SNAPCAST_VERSION="0.34.0"
SERVER_IP="192.168.0.230"
SNAPFIFO="/tmp/snapfifo"
SPOTIFY_DEVICE_NAME="Snapcast"

# ALSA card name for the Pi 4 headphone jack.
# Run 'aplay -l' to confirm; common values: Headphones, bcm2835 Headphones, 0
HEADPHONE_CARD="Headphones"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[setup-server] $*"; }
die()  { echo "[setup-server] ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."
}

detect_arch() {
    local arch
    arch=$(dpkg --print-architecture)
    case "$arch" in
        armhf|arm64|amd64) echo "$arch" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
}

detect_distro() {
    local codename=""
    if [ -f /etc/os-release ]; then
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
        [ -z "$codename" ] && die "/etc/os-release found but VERSION_CODENAME is not set. Cannot determine Debian/Raspbian release."
    else
        die "/etc/os-release not found. Cannot determine Debian/Raspbian release."
    fi
    case "$codename" in
        bookworm|bullseye|trixie) echo "$codename" ;;
        *) die "Unsupported Debian/Raspbian release: '${codename}'. Expected bookworm, bullseye, or trixie." ;;
    esac
}

# Determine the correct boot config file (Bookworm uses /boot/firmware/config.txt)
boot_config() {
    if [ -f /boot/firmware/config.txt ]; then
        echo /boot/firmware/config.txt
    else
        echo /boot/config.txt
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root

log "=== Snapcast Server Setup starting ==="

# --- 1. System update -------------------------------------------------------
log "Updating package lists and upgrading installed packages..."
apt-get update -y
apt-get full-upgrade -y
apt-get install -y curl wget avahi-daemon unattended-upgrades wireless-tools

# --- 2. Install Snapcast ----------------------------------------------------
ARCH=$(detect_arch)
DISTRO=$(detect_distro)
log "Detected architecture: $ARCH"
log "Detected distro: $DISTRO"
log "Installing Snapcast ${SNAPCAST_VERSION}..."

BASE_URL="https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VERSION}"
SERVER_DEB="snapserver_${SNAPCAST_VERSION}-1_${ARCH}_${DISTRO}.deb"
CLIENT_DEB="snapclient_${SNAPCAST_VERSION}-1_${ARCH}_${DISTRO}.deb"

wget -q "${BASE_URL}/${SERVER_DEB}" -O "/tmp/${SERVER_DEB}"
wget -q "${BASE_URL}/${CLIENT_DEB}" -O "/tmp/${CLIENT_DEB}"

# apt will handle dependencies automatically
apt-get install -y "/tmp/${SERVER_DEB}"
apt-get install -y "/tmp/${CLIENT_DEB}"

rm -f "/tmp/${SERVER_DEB}" "/tmp/${CLIENT_DEB}"
log "Snapcast installed."

# --- 3. Install raspotify (Spotify Connect) ---------------------------------
log "Installing raspotify..."
# Download the installer to a temp file so it can be inspected before running.
RASPOTIFY_INSTALLER=$(mktemp /tmp/raspotify-install-XXXXXX.sh)
curl -fsSL https://dtcooper.github.io/raspotify/install.sh -o "$RASPOTIFY_INSTALLER"
bash "$RASPOTIFY_INSTALLER"
rm -f "$RASPOTIFY_INSTALLER"
log "raspotify installed."

# --- 4. Create FIFO and configure librespot ---------------------------------
log "Configuring librespot / raspotify..."

# Create the FIFO so it exists before services start.
# snapserver will also try to create it, but we do it here to set ownership.
if [ ! -p "$SNAPFIFO" ]; then
    mkfifo "$SNAPFIFO"
    chmod 666 "$SNAPFIFO"
fi

# Persist FIFO across reboots via tmpfiles.d
cat > /etc/tmpfiles.d/snapcast.conf <<EOF
p  ${SNAPFIFO}  0666  -  -  -  -
EOF

# Detect raspotify config location (newer versions use /etc/raspotify/conf)
if [ -d /etc/raspotify ]; then
    RASPOTIFY_CONF=/etc/raspotify/conf
else
    RASPOTIFY_CONF=/etc/default/raspotify
fi

log "Writing raspotify config to ${RASPOTIFY_CONF}..."

# Back up any existing config
[ -f "$RASPOTIFY_CONF" ] && cp "$RASPOTIFY_CONF" "${RASPOTIFY_CONF}.bak"

cat > "$RASPOTIFY_CONF" <<EOF
# raspotify / librespot configuration
# Generated by setup-server.sh

# Name shown in Spotify's "Connect to a device" list
LIBRESPOT_NAME="${SPOTIFY_DEVICE_NAME}"

# Write raw PCM audio to the named pipe consumed by snapserver
LIBRESPOT_BACKEND=pipe
LIBRESPOT_DEVICE=${SNAPFIFO}

# Audio format — must match snapserver source sampleformat
LIBRESPOT_FORMAT=s16
LIBRESPOT_SAMPLE_RATE=44100

# Uncomment to enable volume normalisation
# LIBRESPOT_ENABLE_VOLUME_NORMALISATION=true
EOF

# --- 5. Configure snapserver ------------------------------------------------
log "Configuring snapserver..."

[ -f /etc/snapserver.conf ] && cp /etc/snapserver.conf /etc/snapserver.conf.bak

cat > /etc/snapserver.conf <<EOF
# snapserver configuration
# Generated by setup-server.sh

[server]
# Listen on all interfaces so clients can connect
bind_to_address = 0.0.0.0

[stream]
# Read raw PCM from the FIFO written by librespot
source = pipe://${SNAPFIFO}?name=Spotify&sampleformat=44100:16:2&codec=pcm

[http]
# Web UI and control API — accessible at http://${SERVER_IP}:1780
enabled = true
port = 1780

[logging]
sink =
EOF

# --- 6. Configure local snapclient (headphone jack) -------------------------
log "Configuring snapclient for local headphone-jack playback..."

[ -f /etc/default/snapclient ] && cp /etc/default/snapclient /etc/default/snapclient.bak

cat > /etc/default/snapclient <<EOF
# snapclient configuration (local player on server)
# Generated by setup-server.sh

START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--host 127.0.0.1 --soundcard hw:${HEADPHONE_CARD} --latency 0"
EOF

# --- 7. Force analog audio output on Pi 4 -----------------------------------
CONFIG_FILE=$(boot_config)
log "Configuring analog audio output in ${CONFIG_FILE}..."

# Ensure built-in audio is enabled
if ! grep -q "^dtparam=audio=on" "$CONFIG_FILE"; then
    # Remove any commented-out version and add a clean line
    sed -i 's/^#\s*dtparam=audio=on.*//' "$CONFIG_FILE"
    echo "dtparam=audio=on" >> "$CONFIG_FILE"
fi

# Set PWM mode for better headphone audio quality (reduces noise)
if ! grep -q "^audio_pwm_mode" "$CONFIG_FILE"; then
    echo "audio_pwm_mode=2" >> "$CONFIG_FILE"
fi

# --- 8. Disable WiFi power management ---------------------------------------
log "Disabling WiFi power management..."

# NetworkManager (Bookworm default)
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-disable-wifi-powersave.conf <<EOF
# Disable WiFi power saving to prevent Snapcast disconnects
[connection]
wifi.powersave = 2
EOF
fi

# Fallback: dhcpcd / wpa_supplicant based systems (Bullseye)
# Add to /etc/rc.local if it exists
if [ -f /etc/rc.local ]; then
    if ! grep -q "iwconfig wlan0 power off" /etc/rc.local; then
        sed -i 's/^exit 0/\/sbin\/iwconfig wlan0 power off 2>\/dev\/null || true\n\nexit 0/' /etc/rc.local
    fi
fi

# Apply immediately (best-effort — interface may not be present)
/sbin/iwconfig wlan0 power off 2>/dev/null || true

# --- 9. TCP keep-alive tuning ------------------------------------------------
log "Tuning TCP keep-alive parameters..."

cat > /etc/sysctl.d/99-tcp-keepalive.conf <<EOF
# TCP keep-alive tuning for Snapcast stability
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 6
EOF

sysctl -p /etc/sysctl.d/99-tcp-keepalive.conf

# --- 10. Automatic security updates -----------------------------------------
log "Enabling unattended-upgrades..."

# Configure unattended-upgrades with sensible defaults
cat > /etc/apt/apt.conf.d/50unattended-upgrades-snapcast <<EOF
// Enable automatic security updates
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades-snapcast <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades

# --- 11. Watchdog service ----------------------------------------------------
log "Installing Snapcast watchdog service..."

# Watchdog script
cat > /usr/local/bin/snapcast-watchdog.sh <<'WATCHDOG'
#!/usr/bin/env bash
# Snapcast watchdog — restarts any Snapcast service that has stopped.
SERVICES=("snapserver" "snapclient" "raspotify")

while true; do
    for svc in "${SERVICES[@]}"; do
        # Only act if the service is installed
        if systemctl list-unit-files --quiet "${svc}.service" 2>/dev/null; then
            if ! systemctl is-active --quiet "${svc}"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] ${svc} is not active — restarting"
                systemctl restart "${svc}" || true
            fi
        fi
    done
    sleep 30
done
WATCHDOG

chmod +x /usr/local/bin/snapcast-watchdog.sh

cat > /etc/systemd/system/snapcast-watchdog.service <<EOF
[Unit]
Description=Snapcast watchdog — restart failed Snapcast services
After=network.target snapserver.service

[Service]
Type=simple
ExecStart=/usr/local/bin/snapcast-watchdog.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Harden the snapserver and snapclient service restart policies
mkdir -p /etc/systemd/system/snapserver.service.d
cat > /etc/systemd/system/snapserver.service.d/restart.conf <<EOF
[Service]
Restart=on-failure
RestartSec=5s
EOF

mkdir -p /etc/systemd/system/snapclient.service.d
cat > /etc/systemd/system/snapclient.service.d/restart.conf <<EOF
[Service]
Restart=on-failure
RestartSec=5s
EOF

# --- 12. Enable and start services ------------------------------------------
log "Enabling and starting services..."

systemctl daemon-reload
systemctl enable snapserver snapclient raspotify snapcast-watchdog
systemctl restart snapserver snapclient raspotify
systemctl start  snapcast-watchdog

# --- Summary ----------------------------------------------------------------
log ""
log "=== Setup complete! ==="
log ""
log "Services:"
for svc in snapserver snapclient raspotify snapcast-watchdog; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    log "  ${svc}: ${STATUS}"
done
log ""
log "Snapcast web UI: http://${SERVER_IP}:1780"
log ""
log "Next steps:"
log "  1. Open Spotify on any device on the same network."
log "  2. Tap 'Connect to a device' and select '${SPOTIFY_DEVICE_NAME}'."
log "  3. Play audio — it should come through all connected devices."
log ""
log "If the headphone jack device name is wrong, edit /etc/default/snapclient"
log "and update --soundcard.  Run 'aplay -l' to list available devices."
log ""
log "A reboot is recommended to ensure all kernel/config changes take effect:"
log "  sudo reboot"
