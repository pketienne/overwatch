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

## Result

Steps 1-5 implemented in a single pass. 967 → 898 lines (69 lines removed).
Remaining reset infrastructure (~50 lines) kept as safety nets for now.
