# Instrumentation Inventory

---

## V2 (current: `scripts/overwatch.sh`)

### State & Lifecycle

| Component | What it measures | When | Tag |
|---|---|---|---|
| `log_state(checkpoint)` | GPU driver, audio driver, VM domain state at named transition | post_unbind, vfio_bind_failed, vm_running, vm_shutdown, on_error | `STATE` |
| ERR trap | Failing line number, command text, exit code | Any command failure | `ERROR` |
| `--verbose` flag | Full bash trace (`set -x`) with source/line | Entire run | stderr |
| `do_status()` | GPU/audio driver, VM state, iGPU blank, services, CPU governor, irqbalance | On-demand (`overwatch status`) | stdout |

### GPU Hardware

| Component | What it measures | When | Tag |
|---|---|---|---|
| `gpu_bus_reset()` | PCIe SBR completion time, vendor ID readiness poll | After VFIO bind and host rebind | stdout |
| `gpu_pci_remove_rescan()` | PCI remove + rescan time to amdgpu auto-bind (1s poll, 15s timeout) | Primary host rebind method | stdout |
| `gpu_bind_with_timeout()` | amdgpu bind completion time, timeout detection | Fallback bind method | stdout |

### Boot & Startup

| Component | What it measures | When | Tag |
|---|---|---|---|
| `attach_tartarus_deferred()` | Guest agent first-ping time, razerwdl (Synapse) ready time, Tartarus attach time — all from VM start | Background in `_do_start()` | `BOOT_TIMING` |

Log format:
- `BOOT_TIMING guest_agent=Ns` — seconds from VM start to first guest-ping response
- `BOOT_TIMING synapse_ready=Ns` — seconds from VM start to razerwdl process running
- `BOOT_TIMING tartarus=Ns` — seconds from VM start to Tartarus hot-plugged

```bash
journalctl -u overwatch | grep BOOT_TIMING
```

### Runtime Network (2s poll, background)

| Component | What it measures | When | Tag |
|---|---|---|---|
| `monitor_network()` | vnet RX/TX drop deltas on VM's tap interface | Continuous during VM runtime | `NET_HOST` |

Log format:
- `NET_HOST ok` — 30s heartbeat with absolute counts and current traffic state
- `NET_HOST DROPS` — rx or tx drop counter increased; packets lost in host network path
- `NET_HOST TRAFFIC_ACTIVE` — rx rate crossed above 50 pkt/2s; game connection established
- `NET_HOST TRAFFIC_IDLE` — rx rate stayed below 15 pkt/2s for 6s after being active; connection likely dropped

`TRAFFIC_ACTIVE` → `TRAFFIC_IDLE` transitions timestamp disconnect events without requiring packet drops. If `TRAFFIC_IDLE` appears without `DROPS` → traffic stopped upstream (Blizzard/router). If `DROPS` appears → host is dropping packets before the VM.

```bash
# All network events
journalctl -u overwatch | grep NET_HOST

# Disconnect timestamps
journalctl -u overwatch | grep -E "NET_HOST TRAFFIC|NET_HOST DROPS"
```

### Runtime Performance (30s loop, background)

| Metric | Tool | Tag |
|---|---|---|
| Per-core CPU (cores >50% only) | `mpstat -P ALL` | `PERF_HOST cpu:` |
| Disk I/O (r_await, w_await, %util on nvme1n1) | `iostat -x` | `PERF_HOST disk:` |
| Memory (free, available, swap) | `/proc/meminfo` | `PERF_HOST mem:` |

Requires `sysstat` package for CPU and disk metrics. Memory is always logged.

```bash
journalctl -u overwatch | grep PERF_HOST
```

### Shutdown Timing

| Component | What it measures | When | Output |
|---|---|---|---|
| UDP listener (port 9147) | Windows shutdown initiation timestamp (epoch) | Background during runtime | `/tmp/.overwatch-shutdown-ts` |
| QEMU process state tracking | State transitions (started) → S → D → exited | After shutdown signal received | stdout |
| Shutdown duration calc | Signal-to-domain-stop delta (validates ≤300s) | VM stopped | stdout |

The shutdown signal requires `scripts/overwatch.ps1` deployed on the guest (see Guest-Side below).

```bash
# Shutdown duration log
journalctl -u overwatch | grep "Shutdown duration\|QEMU state\|Shutdown signal"
```

### All V2 Grep Tags

```bash
journalctl -u overwatch | grep -E "STATE|BOOT_TIMING|PERF_HOST|NET_HOST|ERROR"
```

---

## Guest-Side

### Post-Boot Diagnostics (`log_guest_diagnostics()`, background, runs 120s after VM start)

| Section | What it measures | Source | Tag |
|---|---|---|---|
| `SHUTDOWN_DIAG` | Event IDs 200–203 from Diagnostics-Performance: prior shutdown duration, slow services, slow drivers | `Get-WinEvent` | `SHUTDOWN_DIAG` |
| `CRASH_DUMPS` | 5 most recent `.dmp` files from LiveKernelReports + Minidump (size, timestamp) | `Get-ChildItem` | `CRASH_DUMPS` |
| `GPU_DRIVER` | AMD GPU PnP status (OK/Error), driver version | `Get-PnpDevice` | `GPU_DRIVER` |
| `HD_AUDIO` | GPU audio codec PnP status | `Get-PnpDevice` | `HD_AUDIO` |
| `DISPLAY_EVENTS` | 20 most recent events from dxgkrnl, Dwm, Display providers (TDR recoveries, mode switches) | `Get-WinEvent` System log | `DISPLAY_EVENTS` |
| `BOOT_DIAG` | Event ID 100: MainPathBootTime, BootPostBootTime, BootDriverInitTime, BootIsDegradation | `Get-WinEvent` Diagnostics-Performance | `BOOT_DIAG` |

120s startup delay avoids guest-exec contention with `attach_tartarus_deferred()` during boot.

```bash
journalctl -u overwatch | grep -E "SHUTDOWN_DIAG|CRASH_DUMPS|GPU_DRIVER|HD_AUDIO|DISPLAY_EVENTS|BOOT_DIAG"
```

### Runtime Performance (`monitor_guest_perf()`, 60s loop via LHM WMI)

Requires LibreHardwareMonitor v0.9.4 net472 running as SYSTEM on guest.

| Metric | Source | Tag |
|---|---|---|
| GPU load %, temps (core/hotspot/memory), clocks (core/memory), package power, VRAM used/total | `root\LibreHardwareMonitor` WMI namespace | `PERF_GUEST` |

If LHM is not available, logs `PERF_GUEST: LibreHardwareMonitor WMI not available` and exits.

```bash
journalctl -u overwatch | grep PERF_GUEST
```

### Shutdown Signal (`scripts/overwatch.ps1`)

4-line PowerShell script on guest: sends UDP "shutdown" to host port 9147 when Windows
Event ID 1074 fires (system shutdown initiated). Deploy to `C:\Scripts\overwatch.ps1`.
Setup command is in the script header.

---

## All Grep Tags

```bash
journalctl -u overwatch | grep -E "STATE|BOOT_TIMING|SHUTDOWN_DIAG|CRASH_DUMPS|GPU_DRIVER|HD_AUDIO|DISPLAY_EVENTS|BOOT_DIAG|PERF_HOST|PERF_GUEST|NET_HOST|ERROR"
```
