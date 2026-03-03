# Debugging Checklists

Quick-reference checklists for hardware passthrough debugging. For the
reasoning behind each item, see [principles](principles.md) and
[case studies](case-studies.md).

---

## Before you start
- [ ] **Verify Tamper Protection is ON** (`TamperProtection=0x5` in `HKLM\SOFTWARE\Microsoft\Windows Defender\Features`). Never disable it
- [ ] What changed recently? (OS updates, driver updates, firmware, config)
- [ ] Can you reproduce reliably? How often?
- [ ] What's your measurement? (timestamps, logs, counters)
- [ ] If a guest app seems to have stopped running but its devices/services still work: check Windows notification area settings (Settings → Personalization → Taskbar → Other system tray icons) before assuming a process crash — Windows auto-hides tray icons for apps that fail to register cleanly

## For BSOD / guest crashes
- [ ] Check `Get-WinEvent` for bugcheck parameters (Id=1001)
- [ ] Check `Get-WinEvent` for recent driver installations
- [ ] Check power plan settings (`powercfg /getactivescheme`)
- [ ] Check AMD driver registry values (ULPS, ASPM)
- [ ] If consistent bugcheck: get minidump, run WinDbg `!analyze -v`
- [ ] Correlate BSOD timing with host dmesg timestamps

## For host hangs (D-state, soft lockup)
- [ ] Check `/proc/PID/stack` for the blocked function
- [ ] Check `fuser` and `lsof` for all device nodes the driver manages
- [ ] Check `systemctl list-units` for services holding device FDs
- [ ] Check runtime PM state (`cat power/runtime_status`)
- [ ] If `i2c_del_adapter`: something holds i2c FDs (OpenRGB, DDC tools)
- [ ] If registers read `0xffffffff`: hardware failure, reboot required

## For "no display" after VM start/stop
- [ ] Is the GPU on the right driver? (`readlink /sys/bus/pci/devices/.../driver`)
- [ ] Is the monitor input correct? (iGPU blanked? DP signal present?)
- [ ] Guest device manager: is the GPU in Error state? (Code 43 = missing
  multifunction peer; Code 10 = driver failed to start)
- [ ] Did both PCI functions (GPU + audio) get passed through?

## For live kernel dumps (WATCHDOG / VIDEO_DXGKRNL_LIVEDUMP)
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

## For game disconnects / lost connection to server

- [ ] Check NET_HOST logs: `journalctl -u overwatch | grep "NET_HOST TRAFFIC\|NET_HOST DROPS"` — if `TRAFFIC_IDLE` appears without `DROPS`, the disconnect is upstream of the host (Blizzard or game client), not a network issue
- [ ] If no drops: check Battle.net logs at `C:\Users\myuser\AppData\Local\Battle.net\Logs\` for `BNPresence ERROR_INTERNAL` — presence subscription failure causes disconnects regardless of network quality
- [ ] If BNPresence errors found: close Battle.net, delete `C:\Users\myuser\AppData\Local\Battle.net\Cache`, relaunch (in-app "Clear Cache" was removed from newer client versions — delete manually)
- [ ] Check whether Battle.net auto-updated during the last host reboot by comparing log file timestamps with reboot time

## For performance / timing issues
- [ ] Add measurement before adding fixes
- [ ] Instrument the shutdown path (UDP signal + process state tracking)
- [ ] Query Windows Diagnostics-Performance events (IDs 200-203)
- [ ] Check for udev/driver race conditions (probe overriding sysfs writes)

## After fixing
- [ ] Remove workaround code that targeted symptoms, not root cause
- [ ] Update documentation with the actual root cause and fix
- [ ] Test the "it works without the workaround" hypothesis
- [ ] Record the failure pattern for future reference even if you don't
  fully understand it
