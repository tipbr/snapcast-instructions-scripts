# snapcast-instructions-scripts

Setup instructions and scripts for a **Snapcast multi-room audio system** with **Spotify Connect** on Raspberry Pi hardware.

## What's included

| File | Purpose |
|---|---|
| [`SETUP.md`](SETUP.md) | Full step-by-step setup guide |
| [`scripts/setup-server.sh`](scripts/setup-server.sh) | Automated setup script for the Snapcast server (Raspberry Pi 4) |
| [`scripts/setup-client.sh`](scripts/setup-client.sh) | Automated setup script for Snapcast clients (Raspberry Pi Zero + DAC+ Zero) |
| [`scripts/show-logs.sh`](scripts/show-logs.sh) | SSH log monitoring tool — diagnose skip and disconnect issues in real time |

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

## Diagnosing playback issues (skip after 1–2 s)

If tracks start then skip immediately, run the log monitoring tool over SSH:

```bash
# Follow live logs while reproducing the skip
ssh pi@192.168.0.230 'curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/show-logs.sh | sudo bash'

# Print service status + diagnostic summary
ssh pi@192.168.0.230 'curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/show-logs.sh | sudo bash -s -- --status'

# Show only warnings/errors from the past hour
ssh pi@192.168.0.230 'curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/show-logs.sh | sudo bash -s -- --errors'
```

See [SETUP.md § 9 Troubleshooting](SETUP.md#9-troubleshooting) for a full list of known causes and fixes.
