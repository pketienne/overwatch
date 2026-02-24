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

## Step 10: Fix runtime PM race during host restore [DONE]

The udev rules from the initial runtime PM fix were insufficient — both
`amdgpu` (via `runpm=-1` auto) and `snd_hda_intel` (via `power_save=1`)
override `power/control` back to `auto` during driver probe, defeating
`ACTION=="add"` rules.

Fifth VM cycle crashed during host restore: audio device entered D3hot
immediately after `snd_hda_intel` probed it, then failed to resume
(`Unable to change power state from D3hot to D0`), cascading into
`device lost from bus` and a soft lockup.

**Fixed** (two changes):
1. `myhost:/etc/modprobe.d/amdgpu.conf`: `options amdgpu runpm=0` —
   prevents amdgpu from ever enabling runtime PM at the driver level
2. vm-overwatch `ensure_gpu_on_host()`: disable runtime PM on GPU
   immediately after amdgpu bind, and on audio immediately after PCI
   rescan, before `snd_hda_intel` has time to put the device to D3hot

**Deploy and test**: clean cycle, `outcome=success`, no crash.

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

- **Fifth deploy (libvirtd fix test)**: vm-overwatch died mid-session (the
  `exec > >(tee ...)` process tracking issue — systemd tracks tee PID, not
  bash). Host restore on next cycle crashed — audio device entered D3hot
  during host restore and failed to resume. Required hard reboot.

- **Sixth deploy (step 10, runtime PM race fix)**: Clean cycle.
  `outcome=success`, `shutdown=clean_acpi`, `was_reset=no`. Both devices
  show `power/control=on` after restore. No crash.

## Round 2: Remove remaining dead code and over-engineering [DONE]

Three consecutive clean VM cycles confirmed the system is stable after round 1.
Removed the remaining safety-net code that never fires (2026-02-24):

1. **Reset chain** (~100 lines): `gpu_healthy`, `try_mode1`, `gpu_reset`,
   `ensure_gpu_reset`, `ensure_reset_module`, `RESET_DEV`/`RESET_MODULE`
   constants — never fires; if the GPU becomes unhealthy, amdgpu bind failure
   is already logged and the reset module can be invoked manually
2. **Bind history logging** (~45 lines): `log_bind_result`, `BIND_LOG`,
   `VM_START_TIME`, `VM_SHUTDOWN_METHOD` — diagnostic TSV from the
   broken-driver era; same info is in journald
3. **Pre-unbind `ensure_runtime_pm_disabled`** (~5 lines): redundant with
   `modprobe.d runpm=0` and the post-rebind disable in `ensure_gpu_on_host`
4. **5 redundant `log_state` checkpoints** (~10 lines): duplicated adjacent
   log messages. Kept: `on_error`, `post_unbind`, `vfio_bind_failed`,
   `post_vfio_unbind`, `vm_running`, `vm_shutdown`
5. **Per-run log files and `exec > >(tee ...)`** (~6 lines): removed the tee
   PID tracking bug and the per-run log files — journald already captures
   everything
6. **i2c double-kill pattern** (~8 lines): OpenRGB is already stopped before
   `fuser -k` runs; single pass is sufficient
7. **`gpu_health` dimension and "degraded" state from `do_status`** (~10 lines):
   follows from removing the reset infrastructure

808 → 629 lines (-179 lines, ~22% reduction). Verified with one clean VM
start/stop cycle — no errors, host restored successfully.

## Round 3: Remove diagnostics, iGPU blanking, and PID pinning [DONE]

Removed remaining code from the broken-driver era and unnecessary overhead
(2026-02-24):

1. **Pre-bind diagnostic snapshot** (~7 lines): `power_state`, `link_speed`,
   `d3cold_allowed` reads in `ensure_gpu_on_host` — only useful for diagnosing
   bind failures which no longer occur; amdgpu bind errors are sufficient
2. **`driver_override` from `log_state` and `do_status`** (~8 lines): always
   shows `(null)/(null)` in steady state; actual bind functions already log
   results
3. **iGPU blank/unblank** (~35 lines): `igpu_fb`, `ensure_igpu_blanked`,
   `ensure_igpu_unblanked`, `IGPU` constant, `iGPU:` status line, and
   callsites — monitor should auto-switch to DisplayPort when dGPU becomes
   active. **Needs testing** — revert if monitor doesn't switch.
4. **PID affinity loops** (~25 lines): removed `for pid` loops from both
   `ensure_performance_tuning` and `ensure_cpu_defaults`, plus the early-exit
   governor+irqbalance check. libvirt `<cputune>` already pins vCPU threads;
   IRQ affinity pinning is the meaningful part. PID iteration added ~1s
   startup time for negligible benefit.

629 → 538 lines (-91 lines, ~14% reduction). Needs deploy+test to verify
steps 3 and 4.

## Result

967 → 538 lines across all commits (-429 lines, ~44% reduction).

Remaining code is all actively used on every VM cycle:
- Audio D3cold workaround (PCI remove+rescan) — still fires every cycle, adds
  ~3s. Could test removing separately but low priority.

## Open issue: GPU crashes during desktop use [FIXED]

The amdgpu driver's runtime PM was killing the GPU between VM cycles. Seen twice
this session: GPU enters D3, runtime PM resume finds device unresponsive
(`0xffffffff` registers), `device lost from bus`, soft lockup. This is NOT
related to VFIO passthrough — it happens during normal GDM desktop operation.
`ensure_runtime_pm_disabled()` only protects during the vm-overwatch startup
window.

**Initial fix (udev rules only)**: Added rules to
`myhost:/etc/udev/rules.d/99-gpu-passthrough.rules`:
```
ACTION=="add", KERNEL=="0000:03:00.0", SUBSYSTEM=="pci", ATTR{power/control}="on"
ACTION=="add", KERNEL=="0000:03:00.1", SUBSYSTEM=="pci", ATTR{power/control}="on"
```
Host survived 9 hours idle — but a later VM cycle crashed during host restore
because both `amdgpu` and `snd_hda_intel` override `power/control` back to
`auto` during driver probe, defeating the udev rules.

**Root cause**: Udev `ACTION=="add"` fires before driver probe. Both drivers
re-enable runtime PM during probe, overriding the rules. The audio device
(`03:00.1`) entered D3hot within seconds of `snd_hda_intel` probing, and
the subsequent D3hot→D0 resume failed, crashing the GPU.

**Complete fix (step 10)**:
1. `myhost:/etc/modprobe.d/amdgpu.conf` — `options amdgpu runpm=0` tells
   the driver to never enable runtime PM (previously `runpm=-1` = auto).
2. vm-overwatch: disable runtime PM on each device immediately after it
   appears — GPU right after `amdgpu bind`, audio right after PCI rescan —
   closing the race window before `snd_hda_intel` puts the audio into D3hot.

**Verified**: Clean VM cycle with host restore, no crash. Both devices show
`power/control=on` after restore.
