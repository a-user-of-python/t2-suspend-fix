#!/usr/bin/env bash
# t2-suspend-fix uninstaller — reverts everything install.sh changed.
#
#   * Removes exactly the kernel arguments install.sh recorded as added
#     (arguments that were already on the system are left alone).
#   * Disables and deletes the systemd units install.sh installed.
#   * Re-enables any stale units install.sh disabled (if recorded).
#   * Removes the state directory.
#
# If the state file is missing (e.g. it was deleted by hand), the script
# falls back to removing this package's known units and its full known
# argument set — but only arguments that are actually present.
#
# Usage: sudo ./uninstall.sh [--dry-run]

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

STATE_DIR="/var/lib/t2-suspend-fix"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

[ "$(id -u)" -eq 0 ] || die "Run this as root: sudo ./uninstall.sh"

# ------------------------------------------------------------- remove units
units=""
if [ -f "$STATE_DIR/installed-units.txt" ]; then
    units="$(cat "$STATE_DIR/installed-units.txt")"
else
    warn "No install state found — falling back to this package's known units."
    units="suspend-fix-t2.service suspend-fix-wifi.service"
fi

for u in $units; do
    [ -n "$u" ] || continue
    if [ -f "/etc/systemd/system/$u" ] || systemctl list-unit-files "$u" 2>/dev/null | grep -q "$u"; then
        say "Removing unit: $u"
        run systemctl disable --now "$u" || true
        run rm -f "/etc/systemd/system/$u"
    fi
done
run systemctl daemon-reload

# ------------------------------------------------- re-enable stale units
if [ -f "$STATE_DIR/disabled-stale-units.txt" ]; then
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        say "Re-enabling unit that install.sh had disabled: $u"
        run systemctl enable "$u" || true
    done < "$STATE_DIR/disabled-stale-units.txt"
fi

# ------------------------------------------------------------ kernel args
args=""
if [ -f "$STATE_DIR/added-args.txt" ]; then
    args="$(cat "$STATE_DIR/added-args.txt")"
else
    warn "No recorded kernel args — falling back to this package's known set."
    args="intel_iommu=on iommu=pt pm_async=off pcie_ports=compat pcie_aspm=off mem_sleep_default=deep mem_sleep_default=s2idle"
fi

# Only remove args that are actually present in the boot entries.
PRESENT_ARGS="$(grubby --info=ALL 2>/dev/null | grep '^args=' || true)"
remove_args=""
for a in $args; do
    [ -n "$a" ] || continue
    if grep -qw "$a" <<<"$PRESENT_ARGS"; then
        remove_args="$remove_args $a"
    fi
done

if [ -n "${remove_args# }" ]; then
    say "Removing kernel args via grubby:$remove_args"
    run grubby --update-kernel=ALL --remove-args="${remove_args# }"
else
    say "None of this package's kernel args are present — nothing to remove."
fi

# ------------------------------------------------------------------- state
run rm -rf "$STATE_DIR"

cat <<'EOF'

Uninstalled. Reboot to return the running kernel to the previous arguments:
    sudo reboot
EOF
