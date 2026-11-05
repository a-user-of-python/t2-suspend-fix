#!/usr/bin/env bash
# lid-lock-fallback.sh — LAST RESORT, not a suspend fix.
#
# If your exact model + firmware combination refuses to resume from real
# suspend no matter what (this is the documented outcome for at least one
# sibling model, the MacBookPro16,2, even on the modern t2bce stack), the
# reliable fallback is: don't suspend. Closing the lid just locks the
# screen; the machine stays awake, uses some battery, but never loses
# your session to a forced reboot.
#
# This script toggles that fallback:
#   sudo ./lid-lock-fallback.sh on     # lid close = lock only, no suspend
#   sudo ./lid-lock-fallback.sh off    # back to normal logind behaviour
#
# It writes/removes one drop-in: /etc/systemd/logind.conf.d/t2-lid-lock.conf
# and restarts systemd-logind (which logs you out — run it from a TTY or
# accept the logout).

set -euo pipefail

DROPIN="/etc/systemd/logind.conf.d/t2-lid-lock.conf"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 on|off"

case "${1:-}" in
    on)
        mkdir -p "$(dirname "$DROPIN")"
        cat > "$DROPIN" <<'EOF'
# t2-suspend-fix fallback: lid close locks instead of suspending.
# Applied by lid-lock-fallback.sh — remove with: lid-lock-fallback.sh off
[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=ignore
EOF
        say "Fallback ON: $DROPIN written."
        say "Restarting systemd-logind (this will log you out)..."
        systemctl restart systemd-logind
        ;;
    off)
        rm -f "$DROPIN"
        say "Fallback OFF: $DROPIN removed."
        say "Restarting systemd-logind (this will log you out)..."
        systemctl restart systemd-logind
        ;;
    *)
        echo "Usage: sudo $0 on|off" >&2
        exit 2
        ;;
esac
