# snapcast-instructions-scripts

Setup instructions and scripts for a **Snapcast multi-room audio system** with **Spotify Connect** on Raspberry Pi hardware.

## What's included

| File | Purpose |
|---|---|
| [`SETUP.md`](SETUP.md) | Full step-by-step setup guide |
| [`scripts/setup-server.sh`](scripts/setup-server.sh) | Automated setup script for the Snapcast server (Raspberry Pi 4) |
| [`scripts/setup-client.sh`](scripts/setup-client.sh) | Automated setup script for Snapcast clients (Raspberry Pi Zero + DAC+ Zero) |

## Quick start

1. Read [`SETUP.md`](SETUP.md) for the full guide and architecture overview.
2. SSH into your server Pi and run:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/setup-server.sh)
   ```
3. SSH into each client Pi and run:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/setup-client.sh)
   ```

## Hardware

| Device | Role | IP | Audio out |
|---|---|---|---|
| Raspberry Pi 4 | Server + local player | 192.168.0.230 | 3.5 mm headphone jack |
| Raspberry Pi Zero | Client 1 | 192.168.0.231 | HiFiBerry DAC+ Zero 1.x |
| Raspberry Pi Zero | Client 2 | 192.168.0.232 | HiFiBerry DAC+ Zero 1.x |

All devices run **Raspberry Pi OS Lite** (Debian Bookworm or Bullseye).
