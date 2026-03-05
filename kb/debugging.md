# Debugging

Principles, case studies, and stress tests from the GPU passthrough project.
For a generalized version of the principles, see `nerv/debugging-principles.md`.

---

# Principles

10 methods distilled from the project, plus 7 anti-patterns.
Each method links to its [case study](#case-studies) for the full investigation.

---

## Method 1: Instrument Before You Theorize

**Never change two things at once. Always add measurement first.** If your
fix works, you'll know *why* it worked. If it doesn't, you'll have data for
the next hypothesis.

The single most productive pattern was adding measurement before attempting
fixes. See [Shutdown timing instrumentation](#shutdown-timing-instrumentation-method-1)
for the UDP listener, QEMU process state tracking, Win diagnostics events,
and bind-history TSV that made every subsequent investigation possible.

---

## Method 2: Trace the Actual Call Path

**When the kernel hangs in D-state,
the problem is almost always a userspace process holding a resource the
kernel needs to tear down.** Check `fuser`,
`lsof`, and `systemctl list-units` before assuming it's a kernel bug.

Most false starts came from fixing symptoms rather than causes. The
fix-for-the-cause always required tracing what the system was actually doing
at the point of failure. See [0x9F BSOD at Shutdown](#0x9f-bsod-at-shutdown-method-2)
and [i2c_del_adapter Hang](#i2c_del_adapter-hang-method-2).

---

## Method 3: Question the Environment, Not Just the Code

**When a system that was working stops working, the first question should be
"what changed in the environment?" before "what's wrong with the code?"**
Check for OS updates, driver changes, firmware updates, configuration drift.

The most impactful discovery — that Windows Update silently installed a
broken AMD driver — came from querying the guest OS's event history, not from
reading overwatch code or kernel logs. See
[Broken AMD Driver](#broken-amd-driver-method-3).

---

## Method 4: Layer-by-Layer Elimination

**When the symptom doesn't match the layer you're debugging,
move up or down a layer.** A BSOD in Windows (guest) caused by HDAudBus (guest driver)
sending an IRP to a codec behind vfio-pci (host) which can't respond because
the hardware (PCI function) is abstracted by IOMMU (firmware) — that's four
layers in one bug. The fix was at the guest layer (disable the device in
Windows), but the root cause understanding required traversing all four.

GPU passthrough sits at the intersection of many layers. Problems at one
layer manifest as symptoms at another.

| Layer | Tools | Example Fix |
|-------|-------|-------------|
| **Firmware** (IOMMU identity mapping) | `dmesg \| grep iommu`, ACPI table inspection | Enable IOMMU explicitly in BIOS (not Auto) |
| **Kernel** (runtime PM, driver probe, i2c) | `/proc/PID/status`, `/proc/PID/stack`, `fuser`, `lsof`, `modprobe.d`, sysfs power attributes | `amdgpu runpm=0`, post-bind `power/control=on` writes |
| **Virtualization** (libvirt hooks, QEMU, vfio-pci) | `virsh`, `qemu-agent-command`, hook scripts, systemd transient units | No-op libvirt hook, external orchestrator |
| **Guest OS** (Windows power mgmt, driver store, tasks) | `Get-WinEvent`, `Get-PnpDevice`, `pnputil`, `powercfg`, `regedit`, `schtasks` | High Performance plan, block WU GPU drivers, disable HDA audio |

Key lessons per layer:
- **Firmware**: BIOS vendors ship firmware tables that make assumptions about
  how the OS will use hardware. Those assumptions may be wrong for passthrough.
- **Kernel**: Driver probe and runtime PM operate on their own timelines. A
  udev rule fires before probe; the driver re-overrides during probe.
  Closing a race window means writing the fix *after* the driver acts, not
  before.
- **Virtualization**: Libvirt hooks are synchronous and hold daemon locks.
  Never call `virsh` from inside a hook. Use an external orchestrator.
- **Guest OS**: Windows has multiple independent power management systems (OS
  power plan, PCI Express ASPM, driver-internal ULPS, HDAudBus codec power
  management). Fixing one doesn't fix the others.

---

## Method 5: Build Incrementally, Then Remove Aggressively

**Build workarounds as you go, but keep a mental ledger of technical debt.**
Every workaround should have a "this exists because..." comment. When the
root cause is found, walk the ledger and remove everything that was
compensating for it. The danger is leaving workaround code in place after the
need is gone — it adds complexity, obscures the real architecture, and
creates false confidence ("we handle that case").

See [Build/Remove Cycle](#buildremove-cycle-method-5) for the
full table of features built and removed, plus the three structured removal
rounds.

---

## Method 6: Use the Guest Agent as a Remote Debugger

**If you can run commands inside the guest, you can debug it like a local
machine.** The guest agent eliminates the need for RDP, SSH inside the VM,
or manual intervention. For a headless passthrough VM,
it's the only debugging interface when the display isn't working.

### What was queried through the guest agent

- `Get-WinEvent` — BSOD history (BugcheckCode, Parameters), driver
  installation timeline, shutdown diagnostics
- `Get-PnpDevice` — device status, instance IDs, driver versions
- `pnputil` — driver store inventory, driver package removal, device
  disable
- `powercfg` — power plan queries and modifications
- Registry reads/writes — AMD driver ULPS settings
- `Get-CimInstance Win32_OperatingSystem` — last boot time, system state
- File operations — checking for minidumps, WER reports

### Escaping

The most painful part was JSON escaping for `virsh qemu-agent-command`. The
working pattern:

```bash
ssh myhost 'sudo virsh qemu-agent-command overwatch '"'"'{
  "execute": "guest-exec",
  "arguments": {
    "path": "powershell.exe",
    "arg": ["-NoProfile", "-Command", "..."],
    "capture-output": true
  }
}'"'"''
```

The `'"'"'` pattern (end single quote, double-quoted single quote, resume
single quote) avoids bash/JSON/PowerShell triple-escaping.

---

## Method 7: Correlate Timestamps Across Boundaries

**When a failure crosses system boundaries, build a unified timeline.** Use
epoch timestamps everywhere. Compare host kernel log timestamps with guest
event timestamps. The bug is usually in the *gap* between two systems'
actions.

Many bugs in this project crossed the host/guest boundary. Correlate
timestamps between:

- **Host journald** (`journalctl -u overwatch`) — script actions, driver
  bind/unbind, service start/stop
- **Host dmesg** — kernel messages for amdgpu, vfio-pci, PCI subsystem,
  i2c, soft lockups
- **Guest Event Viewer** — BSODs, driver installations, shutdown diagnostics
- **UDP shutdown signal** — exact guest shutdown initiation time
- **QEMU process state** — `/proc/PID/status` transitions (S->D->exited)

See [Audio D3cold Crash](#audio-d3cold-crash-method-7) and
[Boot-Time TDR Dumps](#boot-time-tdr-dumps-method-7) for
detailed cross-boundary timeline analyses.

---

## Method 8: Know When to Reboot

**Some failures are hardware-level and no amount of software gymnastics will
fix them.** Recognize the pattern (registers all-ones, D-state hangs,
mailbox timeouts), accept it, reboot, and move on. Time spent trying
software workarounds for a stuck SMU is time wasted. Document the boundary
between software-recoverable and reboot-required failures.

### Symptoms that mean "reboot, don't debug"

- amdgpu bind hangs indefinitely (D-state, `amdgpu_device_init` in stack)
- GPU registers read as `0xffffffff` after a previous VM session
- `dmesg` shows repeated SMU mailbox timeout messages
- PCI config space reads fail or return all-ones

### What doesn't work

- PCI bus reset (`echo 1 > /sys/bus/pci/devices/.../reset`)
- PCI remove + rescan
- Suspend/resume
- The custom navi31_reset kernel module
- Any combination of the above

---

## Method 9: WinDbg and Crash Dump Analysis

WinDbg was used to trace the final shutdown BSOD root cause. The minidump
(`C:\Windows\Minidump\*.dmp`) from a 0x9F bugcheck contains the blocked
IRP, the faulting driver, and the call stack.

### When to reach for WinDbg

- You have a consistent BSOD bugcheck code
- Event Viewer shows the bugcheck parameters but not the root cause
- String-scanning minidumps isn't precise enough (multiple drivers present)
- You need the actual blocked IRP / call stack / device object

### Practical notes

- Install WinDbg from the Windows SDK or Microsoft Store
- Point it at the minidump: `File > Open Crash Dump > C:\Windows\Minidump\*.dmp`
- `!analyze -v` gives the full analysis including the blocked thread
- For 0x9F specifically, Parameter4 points to `TRIAGE_9F_POWER` which
  contains the blocked IRP and its target device
- Symbol server: `srv*C:\Symbols*https://msdl.microsoft.com/download/symbols`

### Alternative when WinDbg isn't available

- `Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001}` for bugcheck
  parameters
- `Get-CimInstance -ClassName Win32_ReliabilityRecords` for BSOD history
- String-scanning minidump binaries (`strings *.dmp | grep -i driver`) for
  driver names present at crash time
- WER archive (`C:\ProgramData\Microsoft\Windows\WER\`) for crash metadata

These got us to "it's a power IRP timeout" and "AMD/HDA drivers are
involved" but couldn't pinpoint the exact function or IRP target. WinDbg
was the tool that closed the loop.

---

## Method 10: Document What You Don't Understand Yet

**Record observations even when you don't have an explanation.** Future you
(or future hardware) may encounter the same pattern. A documented "we saw X
after Y, no fix found, worked around with Z" is infinitely more useful than
no record at all.

Several entries in the troubleshooting reference started as "we observed X
but don't know why" and were later filled in:

- "GPU audio D3cold after VM passthrough" — initially noted as "sometimes
  crashes host," later traced to snd_hda_intel/D3cold interaction
- "SMU mailbox hang" — observed pattern (gaming triggers it, quick tests
  don't), root cause still not fully understood but boundary documented
- "Monitor doesn't auto-switch" — initially assumed it would, then
  discovered it doesn't, then built the iGPU blanking fix

---

## Anti-Patterns Observed

### 1. Fixing symptoms rather than causes

The 3-level GPU reset chain (MODE1->PCI bus reset->suspend/resume) was 100+
lines of code that perfectly handled the *symptom* (GPU in dirty state) of
the *cause* (broken AMD driver). Once the cause was found, all 100 lines
were deleted.

### 2. Assuming the OS is static

Windows Update silently installed a driver that broke everything. Three days
of debugging went into building workarounds before anyone checked what
Windows had installed. The `Get-WinEvent` query that found it took 30
seconds.

### 3. Fighting the kernel in D-state

Multiple attempts to `timeout`, `kill -9`, or otherwise interrupt D-state
kernel hangs. D-state is uninterruptible by design. The fix is always to
prevent the condition that causes the hang, never to interrupt it after it
starts.

### 4. Over-engineering before understanding

The VBIOS disassembler (747 lines), the navi31_reset kernel module (512
lines), and the register reference document (352 lines) — all built to
solve a GPU reset problem that turned out to be caused by a bad driver.
These were impressive technical work but didn't survive contact with the
actual root cause.

### 5. Removing code without testing the assumption

The iGPU blanking removal assumed the monitor would auto-switch. It didn't.
The code had to be restored. Always test assumptions with reversible changes.

### 6. Assuming one disable path is sufficient (Windows)

AMD's AUEPMaster telemetry process had two independent launch paths: the
`AUEPLauncher` Windows service *and* a `\StartAUEP` scheduled task. Disabling
the service via `sc.exe config AUEPLauncher start=disabled` appeared to work
— the service was confirmed Disabled/Stopped — but AUEPMaster kept appearing
every boot with 30+ seconds of CPU usage.

The fix was also disabling the scheduled task:
`Disable-ScheduledTask -TaskName StartAUEP`.

**When disabling a Windows component, check all launch paths:** services
(`Get-Service`), scheduled tasks (`Get-ScheduledTask`), startup folder,
`Run`/`RunOnce` registry keys, and COM surrogate registrations. AMD software
in particular uses multiple redundant launch mechanisms.

### 7. Verifying a stateful fix in a single cycle

The Windows Defender boot deferral used a registry policy
(`DisableRealtimeMonitoring=1`) to suppress real-time scanning during GPU init.
The `DeferDefenderEnable.ps1` script re-enabled Defender after 90 seconds by
deleting the registry key with `Remove-Item`. This passed the test cycle — zero
WATCHDOG dumps, Defender confirmed active afterward.

But the fix was a one-shot: `Remove-Item` destroyed the policy key entirely, so
the next boot had no policy in place. Defender started at full speed, GPU TDR
dumps returned. The bug survived across 4+ boots before being caught.

The fix was trivial: toggle the value (set to 0, restart WinDefend, set back to
1) instead of deleting the key. The policy stays armed at rest and only flips
briefly during the re-enable window.

**Any fix that modifies persistent state (registry, config files, scheduled
tasks) must be tested across at least two full cycles.** A single-cycle test
only proves the fix works *once* — it says nothing about whether the fix
re-arms itself for the next invocation.

---

# Case Studies

Detailed investigations from the project. Each names the principle it illustrates.

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
seconds revealed the S->D->exited transition pattern. The D-state (disk sleep /
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
- The power transition: D0->D1 (power-down)
- The device: GPU's HDA audio codec

---

## i2c_del_adapter Hang (Method 2)

The amdgpu unbind hung in D-state, requiring hard power cycles. Attempts to
fix it:

1. `fuser -k /dev/dri/card1` -> killed GNOME Shell, killed the terminal,
   killed the script
2. `modprobe -r amdgpu` -> can't unload, iGPU also uses it
3. PCI remove -> same hang, same i2c code path
4. `timeout` on sysfs unbind -> D-state processes are unkillable
5. Force DP connectors off via sysfs -> didn't help

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
amdgpu_pci_remove          <- triggered by sysfs unbind
```

### Root cause

`drm_fb_helper` has a `damage_work` worker that blits the shadow framebuffer
to VRAM (`drm_fb_helper_damage_work` -> `drm_fbdev_ttm_damage_blit`). During
driver removal, `drm_fb_helper_fini` calls `cancel_work_sync(&damage_work)`
to wait for any in-flight work to complete. But the work was already running
and trying to access GPU VRAM via TTM buffer mapping — the GPU hardware was
being torn down concurrently by `amdgpu_pci_remove`, so the buffer operation
hung on dead hardware. `cancel_work_sync` waited forever.

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
  dxgmms2!VidSchiCheckHwProgress+0x316   <- GPU scheduler: no progress detected
  dxgmms2!VidSchiResetEngines+0xea       <- engine reset initiated
  dxgmms2!VidSchiResetEngine+0x36e
  dxgkrnl!TdrCollectDbgInfoStage1+0xd69
  nt!DbgkWerCaptureLiveKernelDump        <- live dump captured here
```

### What this means

`dxgmms2!VidSchiCheckHwProgress` is the WDDM GPU scheduler's heartbeat check:
it periodically verifies the GPU is making forward progress on submitted
commands. When it detects a stall, it triggers `VidSchiResetEngines` ->
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

---

## AtihdWT6 Reinstated by Driver Update (2026-03-03)

After updating to AMD driver **32.0.23027.2005**, the driver installer re-added
`atihdwt6.inf` to the driver store and re-enabled the AMD HD Audio device.
WinDbg confirmed AtihdWT6.sys was loaded during TDR events. The permanent fix
is Device Installation Restrictions policy — blocks PnP from binding any driver
to the hardware ID regardless of what is in the driver store.

Post-removal confirmation: a new crash at 15:02 had an identical FAILURE_ID_HASH,
proving AtihdWT6 was not the primary TDR cause. The audio driver removal is
correct hygiene (prevents 0x9F shutdown BSODs) but doesn't prevent gameplay TDRs.

The confirmed behavioral pattern: the transition freeze is **deterministic when
OW2 is backgrounded** (alt-tabbed). Background FPS limit -> max load spike
overwhelms VFIO. Foreground transitions sometimes work; hiccups are recoverable
via Alt+Tab -> 2-3s -> Alt+Tab back.

---

## Build/Remove Cycle (Method 5)

The script grew from 212 to 967 lines through iterative problem-solving:
each new failure mode added handling code. Once root causes were found
(especially the broken driver), three systematic removal rounds reduced it
to 591 lines.

### What was built and then removed

| Feature | Lines | Why Built | Why Removed |
|---------|-------|-----------|-------------|
| 3-level GPU reset chain (MODE1->PCI->suspend) | ~100 | GPU left in dirty state after VM | Broken driver caused the dirty state |
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

1. **Round 1**: Remove reset chain and fallback paths (967->831 lines)
2. **Round 2**: Remove diagnostics, bind logging, driver override tracking
   (831->629 lines)
3. **Round 3**: Remove PID affinity loops, iGPU blanking (later reverted),
   consolidate functions (629->591 lines)

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

| TDR type | Timing | Trigger | Fix |
|---|---|---|---|
| Gameplay (missing cputune) | During active gameplay | vCPU preempted mid-GPU-pipeline | Add `<cputune>` XML block |
| Boot-time (immediate AllowedCPUs) | ~T+49s and T+78s after VM start | Emulator thread bottleneck during interrupt burst | Defer `AllowedCPUs` until guest-agent up |
| Boot-time (Defender/AMD contention) | Same window | Defender + AUEPMaster saturate CPUs during GPU driver init | Disable AUEPMaster; add Defender exclusions |

The boot-time types compound: all three can fire simultaneously during the
same ~30-second driver-init window, and any one of them is sufficient to
trigger a TDR dump.

### VFIO performance tuning (implemented)

Three-layer kernel CPU isolation, applied via GRUB params in the cookbook:

- `isolcpus=domain,managed_irq,2-7`: removes cores 2-7 from scheduler load
  balancing and prevents managed PCIe interrupts from landing there
- `nohz_full=2-7`: disables the 250Hz periodic timer tick on vCPU cores when
  only one task is running — eliminates 4ms periodic interruptions
- `rcu_nocbs=2-7`: moves RCU callbacks off those cores to a dedicated kthread

Runtime tuning in overwatch.sh:
- C-state cap: vCPU cores capped at C1 (no deep C-state wakeup latency)
- Scheduler autogroup disabled (prevents TTY-based throughput grouping for QEMU)
- Both restored on VM stop

---

## PCIe Bus Reset for GPU Rebind

After VFIO releases the GPU, binding amdgpu directly with no hardware reset
leaves the GPU in whatever state the Windows guest left it — firmware state
machines running, command queues initialized, display engine in guest mode.
amdgpu tries to initialize on top of this dirty state, causing SMU mailbox
hangs, MES KIQ soft lockups, and VCN suspend hangs.

**Fix:** Issue a PCIe Secondary Bus Reset (SBR) after vfio-pci unbind but
before amdgpu bind. The RX 7900 XTX does not support FLR — SBR is the only
available reset method. It resets both `03:00.0` and `03:00.1` via the PCIe
link, which also eliminated the need for PCI remove/rescan of the audio
device (confirmed: `snd_hda_intel` binds cleanly after SBR with a direct bind).

---

## Runtime Performance Monitoring

Two background monitoring subsystems were added to overwatch.sh:

**Host-side (`PERF_HOST`)**: Samples every 30s during VM runtime via
`mpstat`, `iostat`, `/proc/meminfo`. Logs per-core CPU load (only cores
>50%), NVMe latency/utilization, free/available memory, swap usage.

**Guest-side (`PERF_GUEST`)**: Samples every 60s via QEMU guest agent +
LibreHardwareMonitor WMI. Logs GPU core load, temps (core/hotspot/memory),
clocks, package power, VRAM used/total.

Both launched in `_do_start()`, killed on shutdown. Searchable via
`journalctl -u overwatch | grep PERF_HOST` or `PERF_GUEST`.

---

# Stress Testing

Synthetic loads for reproducing failure modes without needing a game session.
If a stress test produces the same failure, the failure is in the VM stack,
not the game.

---

## 1. GPU TDR Stability (FurMark or Unigine Heaven, inside VM)

**What it tests:** Whether the GPU passthrough configuration can sustain
maximum GPU load without triggering `VidSchiCheckHwProgress` timeouts.

**Setup:** FurMark from `geeks3d.com` (explicit GPU stress) or Unigine
Heaven from `benchmark.unigine.com` (game-like workload).

**Procedure:** Start the VM, launch the benchmark, run for 15 minutes.
Check for new TDR dumps:

```powershell
Get-ChildItem C:\Windows\LiveKernelReports\WATCHDOG\ |
    Sort-Object LastWriteTime | Select-Object -Last 5 Name,LastWriteTime
```

| Outcome | Conclusion |
|---|---|
| Clean run, no dumps | GPU passthrough is stable; game crashes are server/network |
| Dump within 5 min | GPU config is unstable; check huge pages, graphics settings |
| Dump after 10+ min | Marginal stability; likely thermal or power delivery |

**If dumps occur:** Verify `HugePages_Free = 0` on host, lower resolution,
try newer driver, check host swap is zero.

---

## 2. VCPU Scheduling Pressure (stress-ng on host cores 0-1)

**What it tests:** Whether the CPU isolation is robust — specifically,
whether the QEMU emulator thread competing for cores 0-1 can cause frame
stalls or TDRs in the guest.

**Procedure:** Run on the host while actively gaming:

```bash
sudo stress-ng --cpu 2 --taskset 0,1 --cpu-method matrixprod \
    --metrics-brief --timeout 120s
```

Monitor with `mpstat -P ALL 1` (cores 0-1 should be ~100%, cores 2-7
showing normal guest load) and `virsh vcpuinfo overwatch` (vCPUs should
stay pinned).

| Guest behavior during stress | Conclusion |
|---|---|
| No blips, smooth gameplay | CPU isolation is robust; emulator thread on 2 cores is sufficient |
| Blips correlate with stress window | Emulator thread is a bottleneck; interrupt injection is latency-sensitive |
| TDR dump generated | Core 0-1 saturation causes full WDDM timeout; emulator needs more headroom |

---

## 3. Host Memory Pressure (observation only)

**Status: fixed.** VM RAM reduced from 88GiB to 48GiB, eliminating swap.
**Do not reproduce** by reducing hugepages — this restores a known-bad state.

If you suspect memory pressure has returned:

```bash
free -h                          # swap > 0 means pressure is back
grep HugePages_Free /proc/meminfo # should be 0 after VM starts
top -d1 -p $(pgrep kswapd)       # any sustained CPU% is bad
```

Expected healthy state: zero swap, all 24,576 huge pages allocated, kswapd
idle.
