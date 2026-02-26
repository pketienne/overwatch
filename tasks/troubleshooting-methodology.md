# GPU Passthrough Troubleshooting Methodology

Lessons extracted from the full GPU passthrough project (Feb 20-24, 2026):
building a switchable RX 7900 XTX passthrough system on myhost with
vm-overwatch, from first `amd_iommu=on` through clean 24-second shutdown.

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
```

The script grew from 212 lines to 967 lines (building workarounds), then
shrank to 591 lines (removing them after root causes were found).

---

## Method 1: Instrument Before You Theorize

The single most productive troubleshooting pattern was adding measurement
before attempting fixes.

### Examples

**Shutdown timing**: Variable shutdown durations (10s vs 248s vs BSOD) were
impossible to reason about without data. A 15-line UDP listener + 4-line
PowerShell sender (`notify-host-shutdown.ps1`) gave exact millisecond
timestamps. This immediately revealed that the 104-second "clean" shutdown
after the ULPS fix was still pathologically slow — it wasn't fixed, just
masked.

**QEMU process state tracking**: During shutdown investigation, polling
`/proc/$qemu_pid/status` every 2 seconds revealed the S→D→exited transition
pattern. The D-state (disk sleep / VFIO teardown) duration directly measured
how long GPU release took. Without this, all you see is "VM stopped."

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

### The principle

**Never change two things at once. Always add measurement first.** If your
fix works, you'll know *why* it worked. If it doesn't, you'll have data for
the next hypothesis.

---

## Method 2: Trace the Actual Call Path

Most of the false starts came from fixing symptoms rather than causes. The
fix-for-the-cause always required tracing what the system was actually doing
at the point of failure.

### Example: 0x9F BSOD at Shutdown

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

### Example: i2c_del_adapter Hang

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

The lesson: **when the kernel hangs in D-state, the problem is almost always
a userspace process holding a resource the kernel needs to tear down.** Check
`fuser`, `lsof`, and `systemctl list-units` before assuming it's a kernel
bug.

---

## Method 3: Question the Environment, Not Just the Code

The most impactful discovery — that Windows Update silently installed a
broken AMD driver — came from *querying the guest OS's event history*, not
from reading vm-overwatch code or kernel logs.

### The investigation that found it

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

### The lesson

**When a system that was working stops working, the first question should be
"what changed in the environment?" before "what's wrong with the code?"**
Check for OS updates, driver changes, firmware updates, configuration drift.
The `Get-WinEvent` query that found the driver installation took 30 seconds.
The workaround infrastructure it replaced was ~350 lines of code built over
two days.

---

## Method 4: Layer-by-Layer Elimination

GPU passthrough sits at the intersection of many layers: BIOS/firmware,
IOMMU, Linux kernel, PCI subsystem, driver model, libvirt, QEMU, Windows
guest, guest drivers. Problems at one layer manifest as symptoms at another.

### Systematic approach used

**Firmware layer** (IOMMU identity mapping):
- Tools: `dmesg | grep iommu`, IVRS ACPI table dump, Python struct parsing
- Fix: Binary-patch the IVRS table, inject via GRUB CPIO initrd
- Lesson: BIOS vendors ship firmware tables that make assumptions about how
  the OS will use hardware. Those assumptions may be wrong for passthrough.

**Kernel layer** (runtime PM, driver probe order, i2c teardown):
- Tools: `/proc/PID/status`, `/proc/PID/stack`, `fuser`, `lsof`,
  `modprobe.d`, sysfs power attributes
- Fix: `amdgpu runpm=0`, immediate post-bind `power/control=on` writes
- Lesson: Driver probe and runtime PM operate on their own timelines. A
  udev rule fires before probe; the driver re-overrides during probe.
  Closing a race window means writing the fix *after* the driver acts, not
  before.

**Virtualization layer** (libvirt hooks, QEMU, vfio-pci):
- Tools: `virsh`, `qemu-agent-command`, hook scripts, systemd transient
  units
- Fix: No-op libvirt hook, wrapper script manages lifecycle externally
- Lesson: Libvirt hooks are synchronous and hold daemon locks. Never call
  `virsh` from inside a hook. Use an external orchestrator.

**Guest OS layer** (Windows power management, driver store, scheduled tasks):
- Tools: `Get-WinEvent`, `Get-PnpDevice`, `pnputil`, `powercfg`, `regedit`,
  `schtasks`
- Fix: High Performance plan, block WU GPU drivers, disable HDA audio device
- Lesson: Windows has multiple independent power management systems (OS
  power plan, PCI Express ASPM, driver-internal ULPS, HDAudBus codec power
  management). Fixing one doesn't fix the others.

### The principle

**When the symptom doesn't match the layer you're debugging, move up or down
a layer.** A BSOD in Windows (guest) caused by HDAudBus (guest driver)
sending an IRP to a codec behind vfio-pci (host) which can't respond because
the hardware (PCI function) is abstracted by IOMMU (firmware) — that's four
layers in one bug. The fix was at the guest layer (disable the device in
Windows), but the root cause understanding required traversing all four.

---

## Method 5: Build Incrementally, Then Remove Aggressively

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

### The principle

**Build workarounds as you go, but keep a mental ledger of technical debt.**
Every workaround should have a "this exists because..." comment. When the
root cause is found, walk the ledger and remove everything that was
compensating for it. The danger is leaving workaround code in place after the
need is gone — it adds complexity, obscures the real architecture, and
creates false confidence ("we handle that case").

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

## Method 6: Use the Guest Agent as a Remote Debugger

The QEMU guest agent (`qemu-ga`) turned the headless Windows VM into a
remotely queryable system. Nearly all Windows-side investigation was done
via `virsh qemu-agent-command` running PowerShell.

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

### The principle

**If you can run commands inside the guest, you can debug it like a local
machine.** The guest agent eliminates the need for RDP, SSH inside the VM,
or manual intervention. For a headless passthrough VM, it's the only
debugging interface when the display isn't working.

---

## Method 7: Correlate Timestamps Across Boundaries

Many bugs in this project crossed the host/guest boundary. The key to
understanding them was correlating timestamps between:

- **Host journald** (`journalctl -u vm-overwatch`) — script actions, driver
  bind/unbind, service start/stop
- **Host dmesg** — kernel messages for amdgpu, vfio-pci, PCI subsystem,
  i2c, soft lockups
- **Guest Event Viewer** — BSODs, driver installations, shutdown diagnostics
- **UDP shutdown signal** — exact guest shutdown initiation time
- **QEMU process state** — `/proc/PID/status` transitions (S→D→exited)

### Example: Audio D3cold Crash Timeline

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

### Example: Boot-Time TDR Dump Investigation

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

### The principle

**When a failure crosses system boundaries, build a unified timeline.** Use
epoch timestamps everywhere. Compare host kernel log timestamps with guest
event timestamps. The bug is usually in the *gap* between two systems'
actions.

---

## Method 8: Know When to Reboot

The SMU mailbox hang (`trn=2 ACK should not assert`) is a hardware-level
failure where no software reset restores the GPU. The only fix is a full
machine reboot. This happened 3+ times during the project.

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

### The principle

**Some failures are hardware-level and no amount of software gymnastics will
fix them.** Recognize the pattern (registers all-ones, D-state hangs,
mailbox timeouts), accept it, reboot, and move on. Time spent trying
software workarounds for a stuck SMU is time wasted. Document the boundary
between software-recoverable and reboot-required failures.

---

## Method 9: WinDbg and Crash Dump Analysis

WinDbg was used to trace the final shutdown BSOD root cause. The minidump
(`C:\Windows\Minidump\*.dmp`) from a 0x9F bugcheck contains the blocked
IRP, the faulting driver, and the call stack.

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

In this project, much of the analysis was done without WinDbg (it wasn't
installed in the VM initially):

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

Several entries in the troubleshooting reference started as "we observed X
but don't know why" and were later filled in:

- "GPU audio D3cold after VM passthrough" — initially noted as "sometimes
  crashes host," later traced to snd_hda_intel/D3cold interaction
- "SMU mailbox hang" — observed pattern (gaming triggers it, quick tests
  don't), root cause still not fully understood but boundary documented
- "Monitor doesn't auto-switch" — initially assumed it would, then
  discovered it doesn't, then built the iGPU blanking fix

### The principle

**Record observations even when you don't have an explanation.** Future you
(or future hardware) may encounter the same pattern. A documented "we saw X
after Y, no fix found, worked around with Z" is infinitely more useful than
no record at all.

---

## Anti-Patterns Observed

### 1. Fixing symptoms rather than causes

The 3-level GPU reset chain (MODE1→PCI bus reset→suspend/resume) was 100+
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

---

## Checklist for Future Hardware Passthrough Debugging

### Before you start
- [ ] What changed recently? (OS updates, driver updates, firmware, config)
- [ ] Can you reproduce reliably? How often?
- [ ] What's your measurement? (timestamps, logs, counters)

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
