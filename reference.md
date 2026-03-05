# Reference

Known problems, debugging checklists, and stress tests.
Generalized debugging principles live in the [nerv](https://github.com/pketienne/nerv) repo (`debugging-principles.md`).

## Known Problems

| Problem | Cause | Solution |
| --- | --- | --- |
| White screen on iGPU | `amd_iommu=force_isolation` breaks iGPU DMA | Remove `force_isolation` from kernel params |
| GPU not visible in Windows | GPU never initialized, QEMU can't read ROM | Download VBIOS from TechPowerUp, add as ROM file |
| "failed to find romfile" | QEMU sandbox restricts file access | Place ROM in `/usr/share/qemu/` |
| YouTube won't load in VM | NAT/QUIC issues | Switch to bridged networking |
| Tartarus not detected in VM | USB re-enumeration, stale addresses | Remove hardcoded `<address bus=... device=...>` from USB source entries in VM XML |
| amdgpu unbind hangs (D state, i2c_del_adapter) | OpenRGB holding `/dev/i2c-*` FDs via DP AUX I2C adapters | `systemctl stop openrgb` before unbinding (overwatch does this) |
| amdgpu unbind hangs (D state, drm_dev_unplug) | GDM/GNOME Shell has DRM card FDs open (multi-GPU) | `systemctl stop gdm` before unbinding (overwatch does this) |
| amdgpu unbind hangs (D state, drm_fb_helper_fini) | `drm_fb_helper` damage worker accessing GPU VRAM during teardown; `cancel_work_sync` waits forever on dead hardware. ~1.5% hit rate across unbind cycles. Stack: `amdgpu_pci_remove` -> `drm_dev_unplug` -> `drm_fb_helper_fini` -> `cancel_work_sync(&damage_work)`. The worker's early-out checks `info->state != FBINFO_STATE_RUNNING`. | Suspend dGPU framebuffer before unbind: `echo 1 > /sys/class/graphics/fbN/state` (matched by PCI device path, not hardcoded number). This causes in-flight damage work to return immediately. Note: VT console unbind (`echo 0 > vtcon*/bind`) is not sufficient — it detaches console input but doesn't prevent DRM fbdev damage work. overwatch does this. |
| amdgpu bind fails after VFIO (SMU hang, MES KIQ lockup, VCN suspend hang) | GPU still in Windows guest state after VFIO release; firmware state machines running, command queues initialized, display engine in guest mode | PCIe Secondary Bus Reset (SBR) after vfio-pci unbind, before amdgpu bind. RX 7900 XTX doesn't support FLR — SBR is the only available reset method. Resets both 03:00.0 and 03:00.1, also eliminating the need for PCI remove/rescan of the audio device. overwatch does this. |
| No display after GPU hot-plug via `virsh attach-device` | WDDM doesn't support hot-adding display adapters to an active Windows session. PnP loads the driver and GPU reports OK, but DxgKrnl never registers it — without OVMF executing the VBIOS option ROM at boot, the display engine never initializes. `SetDisplayConfig` returns `ERROR_INVALID_PARAMETER`; `EnumDisplayDevices` only shows Microsoft Basic Display Driver. | GPU must be in VM XML at boot time. Do not attempt `virsh attach-device --live` for display adapters. This is a fundamental Windows architecture limitation, not a configuration issue. |
| libvirt hooks deadlock | Hooks call systemctl/virsh synchronously | Use overwatch wrapper instead of hooks; hook file is no-op `exit 0` |
| No display after VM shutdown | iGPU display in DPMS off state | overwatch unblanks iGPU and restarts GDM |
| GDM wrong aspect ratio (single GPU) | monitors.xml connector mismatch | Update connector name (e.g. `HDMI-1` -> `HDMI-3` when dGPU on amdgpu shifts numbering) |
| GDM wrong aspect ratio (dual GPU) | Both dGPU DP-1 and iGPU HDMI-3 connected to same monitor; monitors.xml lists only one output so GDM falls back to auto (3840x2160) | Add `<disabled>` section for DP-1 in monitors.xml |
| GNOME Shell crashes when GPU unbinds | dGPU used for GPU-accelerated rendering | Stop GDM before unbinding amdgpu; run via systemd service (`systemctl start overwatch`) |
| overwatch dies when GDM stops | Script runs in GNOME terminal session | Runs as systemd service (`systemctl start overwatch`); SIGTERM handler runs full host restore on stop |
| Audio volume much lower in VM | Windows volume state desyncs after USB passthrough | Move volume slider to 0% then back to 100%. Check SteelSeries GG EQ, Volume Mixer per-app levels. Use Settings -> System -> Sound (not `mmsys.cpl` which may freeze the VM) |
| GPU crashes during desktop use | amdgpu runtime PM puts GPU into D3; resume finds device unresponsive (`0xffffffff` registers), `device lost from bus`, soft lockup | `/etc/modprobe.d/amdgpu.conf` with `options amdgpu runpm=0`. overwatch also writes `power/control=on` after amdgpu bind on restore |
| GPU audio D3cold after VM passthrough | Audio function stuck in D3cold after VFIO; binding snd_hda_intel triggers failed power transition that crashes the entire GPU | PCIe bus reset (SBR) resets both GPU and audio function; overwatch binds snd_hda_intel directly without PCI remove/rescan |
| Concurrent overwatch instances cause dirty state | Second instance finds GPU in unexpected driver state | Lock file via `flock /run/overwatch.lock` prevents concurrent instances |
| Windows BSOD 0x9F DRIVER_POWER_STATE_FAILURE | Windows power plan sends power IRPs to passthrough devices; vfio-pci owns hardware so guest driver can't complete transitions | High Performance power plan + disable ASPM, USB suspend, sleep. Run `setup-guest.sh power` to apply. |
| Frequent 0x9F BSODs after Windows Update | Windows Update pushed AMD driver 31.0.14000.58004 (Feb 2026) which corrupts GPU state every 2-5 min during gameplay | Roll back via Device Manager -> Display adapters -> Roll Back Driver. Block reinstall: Settings -> Windows Update -> Pause updates, or `wushowhide.diagcab` to hide the driver update. Known-good driver: Radeon Software 32.0.23017.1001 (2026-01-08). |
| Windows BSOD 0x9F during shutdown specifically | HDAudBus blocks waiting for GPU HDA audio codec behind vfio-pci during power-down. WinDbg on minidump shows blocked IRP: `HDAudBus!HdaController::TransferCodecVerbs` waiting for codec response that can never come. | Uninstall AtiHDAudioService + disable AMD driver power features. Run `setup-guest.sh hda-audio` and `setup-guest.sh power`. |
| WATCHDOG/AMD_WATCHDOG live kernel dumps on VM boot (intermittent) | Defender service init (~12s CPU) contends with AMD GPU driver init. Cannot be eliminated with Tamper Protection on. | Host-side CPU isolation reduces frequency to ~1 in 3 boots. AUEPMaster disabled. AMD exclusions added. Non-fatal (live dumps, not BSODs). Run `setup-guest.sh defender`. |
| amdgpu bind hangs after VM passthrough (`trn=2 ACK should not assert`) | GPU SMU mailbox stuck after heavy GPU usage in VM (e.g. gaming); VFIO release doesn't fully reset the GPU, amdgpu probe loops forever on SMU communication | Reboot required. This is a hardware-level issue — the GPU needs a full PCI bus reset that only a machine reboot provides. Lightweight test cycles may restore fine but extended gaming sessions can leave the GPU in an unrecoverable state |
| Monitor doesn't auto-switch to DP when VM starts | iGPU HDMI stays active, monitor doesn't detect DP | Blank iGPU framebuffer (`echo 4 > /sys/class/graphics/fbN/blank`) when VM starts; monitor auto-detects to DP. fb matched by PCI device path, not hardcoded number. overwatch handles this |
| TDR (P1: 141) during fullscreen gameplay, screen freezes then recovers | MPO (Multiplane Overlay) hardware compositing exceeds watchdog threshold under VFIO passthrough latency. Alt+tab twice can unfreeze before full TDR. HAGS adds further scheduling pressure. | Disable MPO: `HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode` = 5. Disable HAGS: `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode` = 1. Reboot required. |
| Kernel panic when `systemctl stop` during VM start | SIGTERM arrives mid-GPU-handoff (amdgpu unbind -> vfio bind); `_do_stop` runs on half-unbound GPU -> `amdgpu_device_rreg` oops -> D-state process -> kernel panic | SIGTERM is deferred during GPU handoff via flag (`SIGTERM_DEFERRED`). Handoff completes to stable state (VM running or rolled back), then deferred stop is processed. Implemented in overwatch.sh `_do_start()` |
| Razer Synapse missing from system tray; notification-manager error dialog on Tartarus keypresses | Corrupted Electron cache causes RazerAppEngine UI to fail silently on startup; Windows auto-hides tray icon for apps that fail to register it | Stop RazerAppEngine, delete `%LOCALAPPDATA%\Razer\RazerAppEngine\User Data\Default\Cache`, `Code Cache`, and `GPUCache`, restart Synapse. Re-enable icon in Windows Settings -> Personalization -> Taskbar -> Other system tray icons |
| Repeated `LiveKernelEvent P1:141` (VIDEO_TDR_FAILURE) + `AMD_WATCHDOG` during gameplay; OW2 crashes with "Rendering Device Lost" | VFIO passthrough TDR pressure: `dxgmms2!VidSchiCheckHwProgress` detects GPU stall and triggers engine reset; faulting module is `amdkmdag.sys`. `TdrDelay=60` prevents BSOD but live dumps fire earlier as part of TDR recovery — the 60s timeout doesn't prevent the stall itself. Confirmed on known-good driver 32.0.23017.1001 (not driver-related). AMD_WATCHDOG always accompanies WATCHDOG (141), indicating AMD's internal driver watchdog fires alongside DxgKrnl TDR. | Lower in-game graphics settings to reduce GPU command pressure; configure huge pages on host (`<memoryBacking>` in VM XML) to reduce IOMMU translation overhead; try newer driver 32.0.23027.2005. WinDbg `!analyze -v` on `C:\Windows\LiveKernelReports\WATCHDOG\*.dmp` confirms call stack. |
| Screen freezes during match transition (menu->match or match->menu); if left alone results in "Lost connection to server" or "Rendering Device Lost" | VFIO TDR pressure during GPU command burst (asset loads, shader compiles, render target swaps). **Always freezes if OW2 is alt-tabbed (backgrounded) during transition** — game goes from background FPS limit (low GPU activity) to maximum load in one frame; the cold-to-hot spike overwhelms VFIO interrupt latency every time. When OW2 is in the foreground, the GPU is already at steady-state 240fps so the transition delta is smaller — sometimes works fine, sometimes hiccups. `amdkmdag+0x1ec600` is the consistent stall point. | **Primary: `transition-throttle.ps1`** — automatically detects loading screens via GPU Engine counters (<15% utilization for 1s) and throttles OW2's CPU affinity from 6 to 2 vCPUs, slowing command generation below TDR threshold. Runs as scheduled task, logs `TRANSITION` events to host. **Manual fallback:** Keep OW2 in the foreground when queuing. If a hiccup occurs, Alt+Tab -> wait 2-3s -> Alt+Tab back. Reduce frequency with: Render Scale Custom 100%, Frame Rate Custom 240. |
| Lost connection to server / Overwatch lobby disconnect (no network drops) | `BNPresence ERROR_INTERNAL` in Battle.net logs — presence subscription failure after Battle.net auto-updated during a host reboot; corrupted cached auth state for BGS presence entity. NET_HOST shows TRAFFIC_IDLE with zero DROPS (traffic stopped from game side, not dropped by host). | Close Battle.net, delete `C:\Users\myuser\AppData\Local\Battle.net\Cache`, relaunch. The in-app "Clear Cache" button was removed in newer client versions — must delete manually. Check `C:\Users\myuser\AppData\Local\Battle.net\Logs\` for `BNPresence\|ERROR_INTERNAL` to confirm. |
| Repeated TDR crashes / "Rendering Device Lost" mid-match; brief gameplay freezes ("blips") | VM allocated too much RAM (e.g. 88GiB on a 96GiB host), leaving host with only ~6GiB. kswapd runs on host CPUs competing with VCPU threads -> VCPU scheduling latency -> GPU misses WDDM heartbeat -> TDR. Host swap use (3-4GiB) confirms pressure. Windows + OW2 only uses ~7-15GiB in practice. | Reduce VM memory to give host ~half the pool (48GiB VM on 96GiB host). Update VM XML memory fields and `hugepages=` in GRUB, then reboot host. Verify with `grep HugePages_Free /proc/meminfo` and `swap=0` in PERF_HOST mem logs. |
| Micro-stuttering despite stable frame rate | vCPU threads floating across all host cores; host scheduler preempts vCPU mid-GPU-command-stream causing uneven frame delivery (frame pacing). Frame rate counter shows same number but frames are unevenly spaced. | Add `<cputune>` to VM XML pinning vCPUs to isolated cores. Defer `AllowedCPUs` host confinement until guest agent responds (immediate application slows Windows boot due to emulator thread bottleneck during interrupt burst). GRUB: `isolcpus=domain,managed_irq,2-7 nohz_full=2-7 rcu_nocbs=2-7`. |

## Debugging Checklists

### Before you start

- [ ] **Verify Tamper Protection is ON** (`TamperProtection=0x5` in `HKLM\SOFTWARE\Microsoft\Windows Defender\Features`). Never disable it
- [ ] What changed recently? (OS updates, driver updates, firmware, config)
- [ ] Can you reproduce reliably? How often?
- [ ] What's your measurement? (timestamps, logs, counters)
- [ ] If a guest app seems to have stopped running but its devices/services still work: check Windows notification area settings (Settings -> Personalization -> Taskbar -> Other system tray icons) before assuming a process crash — Windows auto-hides tray icons for apps that fail to register cleanly

### For BSOD / guest crashes

- [ ] Check `Get-WinEvent` for bugcheck parameters (Id=1001)
- [ ] Check `Get-WinEvent` for recent driver installations
- [ ] Check power plan settings (`powercfg /getactivescheme`)
- [ ] Check AMD driver registry values (ULPS, ASPM)
- [ ] If consistent bugcheck: get minidump, run WinDbg `!analyze -v`
- [ ] Correlate BSOD timing with host dmesg timestamps

### For host hangs (D-state, soft lockup)

- [ ] Check `/proc/PID/stack` for the blocked function
- [ ] Check `fuser` and `lsof` for all device nodes the driver manages
- [ ] Check `systemctl list-units` for services holding device FDs
- [ ] Check runtime PM state (`cat power/runtime_status`)
- [ ] If `i2c_del_adapter`: something holds i2c FDs (OpenRGB, DDC tools)
- [ ] If registers read `0xffffffff`: hardware failure, reboot required

### For "no display" after VM start/stop

- [ ] Is the GPU on the right driver? (`readlink /sys/bus/pci/devices/.../driver`)
- [ ] Is the monitor input correct? (iGPU blanked? DP signal present?)
- [ ] Guest device manager: is the GPU in Error state? (Code 43 = missing
  multifunction peer; Code 10 = driver failed to start)
- [ ] Did both PCI functions (GPU + audio) get passed through?

### For live kernel dumps (WATCHDOG / VIDEO_DXGKRNL_LIVEDUMP)

- [ ] Check `C:\Windows\LiveKernelReports\WATCHDOG\` for dump files + timestamps
- [ ] Check WER events: `Get-WinEvent -FilterHashtable @{LogName='Application';
  ProviderName='Windows Error Reporting'}` for `LiveKernelEvent` entries with
  bugcheck parameters (P1=0x1B0 = VIDEO_DXGKRNL_LIVEDUMP)
- [ ] Build a boot process timeline: `Get-Process | Sort-Object StartTime` with
  CPU consumption to identify what was running at the dump timestamp
- [ ] Check for heavy boot-time CPU consumers: Defender (MsMpEng), AMD
  telemetry (AUEPMaster), Razer, etc. — GPU init TDRs are often contention
- [ ] If disabling a component doesn't help, check all launch paths: services,
  scheduled tasks (`Get-ScheduledTask`), startup folder, Run/RunOnce registry
- [ ] **For gameplay TDRs (P1=141, amdkmdag.sys):** run WinDbg `!analyze -v`
  on the dump — look for `VidSchiCheckHwProgress` in the call stack, which
  confirms VFIO passthrough TDR pressure (GPU stall detected by WDDM scheduler).
  `TdrDelay=60` prevents BSOD but not live dumps; the dump fires as part of
  TDR recovery, before the 60s timeout. Mitigations: lower graphics settings,
  huge pages, newer driver.

### Running WinDbg non-interactively via guest-exec

Install WinDbg from the Microsoft Store on the guest (free). The binary is in
`C:\Program Files\WindowsApps\Microsoft.WinDbg_<ver>_x64__8wekyb3d8bbwe\amd64\kd.exe`.
Run via guest-exec (from the Python helper scripts on myhost):

```python
KD   = "C:\\Program Files\\WindowsApps\\Microsoft.WinDbg_<ver>_x64__8wekyb3d8bbwe\\amd64\\kd.exe"
DUMP = "C:\\Windows\\LiveKernelReports\\WATCHDOG\\WATCHDOG-<timestamp>.dmp"
SYMS = "srv*C:\\Symbols*https://msdl.microsoft.com/download/symbols"
OUT  = "C:\\Temp\\kd_out.txt"
# arg: ["-z", DUMP, "-y", SYMS, "-c", "!analyze -v; q", "-logo", OUT]
```

Allow ~3 minutes for symbol download. Read `C:\Temp\kd_out.txt` after completion.
Note: Store app stubs in `C:\Users\myuser\AppData\Local\Microsoft\WindowsApps\` cannot
be launched from SYSTEM context — use the full package path above.

### For game disconnects / lost connection to server

- [ ] Check NET_HOST logs: `journalctl -u overwatch | grep "NET_HOST TRAFFIC\|NET_HOST DROPS"` — if `TRAFFIC_IDLE` appears without `DROPS`, the disconnect is upstream of the host (Blizzard or game client), not a network issue
- [ ] If no drops: check Battle.net logs at `C:\Users\myuser\AppData\Local\Battle.net\Logs\` for `BNPresence ERROR_INTERNAL` — presence subscription failure causes disconnects regardless of network quality
- [ ] If BNPresence errors found: close Battle.net, delete `C:\Users\myuser\AppData\Local\Battle.net\Cache`, relaunch (in-app "Clear Cache" was removed from newer client versions — delete manually)
- [ ] Check whether Battle.net auto-updated during the last host reboot by comparing log file timestamps with reboot time

### For performance / timing issues

- [ ] Add measurement before adding fixes
- [ ] Instrument the shutdown path (UDP signal + process state tracking)
- [ ] Query Windows Diagnostics-Performance events (IDs 200-203)
- [ ] Check for udev/driver race conditions (probe overriding sysfs writes)

### After fixing

- [ ] Remove workaround code that targeted symptoms, not root cause
- [ ] Update documentation with the actual root cause and fix
- [ ] Test the "it works without the workaround" hypothesis
- [ ] Record the failure pattern for future reference even if you don't
  fully understand it

### Host-level tracing (BPF tools)

Available via `bpfcc-tools`, `bpftrace`, `trace-cmd`. Useful for deep-diving
host-side issues that the polling monitors in overwatch.sh can't catch:

| Tool | Use case | Example |
| --- | --- | --- |
| `bpftrace` | One-liner kernel probes | `bpftrace -e 'tracepoint:kvm:kvm_exit { @[args->exit_reason] = count(); }'` — count VM exit reasons |
| `trace-cmd` | Kernel ftrace recorder | `trace-cmd record -e kvm` — record all KVM events during a session |
| `bpfcc-tools` | Pre-built BPF scripts | `biolatency` (disk latency histograms), `runqlat` (scheduler queue latency) |

These are ad-hoc diagnostic tools for manual investigation, not wired into the overwatch service.

## Stress Testing

Synthetic loads for reproducing failure modes without needing a game session.

### GPU TDR stability (FurMark or Unigine Heaven)

Start the VM, launch benchmark, run 15 minutes. Check for new dumps:

```powershell
Get-ChildItem C:\Windows\LiveKernelReports\WATCHDOG\ |
    Sort-Object LastWriteTime | Select-Object -Last 5 Name,LastWriteTime
```

| Outcome | Conclusion |
| --- | --- |
| Clean run, no dumps | GPU passthrough stable; game crashes are server/network |
| Dump within 5 min | GPU config unstable; check huge pages, graphics settings |
| Dump after 10+ min | Marginal stability; likely thermal or power delivery |

### VCPU scheduling pressure (stress-ng on host cores 0-1)

Run on host while actively gaming to test CPU isolation robustness:

```bash
sudo stress-ng --cpu 2 --taskset 0,1 --cpu-method matrixprod \
    --metrics-brief --timeout 120s
```

Monitor with `mpstat -P ALL 1` (cores 0-1 at ~100%, 2-7 normal guest load).

| Guest behavior | Conclusion |
| --- | --- |
| Smooth gameplay | CPU isolation robust; emulator thread on 2 cores sufficient |
| Blips during stress | Emulator thread bottleneck; interrupt injection latency-sensitive |
| TDR dump generated | Core 0-1 saturation causes WDDM timeout; emulator needs more headroom |

### Host memory pressure (observation only)

**Fixed** — VM RAM reduced from 88GiB to 48GiB. **Do not reproduce** by reducing
hugepages. If you suspect pressure returned:

```bash
free -h                           # swap > 0 means pressure is back
grep HugePages_Free /proc/meminfo # should be 0 after VM starts
top -d1 -p $(pgrep kswapd)       # any sustained CPU% is bad
```

Expected: zero swap, all 24,576 huge pages allocated, kswapd idle.
