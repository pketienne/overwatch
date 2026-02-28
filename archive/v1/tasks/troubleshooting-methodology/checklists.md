# Debugging Checklists

Quick-reference checklists for hardware passthrough debugging. For the
reasoning behind each item, see [principles](principles.md) and
[case studies](case-studies.md).

---

## Before you start
- [ ] **Verify Tamper Protection is ON** (`TamperProtection=0x5` in `HKLM\SOFTWARE\Microsoft\Windows Defender\Features`). Never disable it — see [Phase 12](../gpu-passthrough/recipe/configure.md#phase-12-defender--telemetry)
- [ ] What changed recently? (OS updates, driver updates, firmware, config)
- [ ] Can you reproduce reliably? How often?
- [ ] What's your measurement? (timestamps, logs, counters)

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
