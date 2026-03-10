#!/usr/bin/env bash
# =============================================================================
# show-logs.sh
#
# SSH-friendly log monitoring for the Snapcast + raspotify stack.
# Use this to diagnose playback issues — particularly tracks that play for
# 1–2 seconds then skip to the next song.
#
# Usage:
#   sudo bash show-logs.sh               # Follow all logs in real time (Ctrl-C to quit)
#   sudo bash show-logs.sh --status      # Print service status + recent errors
#   sudo bash show-logs.sh --errors      # Show warnings/errors from the past hour
#   sudo bash show-logs.sh --lines 200   # Show last 200 log lines (no follow)
#
# Run over SSH, e.g.:
#   ssh pi@192.168.0.230 'sudo bash -s' < show-logs.sh
#   — or —
#   ssh pi@192.168.0.230 \
#     'curl -fsSL https://raw.githubusercontent.com/tipbr/snapcast-instructions-scripts/main/scripts/show-logs.sh | sudo bash'
#
# Tested on: Raspberry Pi OS Lite (Bookworm / Bullseye), Raspberry Pi 4
# =============================================================================

set -euo pipefail

SNAPFIFO="/tmp/snapfifo"
SERVICES="snapserver snapclient raspotify snapcast-watchdog"
MODE="follow"
LINES=100

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)   MODE="status";  shift ;;
        --errors)   MODE="errors";  shift ;;
        --follow|-f) MODE="follow"; shift ;;
        --lines)
            MODE="lines"
            shift
            if [[ -n "${1:-}" && "${1:-}" =~ ^[0-9]+$ ]]; then
                LINES="$1"
                shift
            fi
            ;;
        --help|-h)
            sed -n 's/^# \?//p' "$0" | head -25
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
header() { echo; printf '\033[1;36m=== %s ===\033[0m\n' "$*"; echo; }
hr()     { printf '%.0s-' {1..72}; echo; }

print_status() {
    header "Service Status"
    for svc in $SERVICES; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            ACTIVE=$(systemctl is-active  "$svc" 2>/dev/null || echo "inactive")
            ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
            printf "  %-32s  active=%-10s  enabled=%s\n" "${svc}" "${ACTIVE}" "${ENABLED}"
        fi
    done
    echo
}

print_diagnostics() {
    header "FIFO Pipe"
    if [ -p "$SNAPFIFO" ]; then
        echo "  $SNAPFIFO  ->  exists (OK)"
        ls -la "$SNAPFIFO"
    else
        echo "  $SNAPFIFO does NOT exist"
        echo "  Fix: sudo mkfifo -m 0666 $SNAPFIFO"
        echo "       (or re-run setup-server.sh)"
    fi

    echo
    header "apresolve.spotify.com (skip workaround)"
    if grep -q "apresolve.spotify.com" /etc/hosts 2>/dev/null; then
        echo "  /etc/hosts: BLOCKED -- skip workaround is active"
    else
        echo "  /etc/hosts: NOT blocked"
        echo "  If tracks skip after 1-2 seconds, add to /etc/hosts:"
        echo "    0.0.0.0 apresolve.spotify.com"
        echo "  See: https://github.com/librespot-org/librespot/issues/1623"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$MODE" in
    status)
        print_status
        print_diagnostics
        header "Recent Logs (last 50 lines per service)"
        for svc in $SERVICES; do
            if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
                echo
                hr
                echo "  $svc"
                hr
                journalctl -u "$svc" -n 50 --no-pager 2>/dev/null || true
            fi
        done
        ;;

    errors)
        print_status
        print_diagnostics
        header "Warnings & Errors — past 1 hour"
        journalctl \
            -u snapserver -u snapclient -u raspotify -u snapcast-watchdog \
            --since "1 hour ago" --no-pager -p warning 2>/dev/null || true
        ;;

    lines)
        print_status
        print_diagnostics
        header "Last ${LINES} log lines"
        journalctl \
            -u snapserver -u snapclient -u raspotify -u snapcast-watchdog \
            -n "$LINES" --no-pager 2>/dev/null || true
        ;;

    follow)
        print_status
        print_diagnostics
        header "Following logs in real time — press Ctrl-C to stop"
        echo "  Tip: watch for 'error', 'skip', 'disconnect', 'failed', 'timeout'"
        echo "  Tip: play a Spotify track and observe the log output to pinpoint skips"
        echo
        journalctl -f \
            -u snapserver -u snapclient -u raspotify -u snapcast-watchdog
        ;;
esac
