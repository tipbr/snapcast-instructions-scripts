# Snapcast + Spotify Connect — Multi-Room Audio Setup

A complete guide for setting up synchronised multi-room audio using
[Snapcast](https://github.com/badaix/snapcast) and
[Spotify Connect](https://www.spotify.com/connect/) (via
[librespot](https://github.com/librespot-org/librespot) /
[raspotify](https://github.com/dtcooper/raspotify)) on Raspberry Pi hardware.

---

## Table of contents

1. [Architecture overview](#1-architecture-overview)
2. [Hardware & software requirements](#2-hardware--software-requirements)
3. [Automated setup (recommended)](#3-automated-setup-recommended)
4. [Manual setup — server](#4-manual-setup--server)
5. [Manual setup — clients](#5-manual-setup--clients)
6. [Stability, monitoring & auto-updates](#6-stability-monitoring--auto-updates)
7. [WiFi power-management fix (client disconnects)](#7-wifi-power-management-fix-client-disconnects)
8. [Verification & testing](#8-verification--testing)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Architecture overview

```
Spotify app (phone/desktop)
        │  Spotify Connect (zeroconf/mDNS)
        ▼
┌─────────────────────────────────────────────────────┐
│  Raspberry Pi 4  ·  192.168.0.230  (SERVER)         │
│                                                     │
│  raspotify / librespot                              │
│    └─ backend: pipe → /tmp/snapfifo (raw PCM)       │
│                                                     │
│  snapserver                                         │
│    └─ source: /tmp/snapfifo                         │
│    └─ streams to all snapclients on LAN             │
│                                                     │
│  snapclient (local)                                 │
│    └─ audio out: 3.5 mm headphone jack              │
└──────────────┬──────────────────────────────────────┘
               │  TCP 1704/1705 (Snapcast protocol)
       ┌───────┴────────┐
       ▼                ▼
┌──────────────┐  ┌──────────────┐
│ RPi Zero     │  │ RPi Zero     │
│ 192.168.0.231│  │ 192.168.0.232│
│ snapclient   │  │ snapclient   │
│ DAC+ Zero    │  │ DAC+ Zero    │
└──────────────┘  └──────────────┘
```

**Audio flow:**
1. You open Spotify on any device and select **Snapcast** as the speaker.
2. `librespot` (via raspotify) receives the audio stream and writes raw PCM to a
   named FIFO pipe (`/tmp/snapfifo`).
3. `snapserver` reads from the pipe and synchronously streams to every connected
   `snapclient` — including the local one on the server itself.
4. Each `snapclient` outputs audio through its configured sound device.

---

## 2. Hardware & software requirements

| Device | Role | IP | Audio output |
|---|---|---|---|
| Raspberry Pi 4 | Server + local player | `192.168.0.230` | Built-in 3.5 mm jack |
| Raspberry Pi Zero (×2) | Clients | `192.168.0.231`, `192.168.0.232` | HiFiBerry DAC+ Zero 1.x |

**All devices:**
- Raspberry Pi OS Lite (Bookworm **or** Bullseye), freshly flashed
- SSH enabled
- Connected to the same LAN (WiFi or Ethernet)
- Internet access (to download packages during setup)

**Raspberry Pi Zero note:** The Pi Zero 2 W is recommended for better
performance, but the original Pi Zero W will work. Ensure you have a stable 5 V
power supply — marginal supplies are a common cause of instability.

---

## 3. Automated setup (recommended)

The scripts handle everything described in sections 4–7 automatically.

### 3.1 Server (Raspberry Pi 4 — 192.168.0.230)

```bash
# SSH into the server Pi
ssh pi@192.168.0.230

# Download and run the setup script
curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/setup-server.sh \
  | sudo bash
```

The script will:
- Install `snapserver`, `snapclient`, and `raspotify`
- Configure librespot to write audio to `/tmp/snapfifo`
- Configure `snapserver` to read from that pipe
- Configure `snapclient` to output via the headphone jack
- Fix service start ordering so `raspotify` starts **after** `snapserver`
- Block `apresolve.spotify.com` to work around the Spotify API skip issue
  (see [librespot #1623](https://github.com/librespot-org/librespot/issues/1623))
- Disable WiFi power management
- Enable `unattended-upgrades` for automatic security updates
- Install and enable a watchdog systemd service that automatically restarts
  any crashed Snapcast component

### 3.2 Clients (Raspberry Pi Zero — 192.168.0.231 / .232)

Run the following on **each** client Pi:

```bash
# SSH into a client Pi (repeat for each)
ssh pi@192.168.0.231   # or 192.168.0.232

# Download and run the setup script
curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/setup-client.sh \
  | sudo bash
```

The script will:
- Enable the HiFiBerry DAC+ Zero device-tree overlay
- Install `snapclient`
- Configure `snapclient` to connect to `192.168.0.230` and output via the DAC
- **Disable WiFi power management** (fixes the periodic disconnect problem)
- Configure a persistent keep-alive for the WiFi interface
- Enable `unattended-upgrades`
- Install a watchdog systemd service

> **Reboot required after client setup** — the DAC overlay is applied on boot.

---

## 4. Manual setup — server

Follow this section if you prefer to understand and apply each step yourself.

### 4.1 System preparation

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl wget git avahi-daemon
```

### 4.2 Install Snapcast

Download the latest `.deb` packages from the
[Snapcast releases page](https://github.com/badaix/snapcast/releases).

```bash
SNAPCAST_VERSION="0.34.0"
ARCH=$(dpkg --print-architecture)                          # armhf for Pi 4 / Pi Zero
DISTRO=$(. /etc/os-release && echo "${VERSION_CODENAME}")  # e.g. bookworm or bullseye

# Server package (includes snapserver)
wget "https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VERSION}/snapserver_${SNAPCAST_VERSION}-1_${ARCH}_${DISTRO}.deb" \
  -O /tmp/snapserver.deb

# Client package
wget "https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VERSION}/snapclient_${SNAPCAST_VERSION}-1_${ARCH}_${DISTRO}.deb" \
  -O /tmp/snapclient.deb

sudo apt install -y /tmp/snapserver.deb /tmp/snapclient.deb
```

### 4.3 Install raspotify (Spotify Connect / librespot)

```bash
# Download the installer to a file first so you can review it before running
curl -fsSL https://dtcooper.github.io/raspotify/install.sh -o /tmp/raspotify-install.sh
bash /tmp/raspotify-install.sh
```

### 4.4 Configure librespot to write to a FIFO pipe

Edit `/etc/raspotify/conf` (create it if it does not exist):

```ini
# /etc/raspotify/conf

# Name shown in Spotify's device list
LIBRESPOT_NAME="Snapcast"

# Write raw PCM audio to a named pipe consumed by snapserver
LIBRESPOT_BACKEND=pipe
LIBRESPOT_DEVICE=/tmp/snapfifo

# Audio format — must match snapserver source configuration
LIBRESPOT_FORMAT=s16
LIBRESPOT_SAMPLE_RATE=44100

# Start at full volume so Spotify never receives silent audio.
# Without this, a stored volume of 0 can cause Spotify to skip
# tracks after a couple of seconds.
LIBRESPOT_INITIAL_VOLUME=100

# Use a fixed (passthrough) mixer — volume is controlled per-client
# by snapcast, not by librespot.
LIBRESPOT_VOLUME_CTRL=fixed

# Disable the audio file cache to avoid stale data causing skips.
LIBRESPOT_DISABLE_AUDIO_CACHE=

# Uncomment to enable verbose logging when diagnosing skip issues.
# View with: journalctl -u raspotify -f
# LIBRESPOT_VERBOSE=

# Optional: normalise volume
# LIBRESPOT_ENABLE_VOLUME_NORMALISATION=true
```

> **Older raspotify versions** use `/etc/default/raspotify` with a different
> syntax.  See the [raspotify README](https://github.com/dtcooper/raspotify)
> for the appropriate format for your installed version.

### 4.4a Fix service start ordering

Raspotify must start **after** snapserver so that the FIFO has a reader before
librespot writes to it.  Create a systemd drop-in override:

```bash
sudo mkdir -p /etc/systemd/system/raspotify.service.d
sudo tee /etc/systemd/system/raspotify.service.d/after-snapserver.conf <<'EOF'
[Unit]
After=snapserver.service
Wants=snapserver.service
EOF
sudo systemctl daemon-reload
```

### 4.4b Block `apresolve.spotify.com` (Spotify API skip fix)

A Spotify backend change in late 2024 causes librespot to resolve tracks through
`apresolve.spotify.com`, which returns access points incompatible with open-source
clients — resulting in tracks playing for 1–2 seconds then skipping.
Blocking this domain forces librespot to use its fallback access-point list.
(See [librespot issue #1623](https://github.com/librespot-org/librespot/issues/1623).)

```bash
echo "0.0.0.0 apresolve.spotify.com" | sudo tee -a /etc/hosts
```

Restart raspotify after making this change:

```bash
sudo systemctl restart raspotify
```

### 4.5 Configure snapserver

Edit `/etc/snapserver.conf`:

```ini
[server]
# Bind to all interfaces so clients can connect
bind_to_address = 0.0.0.0

[stream]
# Read raw PCM from the FIFO written by librespot
source = pipe:///tmp/snapfifo?name=Spotify&sampleformat=44100:16:2&codec=pcm

[http]
# Web interface / control API
enabled = true
port = 1780
```

### 4.6 Configure local snapclient (headphone jack)

Edit `/etc/default/snapclient`:

```bash
START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--host 127.0.0.1 --soundcard hw:Headphones --latency 0"
```

> **Note:** The ALSA card name `Headphones` is the built-in 3.5 mm jack on
> Raspberry Pi OS.  Verify with `aplay -l`.  If the name differs, adjust
> accordingly (e.g., `hw:0` or `plughw:0`).

### 4.7 Configure audio output (headphone jack forced)

The Pi 4 defaults to HDMI audio if a monitor is connected.  Force analog output:

```bash
# Add to /boot/firmware/config.txt  (Bookworm)
# or  /boot/config.txt              (Bullseye and earlier)
sudo tee -a /boot/firmware/config.txt <<'EOF'

# Force 3.5 mm headphone jack (disable HDMI audio auto-select)
dtparam=audio=on
audio_pwm_mode=2
EOF
```

### 4.8 Enable and start services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now snapserver snapclient raspotify
```

---

## 5. Manual setup — clients

Perform all steps on **each** client Pi (192.168.0.231 and 192.168.0.232).

### 5.1 System preparation

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl wget
```

### 5.2 Enable HiFiBerry DAC+ Zero overlay

```bash
# Disable the built-in audio (conflicts with HiFiBerry)
sudo sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' /boot/firmware/config.txt 2>/dev/null \
  || sudo sed -i 's/^dtparam=audio=on/#dtparam=audio=on/' /boot/config.txt

# Add the HiFiBerry DAC overlay
CONFIG_FILE=/boot/firmware/config.txt
[ -f "$CONFIG_FILE" ] || CONFIG_FILE=/boot/config.txt
echo "dtoverlay=hifiberry-dac" | sudo tee -a "$CONFIG_FILE"
```

### 5.3 Configure ALSA for HiFiBerry

Create `/etc/asound.conf`:

```
pcm.!default {
    type hw
    card sndrpihifiberry
}

ctl.!default {
    type hw
    card sndrpihifiberry
}
```

### 5.4 Install snapclient

```bash
SNAPCAST_VERSION="0.34.0"
ARCH=$(dpkg --print-architecture)                          # Raspberry Pi OS reports 'armhf' for all Pi models including the Pi Zero (ARMv6 CPU)
DISTRO=$(. /etc/os-release && echo "${VERSION_CODENAME}")  # e.g. bookworm or bullseye

wget "https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VERSION}/snapclient_${SNAPCAST_VERSION}-1_${ARCH}_${DISTRO}.deb" \
  -O /tmp/snapclient.deb

sudo apt install -y /tmp/snapclient.deb
```

### 5.5 Configure snapclient

Edit `/etc/default/snapclient`:

```bash
START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--host 192.168.0.230 --soundcard hw:sndrpihifiberry --latency 0"
```

### 5.6 Enable and start services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now snapclient
```

### 5.7 Reboot to apply DAC overlay

```bash
sudo reboot
```

---

## 6. Stability, monitoring & auto-updates

### 6.1 Automatic security updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

This applies Debian security patches automatically without requiring manual
intervention.

### 6.2 Snapcast watchdog service

The setup scripts install the following systemd unit on all devices.  It
polls the Snapcast services every 30 seconds and restarts them if they have
stopped or failed.

```ini
# /etc/systemd/system/snapcast-watchdog.service
[Unit]
Description=Snapcast watchdog — restart failed Snapcast services
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/snapcast-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Watchdog script `/usr/local/bin/snapcast-watchdog.sh`:

```bash
#!/usr/bin/env bash
# Restart any Snapcast service that is not active.
SERVICES=("snapserver" "snapclient" "raspotify")

while true; do
    for svc in "${SERVICES[@]}"; do
        if systemctl list-unit-files --quiet "${svc}.service" &>/dev/null; then
            if ! systemctl is-active --quiet "${svc}"; then
                echo "$(date): ${svc} is not active — restarting"
                systemctl restart "${svc}"
            fi
        fi
    done
    sleep 30
done
```

### 6.3 systemd service hardening

Both setup scripts configure the Snapcast services with these restart policies:

```ini
Restart=on-failure
RestartSec=5s
```

---

## 7. WiFi power-management fix (client disconnects)

### Why clients disconnect periodically

Linux WiFi drivers enable power-saving by default: the interface periodically
enters a low-power state to save battery.  On a Raspberry Pi Zero this causes
the TCP connection to the Snapcast server to be dropped — resulting in audio
cut-outs and requiring a manual restart.

### Fix 1 — disable power management immediately (non-persistent)

```bash
sudo iwconfig wlan0 power off
```

### Fix 2 — disable power management persistently (recommended)

The setup script uses NetworkManager's configuration drop-in file (Bookworm):

```ini
# /etc/NetworkManager/conf.d/99-disable-wifi-powersave.conf
[connection]
wifi.powersave = 2
```

For Bullseye (uses `dhcpcd`/`wpa_supplicant`), the script adds a hook:

```bash
# /etc/rc.local  (just before exit 0)
/sbin/iwconfig wlan0 power off
```

### Fix 3 — TCP keep-alive tuning

Keeping TCP connections alive ensures the server can detect and recover from a
dead client quickly:

```bash
# Add to /etc/sysctl.d/99-tcp-keepalive.conf
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 6
```

Apply immediately: `sudo sysctl -p /etc/sysctl.d/99-tcp-keepalive.conf`

### About Wake-on-LAN / Wake-on-WLAN

Standard Wake-on-LAN (WOL) sends a magic packet to wake a **powered-off** or
**suspended** machine.  The Pi Zero devices here are always powered on, so
true WOL is not needed.  What matters is preventing the WiFi driver from
sleeping — which the power-management fix above handles completely.

---

## 8. Verification & testing

### Check services are running

On the server:

```bash
systemctl status snapserver snapclient raspotify snapcast-watchdog
```

On each client:

```bash
systemctl status snapclient snapcast-watchdog
```

### Verify audio devices

On the server:

```bash
aplay -l   # should list Headphones (or similar) as a capture/playback device
```

On each client (after reboot):

```bash
aplay -l   # should list sndrpihifiberry (HiFiBerry DAC)
```

### Test playback

1. Open Spotify on any device on the same network.
2. Tap the **Connect to a device** icon and select **Snapcast**.
3. Play a track — audio should come from all devices simultaneously and in sync.

### Check Snapcast web UI

Open `http://192.168.0.230:1780` in a browser to see connected clients, adjust
individual client volumes, and assign clients to groups.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Snapcast device not visible in Spotify | `raspotify` not running or mDNS not working | `sudo systemctl restart raspotify`; ensure `avahi-daemon` is running |
| Spotify plays a few seconds then skips to next track | librespot volume starts at 0, causing Spotify's silence detection to skip; or stale audio cache | Ensure `LIBRESPOT_INITIAL_VOLUME=100`, `LIBRESPOT_VOLUME_CTRL=fixed`, and `LIBRESPOT_DISABLE_AUDIO_CACHE=` are set in the raspotify conf; clear cache with `sudo rm -rf /var/cache/raspotify /var/cache/librespot`; then `sudo systemctl restart raspotify` |
| Spotify plays a few seconds then skips (still, after above fix) | Spotify API backend change (late 2024/2025) routes through `apresolve.spotify.com`, returning access points incompatible with librespot | Block the domain: `sudo sh -c 'echo "0.0.0.0 apresolve.spotify.com" >> /etc/hosts'` then `sudo systemctl restart raspotify`. See [librespot #1623](https://github.com/librespot-org/librespot/issues/1623) |
| Spotify plays a few seconds then skips (still, after both fixes) | raspotify starts before snapserver; librespot writes to FIFO with no reader and blocks/timeouts | Ensure service ordering drop-in is in place: `sudo cat /etc/systemd/system/raspotify.service.d/after-snapserver.conf` (re-run `setup-server.sh` if missing) |
| Tracks skip with `Symphonia Decoder Error: end of stream` in logs | Corrupted or incomplete librespot audio-cache files (persists even after reboot) | Clear cache: `sudo rm -rf /var/cache/raspotify /var/cache/librespot /var/lib/raspotify/.local/share/librespot /var/lib/raspotify/.cache/librespot` then `sudo systemctl restart raspotify`. Re-run `setup-server.sh` to prevent recurrence. |
| No audio on server headphone jack | Wrong ALSA device name | Run `aplay -l`; update `--soundcard` in `/etc/default/snapclient` |
| No audio on client | DAC overlay not loaded | Check `aplay -l` after reboot; verify `dtoverlay=hifiberry-dac` in `config.txt` |
| Client disconnects periodically | WiFi power management | Verify `iwconfig wlan0` shows `Power Management:off`; re-run client setup |
| Audio stutters / desync | Network congestion or CPU load | Increase `--latency` value in snapclient opts; use wired Ethernet if possible |
| raspotify fails to start | `/tmp/snapfifo` not created | The setup script creates the FIFO; check `ls -la /tmp/snapfifo` |
| `snapserver` won't start | Config syntax error | Run `snapserver --config /etc/snapserver.conf` to see error messages |

### Viewing logs

Use `show-logs.sh` for a quick diagnostic overview, or run the `journalctl`
commands directly.

```bash
# --- Quick all-in-one log tool (recommended) ---

# Follow all Snapcast-related logs in real time (best for reproducing a skip)
sudo bash scripts/show-logs.sh

# Print service status + FIFO/apresolve diagnostics + recent logs
sudo bash scripts/show-logs.sh --status

# Show only warnings and errors from the past hour
sudo bash scripts/show-logs.sh --errors

# Show the last 200 log lines
sudo bash scripts/show-logs.sh --lines 200

# --- Run over SSH directly ---
ssh pi@192.168.0.230 'sudo bash -s' < scripts/show-logs.sh
```

```bash
# --- Raw journalctl commands ---

# Follow all Snapcast-related logs in real time
journalctl -f -u snapserver -u snapclient -u raspotify

# Show the last 100 lines without following
journalctl -u snapserver -u snapclient -u raspotify -n 100 --no-pager

# Warnings and errors only (great for spotting the skip root-cause)
journalctl -u raspotify --since "1 hour ago" -p warning --no-pager

# Watchdog log
journalctl -u snapcast-watchdog -n 50
```
