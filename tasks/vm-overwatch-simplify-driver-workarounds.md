# vm-overwatch: Simplify by removing driver-workaround code

## Context

Windows Update pushed AMD display driver 31.0.14000.58004 on Feb 21, causing
DRIVER_POWER_STATE_FAILURE (0x9F) BSODs every 2-5 minutes. This corrupted GPU
state after VM shutdown, which motivated building extensive reset infrastructure
(MODE1 → PCI bus reset → suspend/resume fallback chain), health checks, and
degraded-mode paths. After removing the broken driver and blocking WU from
reinstalling it, three consecutive VM cycles showed: GPU always healthy, zero
resets needed, clean amdgpu rebind every time.

Goal: Remove the ~350 lines of driver-workaround code while keeping the
genuinely needed VFIO passthrough functionality. Done incrementally — one
removal per deploy+test cycle.

## File to modify

`/home/myuser/kb/navi31-reset/vm-overwatch` (deployed to `myhost:/usr/local/bin/vm-overwatch`)

## Step 1: Remove suspend/resume and PCI bus reset fallbacks [DONE]

Removed `try_pci_reset()` and `try_suspend_resume()` entirely. Simplified
`gpu_reset()` to only attempt MODE1. If MODE1 fails, log an error and return 1
(no fallback). Kept `try_mode1()` and `gpu_healthy()` as safety nets.

**Removed** (~40 lines):
- `try_pci_reset()` function
- `try_suspend_resume()` function
- Fallback steps 2 and 3 in `gpu_reset()`

**Deploy and test**: one VM start/stop cycle.

## Step 2: Remove pre-VM GPU reset [DONE]

Removed `ensure_gpu_reset()` call from `_do_start()`. With a healthy
driver, the GPU is always healthy after unbinding from amdgpu.

Kept `ensure_gpu_reset()` in `_do_stop()` path as a safety check (it already
skips if healthy).

**Deploy and test**: one VM start/stop cycle.

## Step 3: Make reset module optional at startup [DONE]

`ensure_reset_module()` was called at the top of `_do_start()` and aborted if
the module couldn't be loaded. Since we no longer reset pre-VM, it's no longer
a hard requirement for starting. Changed to optional — load if available, warn
if not, don't abort.

**Deploy and test**: one VM start/stop cycle.

## Step 4: Remove unresponsive-GPU guard from unbind [DONE]

Removed the `if ! gpu_healthy` branch in `ensure_gpu_unbound_from_host()`
that did PCI remove + rescan instead of normal unbind. With a healthy driver,
this path should never trigger. Kept only the normal unbind path.

**Deploy and test**: one VM start/stop cycle.

## Step 5: Remove degraded-mode path from host restore [DONE]

Removed the `if [ -e "$RESET_DEV" ] && ! gpu_healthy` branch in
`ensure_gpu_on_host()` that skipped amdgpu bind and fell back to iGPU-only
mode. With a healthy driver, this should never trigger.

**Deploy and test**: one VM start/stop cycle.

## Step 6: Evaluate remaining reset code

After steps 1-5, assess what's left:
- `gpu_healthy()` — lightweight register check, ~5 lines. Keep as diagnostic.
- `try_mode1()` — only used in post-VM `ensure_gpu_reset()`. Keep for now,
  evaluate removal after more cycles without it ever firing.
- `ensure_runtime_pm_disabled()` — 2 lines. Low cost, keep for safety.
- Audio D3cold workaround (PCI remove+rescan) — still fires every cycle.
  Test removing it separately in a later session.

## Verification

After each step:
1. Deploy to myhost: `scp vm-overwatch myhost:/tmp/ && ssh myhost "sudo cp /tmp/vm-overwatch /usr/local/bin/vm-overwatch"`
2. Start VM: `ssh myhost "sudo systemd-run --unit=vm-overwatch --collect '--description=Overwatch VM lifecycle' /usr/local/bin/vm-overwatch start"`
3. Shut down VM from Windows
4. Verify in journal: `ssh myhost "sudo journalctl -u vm-overwatch --since '2 minutes ago' --no-pager"` — confirm `outcome=success`, `was_reset=no`, `Host restored`
5. Verify host desktop is back

