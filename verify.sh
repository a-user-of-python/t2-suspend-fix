#!/usr/bin/env bash
# t2-suspend-fix verification helper (read-only — changes nothing).
#
#   ./verify.sh          Pre-flight checks: model, driver stack, sleep
#                        states, kernel arguments, installed units.
#   ./verify.sh --post   Post-resume analysis: pulls the most recent
#                        suspend cycle out of the journal and greps it for
#                        the known T2 failure signatures.
#
# "No errors found" is evidence, not proof — the real test is a suspend
# that sleeps quietly and a resume that brings everything back.

set -uo pipefail

MODE="pre"
[ "${1:-}" = "--post" ] && MODE="post"

hr() { printf '%s\n' "------------------------------------------------------------"; }
kv() { printf '%-28s %s\n' "$1:" "$2"; }

MODEL="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)"

if [ "$MODE" = "pre" ]; then
    hr; echo "T2 suspend fix — pre-flight checks"; hr
    kv "Model (DMI)" "$MODEL"
    [ "$MODEL" = "MacBookPro16,1" ] || echo "  NOTE: this package targets MacBookPro16,1."
    kv "Kernel" "$(uname -r)"

    if lsmod | grep -q '^t2bce'; then
        kv "T2 stack" "t2bce (current)"
    elif lsmod | grep -q '^apple_bce'; then
        kv "T2 stack" "apple_bce (legacy)"
    else
        kv "T2 stack" "NONE DETECTED — check: lsmod | grep -E 't2bce|apple_bce'"
    fi

    kv "Sleep states offered" "$(cat /sys/power/state 2>/dev/null)"
    kv "mem_sleep (selected)" "$(cat /sys/power/mem_sleep 2>/dev/null)"

    hr; echo "Kernel arguments (running kernel, /proc/cmdline):"
    for a in intel_iommu=on iommu=pt pm_async=off pcie_ports=compat pcie_aspm=off mem_sleep_default; do
        if grep -qw "$a" /proc/cmdline || grep -qw "${a}=" /proc/cmdline; then
            echo "  present: $(tr ' ' '\n' < /proc/cmdline | grep "^$a" | head -1)"
        else
            echo "  MISSING: $a  (rebooted since installing? install.sh adds these via grubby)"
        fi
    done

    hr; echo "Units:"
    for u in suspend-fix-t2.service suspend-fix-wifi.service; do
        if systemctl list-unit-files "$u" 2>/dev/null | grep -q "$u"; then
            kv "$u" "$(systemctl is-enabled "$u" 2>/dev/null || echo present)"
        else
            kv "$u" "not installed"
        fi
    done
    for u in suspend-wifi-unload.service resume-wifi-reload.service fix-kbd-backlight.service; do
        if systemctl list-unit-files "$u" 2>/dev/null | grep -q "$u"; then
            kv "$u (stale)" "$(systemctl is-enabled "$u" 2>/dev/null || echo present) — old fix-script unit"
        fi
    done

    hr
    cat <<'EOF'
Manual test protocol:
  1. Save your work, stay on AC power.
  2. Run:  systemctl suspend
  3. Success going down: screen off, fans stop, machine stays asleep
     (no instant wake, no fans cycling) for at least a few minutes.
  4. Wake it (key press / lid). Success coming back: display, keyboard,
     trackpad, Touch Bar, Wi-Fi and sound all return without a reboot.
  5. Then run:  ./verify.sh --post
EOF
    exit 0
fi

# ----------------------------------------------------------------- --post
hr; echo "T2 suspend fix — last suspend cycle analysis"; hr

# systemd-suspend service journal for the current boot, last cycle:
LOG="$(journalctl -b 0 -u systemd-suspend.service --no-pager -o cat 2>/dev/null | tail -n 40)"
if [ -n "$LOG" ]; then
    echo "systemd-suspend.service (tail):"
    echo "$LOG" | sed 's/^/  /'
else
    echo "No systemd-suspend.service journal entries this boot."
    echo "Either no suspend has happened since boot, or journal is volatile."
fi

hr; echo "Kernel PM lines (this boot, last 25):"
journalctl -b 0 -k --no-pager -o cat 2>/dev/null \
    | grep -E "PM: suspend (entry|exit)|PM: suspend devices|Restarting tasks|Freezing user space" \
    | tail -n 25 | sed 's/^/  /'

hr; echo "Known T2 failure signatures in this boot's kernel log:"
FOUND=0
for pat in "bce_vhci_drop_endpoint" "apple_bce.*BUG" "brcmfmac.*timed out" \
           "brcmfmac.*D3" "amdgpu.*resume.*fail" "amdgpu.*ERROR" \
           "psp_resume.*ERROR" "Unable to change power state"; do
    HITS="$(journalctl -b 0 -k --no-pager -o cat 2>/dev/null | grep -iE "$pat" | head -n 3)"
    if [ -n "$HITS" ]; then
        FOUND=1
        echo "  PATTERN: $pat"
        echo "$HITS" | sed 's/^/    /'
    fi
done
[ "$FOUND" -eq 0 ] && echo "  None found. (Good sign — not a guarantee.)"

hr
cat <<'EOF'
How to read this:
  * "PM: suspend entry" followed later by "PM: suspend exit" = a full cycle.
  * No "suspend entry" at all = the machine never actually slept
    (check for instant-wake: something woke it immediately).
  * Errors between entry and exit name the subsystem that failed.
  * Full log if you need it:  journalctl -b 0 -k | less
EOF
