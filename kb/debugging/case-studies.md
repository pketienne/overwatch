# Case Studies

Detailed investigations from the GPU passthrough project. Each case study
names the [principle](principles.md) it illustrates.

---

## The Arc

The project hit **12+ distinct failure modes** over 5 days, 10 sessions, and
30 commits. Every failure was eventually resolved. The timeline:

```
Day 1 (Feb 21): First VM boot, navi31_reset kernel module, VBIOS reverse engineering
Day 2 (Feb 22): Infrastructure docs, disk layout, bridge networking
Day 3 (Feb 23): The marathon session — IOMMU, i2c hangs, hook deadlocks,
                GPU reset, BSOD investigation, runtime PM crashes, display
                switching — 20MB of session transcript
Day 4 (Feb 24): Broken AMD driver identified, 3 rounds of code removal,
                runtime PM race fixed, shutdown BSOD root cause found
                via WinDbg analysis
Day 5 (Feb 25): WATCHDOG TDR root cause — Windows Defender boot contention,
                AUEPMaster dual-launch-path discovery, registry policy
                deferral fix, systemd service conversion
```

The script grew from 212 lines to 967 lines (building workarounds), then
shrank to 591 lines (removing them after root causes were found).

---

## Shutdown Timing Instrumentation (Method 1)

Variable shutdown durations (10s vs 248s vs BSOD) were impossible to reason
about without data. Four measurement channels made every subsequent
investigation possible:

**UDP listener + PowerShell sender**: A 15-line UDP listener + 4-line
PowerShell sender (`overwatch.ps1`) gave exact millisecond
timestamps. This immediately revealed that the 104-second "clean" shutdown
after the ULPS fix was still pathologically slow — it wasn't fixed, just
masked.

**QEMU process state tracking**: Polling `/proc/$qemu_pid/status` every 2
seconds revealed the S→D→exited transition pattern. The D-state (disk sleep /
VFIO teardown) duration directly measured how long GPU release took. Without
this, all you see is "VM stopped."

**Windows Diagnostics-Performance events**: Querying Event IDs 200-203 via
the QEMU guest agent after each boot gave Windows' own measurement of
shutdown duration, slow services, slow apps, and slow drivers — from the
prior session's shutdown. This is how the HDAudBus driver was identified as
the blocking component.