## Step 7: Trim USB diagnostic logging [DONE]

Replaced 120-line `ensure_usb_reattached()` (full lsusb snapshots, USB_DIAG
per-line logging, 30s polling with bus rescan fallback, structured YAML record)
with 20-line core: detach, sleep, attach with one retry.

First deploy revealed Tartarus V2 failing to attach — the old polling/retry
logic was masking a re-enumeration delay. Added a single 3s retry which fixed it.

## Step 8: Fix orphaned VM detection [DONE]

libvirtd lost track of the domain mid-session (QEMU running but `virsh list
--all` empty). The poll loop treated virsh errors as "keep waiting", causing
vm-overwatch to spin forever. Fixed: detect "failed to get domain" 3 consecutive
times, kill orphaned QEMU, and proceed to host restore.

## Step 9: Remove dead code [DONE]

Removed unused `VM_CPUS` variable.

## Testing notes (2026-02-24)

Commits: `19dd65e` (steps 1-5), `27857f1` (steps 7-9)

- **First deploy (steps 1-5)**: Host crashed before vm-overwatch started.
  Root cause: amdgpu runtime PM resume failure during normal desktop use
  (`device lost from bus`, soft lockup on CPU#5/#6). Unrelated to our changes —
  crash started at 03:43, our deploy was at 03:44. GPU had died ~6 min after
  a successful VM cycle restored the host.

- **Second deploy (steps 1-5)**: Clean cycle. `outcome=success`, `was_reset=no`.
  GPU healthy after vfio unbind, clean amdgpu rebind.

- **Third deploy (steps 7-9, first attempt)**: Tartarus V2 failed to attach
  (no retry). libvirtd lost domain — vm-overwatch stuck in poll loop. Had to
  manually kill QEMU and run `vm-overwatch stop`. Host restored cleanly.

- **Fourth deploy (steps 7-9, with fixes)**: Clean cycle. Both USB devices
  attached (Tartarus got it first try this time). `outcome=success`,
  `shutdown=clean_acpi`, `was_reset=no`.

Two unrelated GPU crashes during the session (both during normal desktop use
between VM cycles) required hard reboots. These are caused by amdgpu runtime
PM resuming the GPU from D3 and finding it unresponsive — a separate issue
from the driver workarounds we removed.

## Result

967 → 808 lines across both commits (-159 lines, ~16% reduction).

Remaining code kept as safety nets:
- `gpu_healthy()` — lightweight register check, used by `do_status` and post-VM reset
- `try_mode1()` / `gpu_reset()` / `ensure_gpu_reset()` — post-VM safety net in
  `_do_stop()`, always skips (GPU healthy), never fires
- `ensure_runtime_pm_disabled()` — 2 lines, cheap insurance (the GPU crashes
  during this session proved exactly why runtime PM is dangerous)
- Audio D3cold workaround (PCI remove+rescan) — still fires every cycle, adds
  ~3s. Test removing separately.

## Open issue: GPU crashes during desktop use [FIXED]

The amdgpu driver's runtime PM was killing the GPU between VM cycles. Seen twice
this session: GPU enters D3, runtime PM resume finds device unresponsive
(`0xffffffff` registers), `device lost from bus`, soft lockup. This is NOT
related to VFIO passthrough — it happens during normal GDM desktop operation.
`ensure_runtime_pm_disabled()` only protects during the vm-overwatch startup
window.

**Fix**: Added udev rules to `myhost:/etc/udev/rules.d/99-gpu-passthrough.rules`
to permanently disable runtime PM for both GPU functions (video + audio):
```
ACTION=="add", KERNEL=="0000:03:00.0", SUBSYSTEM=="pci", ATTR{power/control}="on"
ACTION=="add", KERNEL=="0000:03:00.1", SUBSYSTEM=="pci", ATTR{power/control}="on"
```
This forces the GPU to stay in D0 (fully powered) at all times. Tradeoff is
~10-20W higher idle power, but the GPU never enters the D3 state that crashes it.
Applied manually for current session; udev rule takes effect automatically on boot.
