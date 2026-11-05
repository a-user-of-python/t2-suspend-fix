# T2 Suspend Fix — Fedora on MacBook Pro 2019 16″ (MacBookPro16,1)

Suspend/resume fix for **Fedora** running on a T2 MacBook Pro 16″ (2019,
MacBookPro16,1) via the t2linux kernel. This guide assumes **you are
already booted into Fedora** — everything below runs in Fedora's
Terminal, on the machine itself.

> **Honesty note:** this package was researched from the t2linux wiki,
> the KAIT2EN Fedora project, and kernel mailing-list posts. It has
> **not been run on the target MacBook yet** — follow the test steps,
> and keep the uninstaller handy. Everything is reversible; nothing
> here touches the kernel, initramfs, or bootloader in a way that can
> make the machine unbootable.

---

## Get it

```bash
git clone https://github.com/a-user-of-python/t2-suspend-fix.git
cd t2-suspend-fix
```

No git? `sudo dnf install -y git` first. (Or download the repo ZIP
from the GitHub page and unzip it — then run `chmod +x *.sh` once,
because ZIPs don't keep the executable bit.)

## Run it — in this order

### 1. Be on the current T2 kernel first

No config fix substitutes for a current kernel:

```bash
sudo dnf copr enable sharpenedblade/t2linux   # fine if already enabled
sudo dnf upgrade --refresh
```

Reboot if that installed a new kernel. Then note your "before" state:

```bash
lsmod | grep -E 't2bce|apple_bce'   # which driver stack you run
cat /sys/power/mem_sleep           # which sleep states exist
```

### 2. Dry run — see every change before it happens

```bash
sudo ./install.sh --dry-run
```

The installer prints exactly what it would do and changes nothing.

### 3. Install

```bash
sudo ./install.sh
```

Defaults are what you want: deep sleep, driver stack auto-detected.
The installer refuses to run on a non-Fedora system or another model,
adds only the kernel arguments you're missing (via `grubby`, the
Fedora way — recorded for removal), cleans up stale services left by
the old deleted fix script, and installs sleep services **only** on
the legacy apple-bce stack. On the modern t2bce stack it installs no
services on purpose: current t2linux guidance is that t2bce handles
suspend internally and the old module-unload tricks are now harmful.

### 4. Reboot

### 5. Test it properly

```bash
cat /sys/power/mem_sleep    # expect: s2idle [deep]  — brackets = active
./verify.sh                 # pre-flight checks
```

Save your work, keep the charger plugged in:

```bash
systemctl suspend
```

**Pass:** screen off, fans stop, and it *stays* asleep several
minutes. Wake with a key press, then check display, keyboard,
trackpad, Touch Bar, Wi-Fi, and audio. Then:

```bash
./verify.sh --post
```

**Pass:** a "PM: suspend entry" → "PM: suspend exit" pair and no hits
under the known T2 failure signatures. Repeat the suspend/wake cycle
**three times**, then once more on battery. One lucky sleep proves
nothing; three in a row is the fix working.

## If it fails — the ladder, in order

1. **Wakes instantly** — unplug Thunderbolt/USB devices and retest;
   docks are the usual suspect.
2. **Sleeps but wakes wrong (black screen / dead)** — try the other
   sleep state:
   ```bash
   sudo ./uninstall.sh
   sudo ./install.sh --sleep=s2idle
   ```
   Reboot, retest.
3. **Wakes but Wi-Fi is dead** —
   `sudo ./install.sh --with-wifi-service`, reboot, retest.
4. **Legacy stack, keyboard/trackpad dead after wake** — check
   `systemctl status suspend-fix-t2.service`.
5. **Nothing works** — make the machine dependable while you decide:
   ```bash
   sudo ./lid-lock-fallback.sh on    # lid = lock screen, no suspend
   sudo ./lid-lock-fallback.sh off   # reverses it
   ```

## Undo everything

```bash
sudo ./uninstall.sh        # add --dry-run to preview
```

Removes exactly the kernel args the installer recorded adding,
removes its services, restores anything it disabled, and deletes its
state folder (`/var/lib/t2-suspend-fix`). Reboot after.

## The other route (only macOS step anywhere)

If this package doesn't get your machine sleeping, the known-working
road for this exact model is **KAIT2EN Fedora** — a Fedora build by the
author of the original T2 suspend fix, listing working suspend/resume
and dGPU power management on MacBookPro16,1 since Sep 2026. It's a
reinstall, not a patch: boot macOS, plug in an empty USB stick, and run
their installer from https://kait2en.org/.

## Why suspend breaks here (short version)

- Mac firmware from the Sonoma era (v13.5+, late 2023) broke suspend
  across T2 machines; it can't be downgraded, so current drivers route
  around it. Being current matters more than any tweak.
- The old bridge driver (apple-bce) could crash on resume. Current
  kernels replaced it with **t2bce**, which handles suspend internally
  — and must **not** be module-unloaded before sleep.
- Wi-Fi could die after resume (Broadcom D3 acknowledgement bug); the
  in-driver fix was accepted upstream Sep 2026.
- The Radeon Pro 5300M/5500M can't power-manage through Apple's gmux
  switcher on plain kernels — the fix is written and tested on this
  model but not yet in stable kernels; KAIT2EN ships it today.
- No SSD/NVMe wake bug specific to this model exists in any source
  checked — this package doesn't invent one.

## What's in the repo

| File | What it does |
|---|---|
| `install.sh` | Guarded installer (Fedora + model check, `--dry-run`), grubby kernel args, stack-aware services, stale-unit cleanup. State in `/var/lib/t2-suspend-fix/`. |
| `uninstall.sh` | Reverts exactly what the installer recorded. |
| `verify.sh` | Read-only pre-flight + `--post` journal scan for known T2 failure signatures. |
| `services/suspend-fix-t2.service` | Legacy apple-bce stack only: unload before suspend, reload (with 3 s delay) after resume. |
| `services/suspend-fix-wifi.service` | Only with `--with-wifi-service`: brcmfmac unload/reload around suspend. |
| `lid-lock-fallback.sh` | Last resort: lid locks instead of suspending. Not a fix; keeps the machine dependable. |

## Sources

- t2linux wiki — post-install (t2bce suspend position, standard kernel
  parameters, "remove old hooks"): https://wiki.t2linux.org/guides/postinstall/
- t2linux wiki — state of features (Sonoma firmware broke suspend;
  `amdgpu.dpm=0` stopgap): https://kevin-david.github.io/t2linux-wiki/state/
- t2linux wiki — Fedora install (COPR `sharpenedblade/t2linux`):
  https://wiki.t2linux.org/distributions/fedora/installation/
- KAIT2EN Fedora (16,1 suspend/resume + dGPU PM working, Sep 2026):
  https://kait2en.org/
- amdgpu GMUX runtime-PM patch series (tested 15,1/16,1/16,4, Oct 2026):
  https://lists.openwall.net/linux-kernel/2026/10/25/213
- Upstream brcmfmac suspend fix (Sep 2026):
  https://lore.kernel.org/linux-wireless/20260915-brcmfmac-bcm43752-suspend-fix-v2-1-1bd84914998b@collabora.com/
- Setup guide tested on MacBookPro16,1 (deep-sleep kernel args):
  https://github.com/iiimaroiii/dotfiles/blob/HEAD/cheat.sheet/T2-MacBook-Ubuntu-Setup-Guide.md
- Fedora-family T2 docs (firmware ≥ v13.5; s2idle recommendation):
  https://docs.projectbluefin.io/t2-mac/