**Bind-history TSV**: A structured log recording GPU power state, audio
power, link speed, d3cold_allowed, register reads, and whether a reset was
needed after each VM cycle. This accumulated enough data points to notice
patterns (e.g., gaming sessions trigger SMU hang but quick test cycles
don't).

---

## 0x9F BSOD at Shutdown (Method 2)

The investigation went through three hypotheses before reaching root cause:

1. **Hypothesis 1: Windows power plan** (Balanced sends IRPs to passthrough
   devices). Fix: High Performance plan + disable ASPM. Result: BSODs during
   gameplay stopped, but shutdown BSODs continued. *Partially correct — this
   was a real contributor to runtime BSODs, but not the shutdown-specific
   one.*

2. **Hypothesis 2: AMD ULPS** (Ultra Low Power State transitions during
   shutdown). Fix: registry values `EnableUlps=0`,
   `PP_SclkDeepSleepDisable=1`, `DisableDrmdmaPowerOff=1`. Result: 104s
   shutdown, no BSOD. *Appeared to work but the 104s time was suspicious —
   something was still hanging and eventually timing out.*

3. **Root cause: HDAudBus codec verbs** — WinDbg on a minidump showed the
   actual blocked IRP was `IRP_MN_SET_POWER` to D1 on the HDA audio codec.
   `HDAudBus!HdaController::TransferCodecVerbs` was waiting for a response
   from the GPU's audio codec, which is behind vfio-pci and can never
   respond. Fix: `pnputil /disable-device` on the HDAUDIO device. Result:
   24s clean shutdown.

The key move was WinDbg analysis of the minidump, which named the exact
function and IRP that was blocking. Without that, hypothesis 2 would have
been considered "good enough" and the 104s shutdown would remain a mystery.

### What WinDbg revealed

```
BugcheckCode: 0x9F (DRIVER_POWER_STATE_FAILURE)
Parameter1: 0x3 (device object blocked power IRP too long)
Parameter4: -> nt!TRIAGE_9F_POWER -> blocked thread stack:
  HDAudBus!HdaController::TransferCodecVerbs
  HDAudBus!HdaController::ChangePowerState
  HDAudBus!HdaController::SetPowerD1
  -> waiting for GPU HDA codec to respond to verb transfer
```

This immediately named:
- The driver: `HDAudBus.sys`
- The function: `TransferCodecVerbs`
- The power transition: D0→D1 (power-down)
- The device: GPU's HDA audio codec

---

## i2c_del_adapter Hang (Method 2)

The amdgpu unbind hung in D-state, requiring hard power cycles. Attempts to
fix it:

1. `fuser -k /dev/dri/card1` → killed GNOME Shell, killed the terminal,
   killed the script
2. `modprobe -r amdgpu` → can't unload, iGPU also uses it
3. PCI remove → same hang, same i2c code path
4. `timeout` on sysfs unbind → D-state processes are unkillable
5. Force DP connectors off via sysfs → didn't help

What actually worked: `systemctl stop openrgb`. The root cause was OpenRGB
holding file descriptors on all 7 i2c adapters. The fix was stopping the
*specific service* before unbinding — not fighting the kernel.

---

## Broken AMD Driver (Method 3)

The most impactful discovery came from querying the guest OS's event history.

```
Timeline:
- Feb 21, 15:48 — Windows Update installs AMD driver 31.0.14000.58004
- Feb 21, 15:48 — Also installs KB5077181 (Feb 2026 security update)
- Feb 21 onwards — Constant 0x9F BSODs (7 in one day)
- Feb 23 — Session 6 builds massive workaround infrastructure
- Feb 24 — Session 7 finally queries Get-WinEvent for full history
```

Three days of building reset chains, suspend/resume workarounds, degraded
mode fallbacks, and a custom kernel module — all compensating for a broken
Windows-Update-pushed driver. Once the 31.x driver packages (`oem5.inf`,
`oem6.inf`) were removed from the driver store and the good 32.x driver
(`oem30.inf`) was the only one present, zero resets were needed across three
consecutive VM cycles.

The `Get-WinEvent` query that found the driver installation took 30 seconds.
The workaround infrastructure it replaced was ~350 lines of code built over
two days.

---

## Audio D3cold Crash (Method 7)

Cross-boundary timestamp correlation revealed a 100ms race window:

```
T+0.0s  overwatch: "Binding amdgpu..."
T+0.2s  dmesg: amdgpu probed successfully
T+0.3s  overwatch: "Re-enumerating GPU audio..."
T+0.4s  dmesg: snd_hda_intel probe on 03:00.1
T+0.5s  dmesg: "Unable to change power state from D3cold to D0"
T+0.6s  dmesg: "CORB timeout, GPU codec unreachable"
T+0.7s  dmesg: "device lost from bus"
T+1.2s  dmesg: soft lockup on CPU 3
```

The 100ms gap between amdgpu probe and snd_hda_intel probe was the window
where the audio device was in D3cold with no driver managing it. The fix
(PCI remove + rescan to re-enumerate in a clean state) specifically targeted
that window.

---

## Boot-Time TDR Dumps (Method 7)

Two WATCHDOG live kernel dumps appeared every boot at T+49s and T+78s. Event
logs showed no corresponding errors — just WER `LiveKernelEvent` entries with
bugcheck `0x1B0` (`VIDEO_DXGKRNL_LIVEDUMP`). The binary dumps required WinDbg
to decode, but the *timing* was diagnostic on its own.

Building a process timeline via `Get-Process | Sort-Object StartTime` with CPU
consumption revealed:

```
Boot: 19:14:51
T+21s  AMD kernel services: amdfendrsr, atiesrxx, atieclxx (0.2-0.4s CPU)
T+23s  AUEPMaster (AMD telemetry) — 30.5s CPU
T+23s  MsMpEng (Defender) — 51.2s CPU
T+43s  RadeonSoftware — 2.1s CPU
T+49s  *** WATCHDOG dump 1 ***  (GPU driver init under heavy contention)
T+77s  ctfmon (text services)
T+78s  *** WATCHDOG dump 2 ***  (display pipeline initialization)
T+82s  dwm (Desktop Window Manager starts)
T+83s  AMDRSServ (AMD Radeon Settings)
```

The two TDR dumps correlated with the GPU driver being initialized while
AUEPMaster (30.5s CPU) and MsMpEng (51.2s CPU) were hammering the system.
The dumps weren't caused by a single bad component — they were caused by
*contention during GPU initialization*. This led to disabling AUEPMaster
(freeing 30s of boot CPU) and identified Defender as the next-largest
contributor.

---

## GPU Hot-Plug Attempt (Method 2)

The WATCHDOG TDR dumps (~1 in 3 boots) were caused by DxgKrnl WDDM driver init
during boot contention. Testing confirmed that manually hot-plugging the GPU
after boot via `virsh attach-device --live` eliminated dumps entirely: 0/5
cycles vs 3/5 with GPU present at boot. This motivated a full implementation.

### What was built

`ensure_gpu_hotplugged()` in overwatch.sh: wait for guest agent (confirms
Windows boot complete), then hot-plug GPU and audio PCI hostdevs via
`virsh attach-device --live`. GPU/audio hostdevs removed from persistent VM
config — managed entirely by overwatch.

Deployed, started VM. Hot-plug succeeded — guest agent ready in ~8s, both
devices attached, AMD GPU showed `Status: OK` in PnP, AMD driver loaded.

### What failed

No display output. The monitor got no signal on DisplayPort. Investigation:

1. `Win32_VideoController` showed the AMD GPU with no resolution set
2. `WmiMonitorBasicDisplayParams` detected the LG ULTRAGEAR+ monitor (EDID was
   read) but all monitors showed `Status: Unknown`
3. `displayswitch /external` — appeared to work briefly (monitor's auto-input
   detection cycled to DP for 5-10s) but no actual video signal was produced.
   No display events in Windows Event Log confirmed nothing happened.
4. `EnumDisplayDevices` — only 1 display adapter registered: Microsoft Basic
   Display Driver. The AMD GPU was completely absent from the display subsystem.
5. `QueryDisplayConfig` — only 1 active display path (the Basic Display Driver)
6. `SetDisplayConfig` with `SDC_TOPOLOGY_EXTERNAL` — returned
   `ERROR_INVALID_PARAMETER` (87) from both Session 0 and the interactive
   session, confirming the topology didn't exist

### Root cause

**WDDM does not support hot-adding a display adapter to an active Windows
session.** The PCI device is detected, PnP loads the driver, the GPU reports
OK — but DxgKrnl never registers it as a display adapter because it wasn't
present during boot. Without OVMF executing the VBIOS option ROM at VM start,
the display engine hardware never initializes, and the WDDM display topology
is never created. This is a fundamental Windows architecture limitation, not a
configuration issue.

### Key insight

The pre-implementation manual test (hot-plug via virsh) confirmed "zero TDR
dumps" but never verified display output — it only measured crash dump
presence. The test validated the hypothesis it was designed to test (TDR
elimination) but missed the critical side effect (no display). **Validate all
user-visible outcomes, not just the metric that motivated the change.**

### Pivot

Keep GPU in persistent VM config (OVMF runs VBIOS, display engine initializes,
WDDM registers adapter at boot) but prevent the AMD WDDM driver from loading
during boot by disabling the device in Windows Device Manager (persistent
`ConfigFlags` in registry). After boot settles, enable via `Enable-PnpDevice`
through guest agent — driver loads post-boot with zero contention.

---

## drm_fb_helper_fini Deadlock (Method 2)

The amdgpu sysfs unbind hung in D-state, requiring a hard power cycle. This
was the second occurrence across ~133 unbind cycles (~1.5% hit rate) — rare
enough to not be obvious, but a hard failure when it hits.

### Kernel stack trace

```
__flush_work
cancel_work_sync
drm_fb_helper_fini
drm_fbdev_ttm_fb_destroy
put_fb_info
unregister_framebuffer
drm_fb_helper_unregister_info
drm_fbdev_client_unregister
drm_client_dev_unregister
drm_dev_unregister
drm_dev_unplug
amdgpu_pci_remove          ← triggered by sysfs unbind
```

### Root cause

`drm_fb_helper` has a `damage_work` worker that blits the shadow framebuffer
to VRAM (`drm_fb_helper_damage_work` → `drm_fbdev_ttm_damage_blit`). During
driver removal, `drm_fb_helper_fini` calls `cancel_work_sync(&damage_work)`
to wait for any in-flight work to complete. But the work was already running
and trying to access GPU VRAM via TTM buffer mapping — the GPU hardware was
being torn down concurrently by `amdgpu_pci_remove`, so the buffer operation
hung on dead hardware. `cancel_work_sync` waited forever.

This is **not** a `console_lock` deadlock (the damage worker doesn't touch
`console_lock`). It's a race between a queued framebuffer dirty operation and
device removal.

### The early-out

The damage worker has a guard:

```c
static void drm_fb_helper_damage_work(struct work_struct *work) {
    if (helper->info->state != FBINFO_STATE_RUNNING)
        return;                    // bails immediately
    drm_fb_helper_fb_dirty(helper);
}
```

Setting `/sys/class/graphics/fbN/state` to `1` (`FBINFO_STATE_SUSPENDED`)
before initiating the unbind causes any in-flight or newly-scheduled damage
work to return immediately instead of trying to access dying hardware.

### Fix

Added to `ensure_gpu_unbound_from_host()` in overwatch: find the dGPU's
framebuffer by PCI device path and set `state=1` before the amdgpu unbind
echo. One-line sysfs write that directly closes the race window.

### Key insight

VT console unbinding (`echo 0 > vtcon*/bind`) was already done before the
GPU unbind, but that only detaches the console *input* — it doesn't prevent
the DRM fbdev client from scheduling damage work for pending
redraws. The framebuffer and the VT console are separate subsystems with
separate lifecycle management.

---

## Gameplay TDR Root Cause via WinDbg (Method 2)

OW2 was crashing with "Rendering Device Lost" 5+ times per session. Each crash
coincided with a paired `WATCHDOG` (P1:141) + `AMD_WATCHDOG` (P1:a1000001)
live kernel dump. Standard mitigations were already in place: `TdrDelay=60`,
MPO disabled, HAGS disabled, known-good driver 32.0.23017.1001.

### WinDbg `!analyze -v` output (WATCHDOG-20260302-2047.dmp)

```
Failure.Exception.IP.Module: amdkmdag
FAILURE_BUCKET_ID: LKD_0x141_IMAGE_amdkmdag.sys

STACK_TEXT:
  dxgmms2!VidSchiCheckHwProgress+0x316   ← GPU scheduler: no progress detected
  dxgmms2!VidSchiResetEngines+0xea       ← engine reset initiated
  dxgmms2!VidSchiResetEngine+0x36e
  dxgkrnl!TdrCollectDbgInfoStage1+0xd69
  nt!DbgkWerCaptureLiveKernelDump        ← live dump captured here
```

### What this means

`dxgmms2!VidSchiCheckHwProgress` is the WDDM GPU scheduler's heartbeat check:
it periodically verifies the GPU is making forward progress on submitted
commands. When it detects a stall, it triggers `VidSchiResetEngines` →
`VidSchiResetEngine`, which collects debug info and creates the live dump.
The faulting address lands in `amdkmdag.sys` (AMD's kernel driver).

This is VFIO passthrough TDR pressure: IOMMU fault handling or VCPU scheduling
latency causes the GPU to miss the WDDM progress heartbeat window, making it
appear stalled to the scheduler. The TDR recovery succeeds (live dump, no BSOD)
but OW2 loses its DirectX device and crashes.

**Key insight:** `TdrDelay=60` only extends how long Windows waits before a
*hard* TDR BSOD. Live dumps fire earlier, as part of TDR recovery, well before
the 60s limit. Increasing TdrDelay does not prevent these events.

**Key insight:** The AMD_WATCHDOG dump (P1:a1000001) always accompanies the
WATCHDOG (141) dump. This is AMD's own driver watchdog firing alongside
DxgKrnl's TDR — both responding to the same underlying GPU stall.

### Confirmed not driver-related

The TDRs occur on driver 32.0.23017.1001 (January 2026, known-good). This
rules out the 32.0.23027.2005 regression as the cause for this pattern.

### Mitigations to try

1. Lower in-game graphics settings — reduces GPU command pressure
2. Huge pages on host — reduces IOMMU translation overhead per DMA operation
3. Try newer driver 32.0.23027.2005 — may have improved TDR handling

---

## AtihdWT6 Reinstated by Driver Update (2026-03-03)

### Background

The 0x9F BSOD at Shutdown case study identified `HDAudBus` blocking power IRPs
to the GPU's HDMI audio codec and fixed it by disabling the HDAUDIO device
(`pnputil /disable-device`). This also addressed AtihdWT6 (AMD HD Audio driver)
which was the functional driver for the GPU's HDMI audio endpoint.

### What happened

After updating to AMD driver **32.0.23027.2005** (Feb 17, 2026), the driver
installer re-added `atihdwt6.inf` to the driver store (`oem62.inf`) and
re-enabled the `AMD High Definition Audio Device` (Status: OK). The device was
back online, binding to `HDAUDIO\FUNC_01&VEN_1002&DEV_AA01&SUBSYS_00AA0100`.

The WinDbg module list from the 2026-03-03 crash dumps confirmed AtihdWT6.sys
was loaded during TDR events. The driver is compiled Sep 2, 2025 — it shipped
as part of the Adrenalin 32.0.23027.2005 package.

### WinDbg analysis of 2026-03-03 dumps

Running `!analyze -v` on `WATCHDOG-20260303-1349.dmp` and `WATCHDOG-20260303-1413.dmp`:

```
1349.dmp: BugCheck 0x117 (VIDEO_TDR_TIMEOUT_DETECTED)
  System uptime: 0:01:11 — TDR during early GPU driver initialization
  Faulting IP: amdkmdag+0x1ec600

1413.dmp: BugCheck 0x141 (VIDEO_ENGINE_TIMEOUT_DETECTED)
  System uptime: 0:25:42 — TDR during match loading
  Faulting IP: amdkmdag+0x1ec600  ← same address both times
```

Both crash at the exact same address in amdkmdag.sys, indicating the same code
path stalls regardless of whether it's early initialization or active gameplay.
The 0x117 is the initial TDR detection; the 0x141 is the follow-on engine
reset also timing out (both are live dumps, not hard BSODs).

The call stacks confirm the standard VFIO TDR path:
```
dxgmms2!VidSchiCheckHwProgress  ← heartbeat: no GPU progress detected
dxgmms2!VidSchiReportHwHang     ← hang reported
dxgkrnl!TdrIsRecoveryRequired   ← decides recovery is needed
dxgkrnl!TdrCollectDbgInfoStage1 ← live dump captured
```

### Permanent fix: Device Installation Restrictions policy

Deleting the INF and disabling the device is not durable — AMD driver updates
reinstall the INF and may re-enable the device. The durable fix is Windows
Device Installation Restrictions, which blocks PnP from binding any driver to
the hardware ID regardless of what is in the driver store:

```powershell
$restrict = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$denyKey  = "$restrict\DenyDeviceIDs"
New-Item -Path $restrict -Force | Out-Null
New-Item -Path $denyKey  -Force | Out-Null
Set-ItemProperty -Path $restrict -Name "DenyDeviceIDs"            -Value 1 -Type DWord
Set-ItemProperty -Path $restrict -Name "DenyDeviceIDsRetroactive"  -Value 1 -Type DWord
# Block HDAUDIO codec (loads AtihdWT6.sys)
Set-ItemProperty -Path $denyKey -Name "1" -Value "HDAUDIO\FUNC_01&VEN_1002&DEV_AA01" -Type String
# Block PCI HD Audio Bus (parent — prevents codec from ever enumerating)
Set-ItemProperty -Path $denyKey -Name "2" -Value "PCI\VEN_1002&DEV_AB30" -Type String
```

`DenyDeviceIDsRetroactive=1` immediately disables any currently-enabled
matching device. No reboot required; takes effect on next PnP enumeration.
Future AMD driver updates may still add `atihdwt6.inf` to the driver store, but
PnP will refuse to bind it to the blocked hardware IDs.

### Why audio interacts with GPU TDRs

The AMD HD Audio codec sits on the GPU's PCIe device (address `03:00.1`),
sharing the GPU's PCIe bus with the display engine (`03:00.0`). In a VFIO
passthrough setup, both devices are passed through and share the same IOMMU
group. When AtihdWT6 issues codec verb commands (e.g., for EDID probe, power
state transitions, or audio encoding), those commands go through the same
hardware command ring as GPU rendering work. Under VFIO, MMIO access latency
from the host can delay command completion. If a codec verb is in-flight while
dxgmms2 checks GPU progress, the heartbeat check can see the engine as "stuck"
and trigger TDR.

Disabling the audio device eliminates this command traffic from the shared ring,
reducing one source of TDR pressure during high-load transitions (match loading,
driver initialization).

### Post-removal confirmation: AtihdWT6 not primary TDR cause

After removing AtihdWT6 and the HDA Bus device, a new crash occurred at 15:02
(`WATCHDOG-20260303-1502.dmp`):

```
BugCheck 0x141, Faulting IP: amdkmdag+0x1ec600
FAILURE_ID_HASH: {48b738dd-5a92-7ff8-63d0-f075fc680fe0} — identical to 1413 dump
```

The FAILURE_ID_HASH is identical across all three 2026-03-03 dumps. AtihdWT6 removal
had no effect on the TDR signature. The audio driver removal was correct hygiene
(previously caused 0x9F shutdown BSODs via HDAudBus) but is not the cause of
gameplay TDRs.

The root cause is VFIO passthrough latency: `amdkmdag.sys` at offset `+0x1ec600`
stalls during high GPU command pressure (match transitions, driver initialization).
No driver update was available (32.0.23027.2005 = latest as of 2026-03-03).

### Reducing TDR frequency without eliminating root cause

`TdrDelay=60` converts hard crashes to recoverable stalls: the GPU hangs but Windows
recovers it within the 60s window, avoiding the "Rendering Device Lost" OW2 crash.

Additional in-game settings reduced peak GPU command pressure:
- **Render Scale**: Automatic → Custom 100%. OW2's Automatic goes *above* 100% when the
  GPU has headroom (supersampling), not at 100% as a floor. On an RX 7900 XTX at
  3440×1440, Automatic was driving render scales above 100% into match transitions.
- **Frame Rate**: Automatic → Custom 240 (matches monitor Hz, caps steady-state queue depth)

Effect: TDR events during transitions changed from hard crashes to occasional recoverable
hangs.

### Confirmed behavioral pattern (2026-03-04)

The transition freeze is **deterministic when OW2 is backgrounded** (alt-tabbed away in
borderless window mode). OW2 runs at its background FPS limit when not focused — the GPU
is near-idle. When the match starts loading, GPU command submission jumps from near-zero
to maximum in one frame. This cold-to-hot spike overwhelms the VFIO interrupt/MMIO path
every time, causing a TDR stall that results in "Rendering Device Lost" or server timeout.

When OW2 is **in the foreground**, the GPU is already at steady-state (240fps). The
transition command burst is a smaller delta from the current load. It sometimes works
cleanly; when it doesn't, a brief hiccup occurs that is recoverable:

- Alt+Tab away (game reduces submission) → wait 2-3s → Alt+Tab back
- Screen immediately recovers, match loads normally

If left alone during a foreground hiccup, the GPU does not self-recover fast enough —
the game server times out and the result is "Lost connection to server".

**Operational rule:** Keep OW2 in the foreground when queuing. If a hiccup occurs on
transition, Alt+Tab → 2-3s → Alt+Tab back.

---

## Build/Remove Cycle (Method 5)

The script grew from 212 to 967 lines through iterative problem-solving:
each new failure mode added handling code. Once root causes were found
(especially the broken driver), three systematic removal rounds reduced it
to 591 lines.

### What was built and then removed

| Feature | Lines | Why Built | Why Removed |
|---------|-------|-----------|-------------|
| 3-level GPU reset chain (MODE1→PCI→suspend) | ~100 | GPU left in dirty state after VM | Broken driver caused the dirty state |
| Bind-history TSV logging | ~40 | Track reset patterns across cycles | Same info in journald |
| Pre-VM GPU health check + reset | ~30 | Ensure GPU clean before VM start | GPU always clean with good driver |
| Degraded-mode iGPU fallback | ~30 | Continue without GPU if reset fails | Reset never needed now |
| PID affinity loops | ~40 | Pin all processes away from VM CPUs | libvirt cputune handles this |
| 120-line USB reattach diagnostics | ~120 | Debug USB re-enumeration timing | 2s sleep + 1 retry sufficient |
| Per-run log files + tee pattern | ~20 | Separate log per session | journald already captures this |
| navi31_reset kernel module | ~512 | Direct GPU register reset | Broken driver was the problem, not GPU hardware |
| VBIOS disassembler (atomdis.py) | ~747 | Reverse engineer GPU reset sequence | Same |

### How removal was structured

Three rounds, each verified with a clean VM cycle:

1. **Round 1**: Remove reset chain and fallback paths (967→831 lines)
2. **Round 2**: Remove diagnostics, bind logging, driver override tracking
   (831→629 lines)
3. **Round 3**: Remove PID affinity loops, iGPU blanking (later reverted),
   consolidate functions (629→591 lines)

The iGPU blanking removal in round 3 is instructive: the hypothesis that
"the monitor auto-switches inputs" was tested by removing the code, and
immediately falsified when the monitor stayed on HDMI. The code was restored
within minutes. **Test assumptions with reversible changes before committing
to them.**

---

## CPU Pinning: Frame Pacing vs Frame Rate (Observed 2026-03-02)

### Background

v2 was missing the `<cputune>` XML block that v1 had. The script's
`ensure_performance_tuning()` was already confining host processes via
`AllowedCPUs` and pinning IRQs to `HOST_CPUS`, but without `<cputune>` the
vCPU threads themselves floated freely across all 8 host cores. The host
scheduler could preempt any vCPU at any time to run host work.

### Effect of adding cputune

After adding `<cputune>` to pin vCPUs 0-5 to cores 2-7 (emulator/IO on
cores 0-1), the user immediately noticed smoother video without any change
in frame rate. This illustrates the difference between the two:

**Frame rate** — how many frames per second the GPU produces (e.g. 120 FPS).
A counter displays this; it's an average throughput measurement.

**Frame pacing** — how evenly those frames are spaced in time.

```
Good pacing (120 FPS):    |---|---|---|---|---|---|
Bad pacing (120 FPS avg): |--|----|--|----|--|----|
```

With floating vCPUs, the host scheduler would occasionally preempt a vCPU
mid-GPU-command-stream. The GPU starved briefly, then burst to catch up.
The average frame rate measured the same, but the uneven delivery was
perceptible as micro-stuttering. With pinned cores, the command stream flows
uninterrupted and frames arrive at even intervals.

### Boot slowdown trade-off

Applying `AllowedCPUs` immediately at VM start caused noticeably slower
Windows boot. The QEMU emulator thread (responsible for interrupt injection
into the guest) is confined to cores 0-1 by `AllowedCPUs`. During Windows
boot, there is a burst of driver initialization and service startup that
generates heavy interrupt traffic. Restricting the emulator thread to 2 cores
during this burst limits its throughput.

**Fix:** `apply_cpu_isolation()` runs as a background job and waits for the
guest agent to respond (indicating Windows has finished booting) before
applying `AllowedCPUs`. The emulator thread runs unconstrained during boot,
then gets pinned once steady-state gameplay begins. 120s fallback in case the
guest agent doesn't respond.

### Host RAM sizing and TDR (same session)

On the same day, the VM was over-allocated (88GiB on a 96GiB host), leaving
the host with ~6GiB. The resulting swap and kswapd CPU competition with VCPU
threads was the primary driver of VFIO passthrough TDR pressure — GPU stalls
causing `VidSchiCheckHwProgress` timeouts, OW2 crashes with "Rendering Device
Lost", and mid-match disconnections. Reducing to 48GiB/48GiB eliminated swap
entirely and reduced TDR crashes from multiple per session to rare blips.

**Lesson:** Over-provisioning guest RAM at the expense of host headroom is
counter-productive for GPU passthrough. The host kernel needs memory for
IOMMU structures and its VCPU scheduling threads. The guest's unused RAM does
nothing; the host's missing RAM causes real latency.

### TDR types that CPU pinning configuration can induce

Both issues above (missing `<cputune>` and immediate `AllowedCPUs`) can
produce WATCHDOG live kernel dumps. They have the same dump signature
(`P1:141` WATCHDOG + `P1:a1000001` AMD_WATCHDOG) but differ in *when* they
fire and what triggers them.

**Type 1 — Gameplay TDR (missing `<cputune>`)**

Without `<cputune>`, vCPU threads float across all host cores. The Linux
scheduler can preempt any vCPU at any point to run host work (kworker,
kswapd, IRQ handlers, GDM, etc.). If a vCPU is preempted while the GPU is
mid-pipeline (processing a draw call batch, waiting for fence signal), the
GPU stalls. If the stall exceeds the WDDM heartbeat window,
`dxgmms2!VidSchiCheckHwProgress` triggers engine reset → live dump. OW2
loses its DirectX device and crashes with "Rendering Device Lost".

This TDR is indistinguishable from a RAM-pressure TDR (kswapd VCPU
competition) based on the dump alone. Both produce the same
`VidSchiCheckHwProgress → VidSchiResetEngines` call stack. The distinguishing
factor is host memory state: if `swap > 0` or `HugePages_Free > 0` (pages
unallocated), RAM pressure is the more likely cause. If swap is zero and
pages are fully allocated, missing CPU pinning is more likely.

Fix: add `<cputune>` to VM XML with vCPUs pinned to dedicated cores and
emulator/IO thread on the remaining cores.

**Type 2 — Boot-time TDR (immediate `AllowedCPUs`)**

If `AllowedCPUs` is applied immediately when the VM starts (before Windows
boots), the QEMU emulator thread is confined to `HOST_CPUS` (cores 0-1)
during the entire boot sequence. The emulator thread is responsible for
injecting interrupts into the guest. During Windows boot, AMD GPU driver
initialization, Defender service init, and other heavy startup activity all
generate interrupt bursts simultaneously. With the emulator thread constrained
to 2 cores, it cannot keep up with the volume of interrupt delivery → interrupt
injection queues back up → AMD GPU driver stalls waiting for interrupt
acknowledgment → `VidSchiCheckHwProgress` fires → boot-time WATCHDOG TDR.

This produces the same dump signature as the pre-existing boot-time TDRs
documented in the "Boot-Time TDR Dumps" case study (Defender/AUEPMaster
contention). Immediate `AllowedCPUs` *adds to* that contention; it doesn't
create an entirely new failure mode. The practical effect: boot-time TDR
frequency increases when `AllowedCPUs` is applied immediately.

Fix: apply `AllowedCPUs` only after the guest agent responds (`apply_cpu_isolation()`
background function), so the emulator thread runs unconstrained during boot.

**Summary**

| TDR type | Timing | Trigger | Fix |
|---|---|---|---|
| Gameplay (missing cputune) | During active gameplay | vCPU preempted mid-GPU-pipeline | Add `<cputune>` XML block |
| Boot-time (immediate AllowedCPUs) | ~T+49s and T+78s after VM start | Emulator thread bottleneck during interrupt burst | Defer `AllowedCPUs` until guest-agent up |
| Boot-time (Defender/AMD contention) | Same window | Defender + AUEPMaster saturate CPUs during GPU driver init | Disable AUEPMaster; add Defender exclusions |

The boot-time types compound: all three can fire simultaneously during the
same ~30-second driver-init window, and any one of them is sufficient to
trigger a TDR dump.
