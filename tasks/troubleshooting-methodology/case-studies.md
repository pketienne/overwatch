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
PowerShell sender (`notify-host-shutdown.ps1`) gave exact millisecond
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
T+0.0s  vm-overwatch: "Binding amdgpu..."
T+0.2s  dmesg: amdgpu probed successfully
T+0.3s  vm-overwatch: "Re-enumerating GPU audio..."
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
