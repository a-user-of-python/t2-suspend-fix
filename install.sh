#!/usr/bin/env bash
# t2-suspend-fix installer — Fedora on a T2 Mac (target: MacBookPro16,1)
#
# What it does (and nothing else):
#   1. Adds the documented T2 kernel arguments with grubby (only the ones
#      that are missing; exactly which ones were added is recorded).
#   2. Detects the T2 driver stack (t2bce vs legacy apple_bce).
#      - t2bce stack: installs NO module-unload services. The t2linux wiki
#        says t2bce handles suspend internally and must not be unloaded.
#        The Wi-Fi service is available with --with-wifi-service if Wi-Fi
#        is dead after resume on your kernel.
#      - legacy apple_bce stack: installs suspend-fix-t2.service and
#        suspend-fix-wifi.service (the documented unload/reload remedy).
#   3. Disables stale suspend-fix units left over from the old (now
#      deleted) GitHub suspend-fix script if they are enabled — they
#      conflict with the current stack guidance. They are recorded so
#      uninstall.sh can re-enable them.
#   4. Writes a backup + state file under /var/lib/t2-suspend-fix so
#      uninstall.sh can revert every change precisely.
#
# Safety: no kernel is installed or removed, no initramfs is rebuilt, no
# bootloader is replaced. Kernel arguments are changed with grubby, which
# edits the BLS entries and can be reverted by uninstall.sh. Every arg
# used here is a documented T2 arg (see README.md "Sources").
#
# Usage:
#   sudo ./install.sh [--sleep=deep|s2idle] [--stack=auto|t2bce|legacy]
#                     [--with-wifi-service] [--dry-run] [--force]
#
#   --sleep           mem_sleep_default value (default: deep — reported
#                     working on MacBookPro16,1; s2idle is the documented
#                     fallback if deep misbehaves on your firmware)
#   --stack           override stack detection
#   --with-wifi-service  install the brcmfmac unload/reload service even
#                     on the t2bce stack (only if Wi-Fi dies after resume)
#   --dry-run         print what would happen, change nothing
#   --force           continue despite model/OS mismatch warnings

set -euo pipefail

SLEEP_MODE="deep"
STACK="auto"
WITH_WIFI=0
DRY_RUN=0
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --sleep=deep|--sleep=s2idle) SLEEP_MODE="${arg#--sleep=}" ;;
        --stack=auto|--stack=t2bce|--stack=legacy) STACK="${arg#--stack=}" ;;
        --with-wifi-service) WITH_WIFI=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

STATE_DIR="/var/lib/t2-suspend-fix"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$STATE_DIR/backup-$TIMESTAMP"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
    # run a mutating command, or just print it in dry-run mode
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "Run this as root: sudo ./install.sh"

if [ ! -f /etc/fedora-release ]; then
    [ "$FORCE" -eq 1 ] || die "This does not look like Fedora (/etc/fedora-release missing). Use --force to override."
    warn "Not a Fedora system — continuing because --force was given."
fi

MODEL="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)"
if [ "$MODEL" != "MacBookPro16,1" ]; then
    [ "$FORCE" -eq 1 ] || die "DMI reports '$MODEL', not MacBookPro16,1. This package targets the 2019 16-inch. Use --force to install anyway."
    warn "Model is '$MODEL', not MacBookPro16,1 — continuing because --force was given."
else
    say "Model check: MacBookPro16,1 (2019 16-inch) — OK"
fi

command -v grubby >/dev/null 2>&1 || die "grubby not found. On Fedora: sudo dnf install grubby"

# Kernel arguments recommended for T2 Macs (see README.md for sources).
BASE_ARGS="intel_iommu=on iommu=pt pm_async=off pcie_ports=compat pcie_aspm=off"
SLEEP_ARG="mem_sleep_default=$SLEEP_MODE"
ALL_ARGS="$BASE_ARGS $SLEEP_ARG"

# ------------------------------------------------------------- stack detect
detect_stack() {
    if lsmod | grep -q '^t2bce'; then
        echo "t2bce"
    elif lsmod | grep -q '^apple_bce'; then
        echo "legacy"
    else
        echo "unknown"
    fi
}

if [ "$STACK" = "auto" ]; then
    STACK="$(detect_stack)"
fi
case "$STACK" in
    t2bce)  say "Driver stack: t2bce (current t2linux stack)" ;;
    legacy) say "Driver stack: legacy apple_bce" ;;
    *)      warn "Could not detect a loaded T2 stack (no t2bce_* or apple_bce module)."
            warn "Installing kernel arguments only. Check 'lsmod | grep -E \"t2bce|apple_bce\"'"
            warn "and re-run with --stack=t2bce or --stack=legacy if needed."
            STACK="unknown" ;;
esac

# Sleep states this firmware actually offers:
if [ -r /sys/power/mem_sleep ]; then
    say "Firmware sleep states: $(cat /sys/power/mem_sleep)"
