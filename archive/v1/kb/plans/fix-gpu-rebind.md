# Plan: Fix GPU Rebind After VFIO Passthrough

## Context

After VFIO passthrough (especially following a mid-gameplay GPU TDR), `amdgpu`'s `probe()` gets stuck in an SR-IOV VF mailbox loop when binding via `echo $GPU > .../amdgpu/bind`. The call blocks for ~4 minutes in kernel space, systemd's `TimeoutStopSec=120` fires SIGKILL, and the host is left half-restored: no GDM, GPU unbound, user locked out.

PCI remove+rescan was proven to recover: it gives `amdgpu` a completely fresh device, avoiding the stale SR-IOV state entirely.

## Changes to `overwatch.sh`

### 1. Add `gpu_pci_remove_rescan()` helper (after `gpu_bus_reset()`, ~line 71)

Removes both `$GPU` and `$GPU_AUDIO` from the PCI bus, sleeps 1s, rescans. Polls for `amdgpu` auto-bind for up to 15s (1s intervals). Drivers auto-bind via modalias since `driver_override` was already cleared by `ensure_gpu_unbound_from_vfio()`.

### 2. Add `gpu_bind_with_timeout()` helper (after `gpu_pci_remove_rescan()`)

Runs `echo $GPU > .../amdgpu/bind` in a background subshell (`( ... ) &`), polls `kill -0` at 1s intervals up to 30s. If the subshell hasn't exited, kills it and returns failure. This is the fallback path — only used if PCI remove+rescan didn't auto-bind.

### 3. Add `disable_gpu_runtime_pm()` helper (before `ensure_gpu_on_host()`)

Extracted from current inline code. Disables runtime PM on GPU and audio, binds audio to `snd_hda_intel` if not already bound. Called after any successful bind method.

### 4. Rewrite `ensure_gpu_on_host()` (lines 707-756)

Two-tier strategy:
1. **Primary**: `gpu_pci_remove_rescan()` — avoids the blocking bind call entirely
2. **Fallback**: `gpu_bus_reset()` + `gpu_bind_with_timeout(30)` — if rescan didn't auto-bind
3. Both failed → return 1 (non-fatal, host runs on iGPU)

Each tier checks `gpu_driver "$GPU"` after completion. First success calls `disable_gpu_runtime_pm()` and returns.

### 5. Reorder `_do_stop()` (lines 788-799)

```
ensure_vm_stopped
ensure_cpu_defaults
ensure_gpu_unbound_from_vfio
set_igpu_blank 0 unblank          ← moved before GPU rebind
ensure_services_running            ← moved before GPU rebind (GDM starts on iGPU)
ensure_gpu_on_host || log WARNING  ← now last (user already has desktop)
```

This guarantees the user gets their desktop back even if GPU rebind hangs or fails.

## Files Modified

- `scripts/overwatch.sh` — new helpers, rewritten `ensure_gpu_on_host()`, reordered `_do_stop()`

## Edge Cases

- **`driver_override` cleared before rescan**: Already handled — `ensure_gpu_unbound_from_vfio()` clears it, and PCI remove+recreate also resets it to empty
- **Killing bind subshell doesn't stop kernel probe**: Acceptable — D-state lingers but script continues; the SR-IOV loop self-terminates after ~4 min
- **Rescan enumerates entire PCI bus**: Safe — existing bound devices are not disturbed
- **GDM starts before dGPU appears**: Fine — GNOME handles multi-GPU; `monitors.xml` copy ensures correct config
- **Audio function missing after rescan**: `disable_gpu_runtime_pm()` checks existence before touching it

## Verification

1. `bash -n scripts/overwatch.sh` — syntax check
2. Start VM normally, play for a bit, stop VM — verify clean restore with PCI rescan path
3. Simulate hung probe: if testing shows the SBR+bind fallback is reached, verify the 30s timeout fires and doesn't leave the script stuck
4. Verify GDM comes up on iGPU before GPU rebind completes (check timestamps in journal)
