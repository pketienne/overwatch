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

- **ensure_performance_tuning()** (lines 366–383) — cgroup confinement
  (system.slice, user.slice, init.scope) to CPUs 0–1, governor=performance
  on all cores, IRQ pinning to host CPUs, writeback affinity. Expanded from
  single core after PERF_HOST monitoring revealed cpu0 saturation causing
  USB audio drops. Runs once after VM enters running state.

### GPU Hardware — Implemented

- **Framebuffer suspend** (lines 268–275) — sets dGPU framebuffer state to
  `FBINFO_STATE_SUSPENDED` via sysfs before amdgpu unbind. Prevents
  `drm_fb_helper_fini` deadlock where `cancel_work_sync(&damage_work)` waits
  forever on a blit to dying hardware (~1.5% hit rate without this). Finds
  framebuffer by PCI device path. Runs in `ensure_gpu_unbound_from_host()`.
- **gpu_bus_reset()** (lines 55–70) — PCIe Secondary Bus Reset via sysfs +
  vendor ID readiness poll (setpci, 100ms intervals, 2s timeout). Called at
  VFIO bind (clean guest handoff) and host rebind (post-VFIO).
- **gpu_driver()** (lines 43–51) — sysfs driver binding query
  (readlink on driver symlink). Called throughout lifecycle transitions and
  state snapshots.

### Shutdown Timing — Implemented

- **UDP shutdown signal** (lines 741–752) — Python listener on port 9147.
  Receives timestamp from Windows `notify-host-shutdown.ps1` (triggered by
  Event ID 1074 scheduled task). Writes timestamp to temp file for delta
  calculation.
- **QEMU process state tracking** (lines 759–776) — reads
  `/proc/<pid>/status` State field, logs transitions (S→D→exited). Only
  active after shutdown signal received to avoid noise.
- **Libvirt domain state polling** (lines 761–797) — `virsh domstate` every
  2s. Detects clean shutdown, orphaned QEMU (domain-not-found 3x), and
  calculates shutdown duration from signal to VM stop.

### Error Handling — Implemented

- **ERR trap** (lines 167–172) — traps ERR signal, logs failing line number,
  command text, and exit code. Calls `log_state("on_error")` for context.

### Runtime Performance Monitoring — Implemented (monitor_host_perf, lines 526–552)

Background subshell samples every 30s while VM is running. Tagged `PERF_HOST`
for `journalctl -u vm-overwatch | grep PERF_HOST`. Launched in `_do_start()`,
killed on shutdown alongside other background jobs.

| Metric | Tool | What it diagnoses |
|---|---|---|
| Per-core CPU utilization | `mpstat -P ALL` (cores >50% only) | Core 0 saturation, host interference on vCPU cores 1–7 |
| Disk I/O latency | `iostat -x` (nvme1n1) | qcow2 read/write await, utilization |
| Memory pressure | `/proc/meminfo` | Free/available memory, swap usage |

See [Action Item 8](action-items.md#8-host-side-runtime-performance-monitoring).

## Guest-Side

### Post-Boot Diagnostics — Implemented (log_guest_diagnostics, lines 392–521)

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

### Runtime Performance Monitoring — Implemented (monitor_guest_perf, lines 557–626)

Background subshell samples every 60s via QEMU guest agent (`qga`/`run_ps`
pattern, same as `log_guest_diagnostics`). Tagged `PERF_GUEST` for
`journalctl -u vm-overwatch | grep PERF_GUEST`. Launched in `_do_start()`,
killed on shutdown.

| Metric | Tool | What it diagnoses |
|---|---|---|
| GPU 3D engine utilization | `Get-Counter` GPU Engine perf counters | GPU load during gameplay |
| GPU temperature, clock speed | AMD WMI (`AMD_ACPI`) with graceful fallback | Thermal throttling, clock drops |
| Video controller status, VRAM | `Win32_VideoController` | Driver status, VRAM availability |

Frame time and render stalls are not capturable via guest agent — use
Overwatch's built-in overlay (Ctrl+Shift+N) for those.

See [Action Item 9](action-items.md#9-guest-side-runtime-performance-monitoring).