fi

# ------------------------------------------------------------------- backup
run mkdir -p "$BACKUP_DIR"
if [ "$DRY_RUN" -eq 0 ]; then
    grubby --info=ALL > "$BACKUP_DIR/grubby-info-before.txt" 2>/dev/null || true
    cp -a /proc/cmdline "$BACKUP_DIR/cmdline-before.txt" 2>/dev/null || true
fi
ADDED_ARGS_FILE="$STATE_DIR/added-args.txt"
INSTALLED_UNITS_FILE="$STATE_DIR/installed-units.txt"
DISABLED_STALE_FILE="$STATE_DIR/disabled-stale-units.txt"
run mkdir -p "$STATE_DIR"
run touch "$ADDED_ARGS_FILE" "$INSTALLED_UNITS_FILE" "$DISABLED_STALE_FILE"

# ------------------------------------------------------------- kernel args
# An arg counts as present if it is in the running kernel's cmdline or in
# any BLS entry grubby knows about. Only missing args are added, and only
# the ones WE add are recorded (uninstall removes exactly those).
PRESENT_ARGS="$(cat /proc/cmdline) $(grubby --info=ALL 2>/dev/null | grep '^args=' || true)"

add_args=""
for a in $ALL_ARGS; do
    key="${a%%=*}"
    # drop any older value of the same key we may have set previously
    if grep -qw "$a" <<<"$PRESENT_ARGS"; then
        say "Kernel arg already present: $a"
    else
        add_args="$add_args $a"
    fi
    # If a different mem_sleep_default is currently set, replace ours cleanly:
    if [ "$key" = "mem_sleep_default" ] && ! grep -qw "$a" <<<"$PRESENT_ARGS" \
       && grep -qw "mem_sleep_default" <<<"$PRESENT_ARGS"; then
        run grubby --update-kernel=ALL --remove-args="mem_sleep_default"
    fi
done

if [ -n "${add_args# }" ]; then
    say "Adding kernel args via grubby:$add_args"
    run grubby --update-kernel=ALL --args="${add_args# }"
    if [ "$DRY_RUN" -eq 0 ]; then
        for a in $add_args; do echo "$a" >> "$ADDED_ARGS_FILE"; done
    fi
else
    say "All kernel args already present — nothing to add."
fi

# ------------------------------------------------------ stale unit cleanup
# Units from the old deqrocks/T2Linux-Suspend-Fix script (repo deleted;
# units documented in community guides). On the t2bce stack they are
# actively harmful advice; on the legacy stack our units supersede them.
STALE_UNITS="suspend-wifi-unload.service resume-wifi-reload.service fix-kbd-backlight.service"
for u in $STALE_UNITS; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1 && [ -n "$(systemctl list-unit-files "$u" 2>/dev/null | grep "$u")" ]; then
        if systemctl is-enabled "$u" >/dev/null 2>&1; then
            say "Disabling stale suspend unit from the old fix script: $u"
            run systemctl disable --now "$u" || true
            [ "$DRY_RUN" -eq 0 ] && echo "$u" >> "$DISABLED_STALE_FILE"
        fi
    fi
done

# ----------------------------------------------------------------- services
install_unit() {
    local unit="$1"
    say "Installing $unit"
    run install -m 0644 "$SCRIPT_DIR/services/$unit" "/etc/systemd/system/$unit"
    run systemctl daemon-reload
    run systemctl enable "$unit"
    [ "$DRY_RUN" -eq 0 ] && echo "$unit" >> "$INSTALLED_UNITS_FILE"
}

if [ "$STACK" = "legacy" ]; then
    install_unit "suspend-fix-t2.service"
    install_unit "suspend-fix-wifi.service"
elif [ "$STACK" = "t2bce" ] && [ "$WITH_WIFI" -eq 1 ]; then
    install_unit "suspend-fix-wifi.service"
else
    say "No module-unload services installed (correct for the t2bce stack:"
    say "the wiki says t2bce handles suspend itself and must not be unloaded)."
    say "If Wi-Fi is dead after resume, re-run with --with-wifi-service."
fi

run systemctl daemon-reload

# -------------------------------------------------------------------- done
cat <<EOF

Done. Changes are recorded in $STATE_DIR (backup: $BACKUP_DIR).
Revert everything at any time with:  sudo ./uninstall.sh

NEXT STEPS
1. Reboot (kernel arguments only take effect after a reboot):
       sudo reboot
2. After reboot, confirm the sleep mode:
       cat /sys/power/mem_sleep        # expect [$SLEEP_MODE] selected
3. Run the verification checks:
       ./verify.sh
4. Test a real suspend, on AC power, with your work saved:
       systemctl suspend
   Wait until the fans stop, count to 20, then press a key / open the lid.
5. After resume, inspect the log of that sleep cycle:
       ./verify.sh --post
EOF
