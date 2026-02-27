# Troubleshooting Principles

10 methods distilled from the GPU passthrough project, plus 7 anti-patterns.
Each method links to its detailed [case study](case-studies.md) for the full
investigation narrative.

---

## Method 1: Instrument Before You Theorize

**Never change two things at once. Always add measurement first.** If your
fix works, you'll know *why* it worked. If it doesn't, you'll have data for
the next hypothesis.

The single most productive pattern was adding measurement before attempting
fixes. See [Shutdown timing instrumentation](case-studies.md#shutdown-timing-instrumentation-method-1)
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
at the point of failure. See [0x9F BSOD at Shutdown](case-studies.md#0x9f-bsod-at-shutdown-method-2)
and [i2c_del_adapter Hang](case-studies.md#i2c_del_adapter-hang-method-2).

---

## Method 3: Question the Environment, Not Just the Code

**When a system that was working stops working, the first question should be
"what changed in the environment?" before "what's wrong with the code?"**
Check for OS updates, driver changes, firmware updates, configuration drift.

The most impactful discovery — that Windows Update silently installed a
broken AMD driver — came from querying the guest OS's event history, not from
reading overwatch code or kernel logs. See
[Broken AMD Driver](case-studies.md#broken-amd-driver-method-3).

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
| **Firmware** (IOMMU identity mapping) | `dmesg \| grep iommu`, IVRS ACPI table dump, Python struct parsing | Binary-patch IVRS table, inject via GRUB CPIO initrd |
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

See [Build/Remove Cycle](case-studies.md#buildremove-cycle-method-5) for the
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
- **QEMU process state** — `/proc/PID/status` transitions (S→D→exited)

See [Audio D3cold Crash](case-studies.md#audio-d3cold-crash-method-7) and
[Boot-Time TDR Dumps](case-studies.md#boot-time-tdr-dumps-method-7) for
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
