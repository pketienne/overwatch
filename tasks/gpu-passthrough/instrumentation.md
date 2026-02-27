# Instrumentation

Inventory of all monitoring and diagnostics in the GPU passthrough stack,
organized by side (host/guest) and phase (startup/runtime/shutdown).

## Host-Side

### State Snapshots — Implemented

- **do_status()** (lines 88–144) — on-demand query: GPU/audio driver, VM
  state, services, CPU governor, IRQ balance, iGPU blank state. Derives
  overall state (host-ready, vm-running, transitioning). Run via
  `vm-overwatch status`.
- **log_state()** (lines 183–190) — checkpoint logging at transitions
  (post_unbind, vfio_bind_failed, post_vfio_unbind, vm_running, vm_shutdown,
  on_error). Logs GPU driver, audio driver, and VM domain state.

### CPU Isolation & Tuning — Implemented

- **ensure_performance_tuning()** (lines 354–371) — cgroup confinement
  (system.slice, user.slice, init.scope) to CPU 0, governor=performance on
  all cores, IRQ pinning to host CPU, writeback affinity. Runs once after VM
  enters running state.

### GPU Hardware — Implemented

- **gpu_bus_reset()** (lines 55–70) — PCIe Secondary Bus Reset via sysfs +
  vendor ID readiness poll (setpci, 100ms intervals, 2s timeout). Called at
  VFIO bind (clean guest handoff) and host rebind (post-VFIO).
- **gpu_driver()** (lines 43–51) — sysfs driver binding query
  (readlink on driver symlink). Called throughout lifecycle transitions and
  state snapshots.

### Shutdown Timing — Implemented

- **UDP shutdown signal** (lines 729–740) — Python listener on port 9147.
  Receives timestamp from Windows `notify-host-shutdown.ps1` (triggered by
  Event ID 1074 scheduled task). Writes timestamp to temp file for delta
  calculation.
- **QEMU process state tracking** (lines 747–764) — reads
  `/proc/<pid>/status` State field, logs transitions (S→D→exited). Only
  active after shutdown signal received to avoid noise.
- **Libvirt domain state polling** (lines 749–785) — `virsh domstate` every
  2s. Detects clean shutdown, orphaned QEMU (domain-not-found 3x), and
  calculates shutdown duration from signal to VM stop.

### Error Handling — Implemented

- **ERR trap** (lines 167–172) — traps ERR signal, logs failing line number,
  command text, and exit code. Calls `log_state("on_error")` for context.

### Runtime Performance Monitoring — Gap

No host-side metrics collected during VM runtime. When gameplay stuttering
occurs, there is no data to distinguish host-side contention from guest-side
issues.

| Metric | Tool | What it would diagnose |
|---|---|---|
| Per-core CPU utilization | `mpstat -P ALL` | Core 0 saturation, host interference on vCPU cores 1–7 |
| Disk I/O latency | `iostat -x` | qcow2 read/write latency, I/O wait |
| Memory pressure | `vmstat` | Swapping, page faults, free memory depletion |
| Kernel errors | `dmesg -w` | VFIO/IOMMU errors, PCIe AER during gameplay |

See [Action Item 8](action-items.md#8-host-side-runtime-performance-monitoring).

## Guest-Side

### Post-Boot Diagnostics — Implemented (log_guest_diagnostics, lines 380–509)

Runs via QEMU guest agent after VM boot. Non-blocking (background subshell).
Waits up to 60s for guest agent, then queries five data sources:

- **SHUTDOWN_DIAG** — Windows Event IDs 200–203 from
  Diagnostics-Performance log. Shows prior session shutdown duration, slow
  services, and slow drivers.
- **CRASH_DUMPS** — enumerates `C:\Windows\LiveKernelReports\*\*.dmp` and
  `C:\Windows\Minidump\*.dmp` (5 most recent). Shows TDR livedumps and
  BSODs with size and timestamp.
- **GPU_DRIVER** — AMD display adapter PnP status and driver version.
  Detects silent Windows Update driver changes.
- **HD_AUDIO** — GPU audio codec device status + driver store check for
  AtiHDAudioService. Warns if the audio driver has rebound (causes PnP
  Watchdog events).
- **DISPLAY_EVENTS** — 20 most recent events from Display, DxgKrnl, and Dwm
  providers. Shows mini-TDR recoveries (Event 4101), display config changes,
  and GPU stalls.

### Runtime Performance Monitoring — Gap

No GPU utilization, clock speed, temperature, or VRAM usage data during
gameplay. Can't determine if stuttering is thermal throttling, driver stalls,
or resource exhaustion.

| Metric | Tool | What it would diagnose |
|---|---|---|
| GPU clocks, temps, utilization, VRAM | PowerShell WMI, GPU-Z CLI, or HWiNFO | Thermal throttling, clock drops, VRAM exhaustion |
| Guest CPU usage | `Get-Counter` or Task Manager | CPU bottleneck inside VM |
| Frame time | Overwatch overlay (Ctrl+Shift+N) | Render stalls, network latency, frame pacing |

See [Action Item 9](action-items.md#9-guest-side-runtime-performance-monitoring).
