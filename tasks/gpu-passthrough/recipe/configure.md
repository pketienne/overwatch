# Configure — Phases 10-14: Tuning and Integration

## Phase 10: Power Settings & AMD Driver Tuning

GPU passthrough devices are owned by vfio-pci on the host — the Windows guest driver cannot perform actual hardware power transitions. Windows power management causes **BSOD 0x9F (DRIVER_POWER_STATE_FAILURE)** when it sends power IRPs that the guest AMD driver can't complete.

**Required settings** (applied via `powercfg` through QEMU guest agent):

| Setting | Value | Why |
|---------|-------|-----|
| Power plan | **High Performance** (`8c5e7fda-...`) | Disables aggressive power management globally |
| PCI Express ASPM | **Off** (AC & DC) | ASPM tries to negotiate PCIe link power states — incompatible with vfio-pci passthrough. Primary crash trigger during gameplay. |
| USB selective suspend | **Disabled** (AC & DC) | Prevents Windows from sleeping passthrough USB devices |
| Display timeout | **Never** (0) | Prevents power IRPs to GPU for display-off transitions |
| Sleep after | **Never** (0) | Prevents full system sleep (which would freeze the VM) |
| Hybrid sleep | **Off** | Sleep would include hibernation prep, writing to passthrough disk |

```powershell
# Switch to High Performance
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
# Disable PCI Express ASPM
powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
# Disable USB selective suspend
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
# Disable display timeout
powercfg /setacvalueindex SCHEME_CURRENT 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0
powercfg /setdcvalueindex SCHEME_CURRENT 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0
# Disable sleep and hybrid sleep
powercfg /setacvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0
powercfg /setdcvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0
powercfg /setacvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0
powercfg /setdcvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0
powercfg /setactive SCHEME_CURRENT
```

### AMD Driver Internal Power Management

The AMD GPU driver has its own power management independent of the Windows power
plan. These must be disabled to prevent 0x9F BSODs during shutdown. The GPU is at
registry index `0001` (index `0000` is Microsoft Basic Display Adapter).

| Registry Value | Set To | Effect |
|---|---|---|
| `EnableUlps` | 0 | Disables Ultra Low Power State transitions |
| `PP_SclkDeepSleepDisable` | 1 | Prevents GPU clock deep sleep |
| `DisableDrmdmaPowerOff` | 1 | Prevents DRM DMA power-off |

```powershell
$regpath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001"
Set-ItemProperty -Path $regpath -Name EnableUlps -Value 0
Set-ItemProperty -Path $regpath -Name PP_SclkDeepSleepDisable -Value 1
Set-ItemProperty -Path $regpath -Name DisableDrmdmaPowerOff -Value 1
```

> **Note:** If Windows Update reinstalls the AMD driver, these values may be
> reset. Verify after any driver update.


## Phase 11: GPU HDA Audio

The GPU audio function (`03:00.1`) must be passed through to the VM (the AMD
driver fails with Code 43 without it), but the AMD HD Audio driver
(`AtiHDAudioService` / `oem39.inf`) caused PnP Driver Watchdog events on every
boot (>3s initialization timeout). Fix: uninstall the AMD audio driver package
and let Windows use the generic `High Definition Audio Device` driver instead.

```powershell
# Remove device, then delete driver from store
pnputil /remove-device "HDAUDIO\FUNC_01&VEN_1002&DEV_AA01&SUBSYS_00AA0100&REV_1008\5&1E9E0D5E&0&0001"
pnputil /delete-driver oem39.inf /force
```

After reboot, Windows binds the generic HD Audio driver — `Status: OK`,
no PnP watchdog events. HDMI/DP audio is unused (all audio goes through
the SteelSeries Arctis Pro Wireless headset via USB passthrough).

> **Note:** AMD Adrenalin driver updates may reinstall `AtiHDAudioService`.
> vm-overwatch boot diagnostics monitor for this (HD Audio section in logs).


## Phase 12: Defender & Telemetry

### Windows Defender Boot Contention (Intermittent TDR)

**Root cause:** Windows Defender *service initialization* (~12s heavy CPU at boot
for loading ~300MB definition databases, starting scan engines) creates CPU
contention during AMD GPU driver initialization, triggering
`VIDEO_DXGKRNL_LIVEDUMP` (0x1B0) WATCHDOG dumps. With Defender disabled, zero
dumps occur even at default TDR timeouts (TdrDelay=2, TdrDdiDelay=5).

**What doesn't work:**
- **DisableRealtimeMonitoring policy** — catch-22: requires Tamper Protection off
  to write, but with TP off, once RTP is disabled at boot it's sticky for the
  session (can't re-enable without reboot)
- **ScanAvgCPULoadFactor throttle** — only controls scheduled/on-demand scans,
  not real-time protection or service initialization CPU
- **C:\ path exclusion** — tested adding entire C:\ as exclusion; WATCHDOG dump
  still occurred. This proved the contention is from Defender's service
  initialization, not file scanning
- **Delaying/stopping WinDefend** — protected by 4 independent layers (WdBoot.sys
  ELAM, WdFilter.sys kernel minifilter, Tamper Protection, Protected Process
  Light). No viable way to delay, stop, or modify its startup with TP on.

**Current mitigations (reduce frequency, don't eliminate):**

Host-side CPU isolation (AllowedCPUs confines host to core 0, emulatorpin/iothreadpin
on core 0) reduces frequency to ~1 in 3 boots. See [CPU Isolation Architecture](setup.md#cpu-isolation-architecture)
for implementation details.

### Defender exclusions for AMD driver paths

These reduce real-time protection scanning of GPU driver files (doesn't fix boot
contention, but reduces runtime overhead):

```powershell
# Path exclusions
@("C:\Program Files\AMD",
  "C:\Windows\System32\amd*", "C:\Windows\SysWOW64\amd*",
  "C:\Windows\System32\ati*", "C:\Windows\SysWOW64\ati*",
  "C:\Windows\System32\drivers\amd*",
  "C:\Windows\System32\DriverStore\FileRepository\u0*"
) | ForEach-Object { Add-MpPreference -ExclusionPath $_ }

# Process exclusions
@("amdfendrsr.exe","atiesrxx.exe","atieclxx.exe","RadeonSoftware.exe",
  "AMDRSServ.exe","AMDRSSrcExt.exe","amdow.exe","cncmd.exe","CPUMetricsServer.exe"
) | ForEach-Object { Add-MpPreference -ExclusionProcess $_ }
```

> **Note:** Tamper Protection should be ON. Exclusions are not protected by
> Tamper Protection on standalone (non-domain) devices (`TPExclusions=0`).
> Defender real-time protection stays fully enabled. The DeferDefenderEnable
> scheduled task still exists but is effectively inert — it sets
> `ScanAvgCPULoadFactor` which only affects scheduled scans, not the boot-time
> service initialization that causes the contention.

### Disable AMD Telemetry (AUEPMaster)

AMD User Experience Program (AUEPMaster.exe) consumes 30-54s CPU during boot,
contributing to GPU init contention. It has two independent launch paths that
must both be disabled:

```powershell
# Disable the service
sc.exe config AUEPLauncher start=disabled

# Disable the scheduled task (this is the one that actually launches it)
Disable-ScheduledTask -TaskName StartAUEP
```

> **Note:** Disabling only the service is insufficient — AUEPMaster will still
> launch via the `\StartAUEP` scheduled task. Check both paths.


## Phase 13: Display Configuration

### Disable Auto HDR

Overwatch crashed on first launch with a runtime GPU TDR (WATCHDOG dump).
Windows Auto HDR (Event ID 4125) dynamically toggles HDR per-application,
causing display pipeline reconfiguration. During Overwatch's fullscreen + HDR
initialization, this mode switch triggers a GPU timeout at the default 2-second
TDR deadline. Second launch succeeds because the display is already configured.

Disable Auto HDR globally while keeping native HDR enabled:

```powershell
# Registry: HKU\<SID>\SOFTWARE\Microsoft\DirectX\UserGpuPreferences
# Set global AutoHDREnable=0 (HDR stays on natively, Auto HDR off)
# Remove any per-app Auto HDR overrides (e.g. Overwatch had AutoHDREnable=2097)
```

The registry path is per-user under `DirectXUserGlobalSettings`. The global
setting `SwapEffectUpgradeEnable=1;AutoHDREnable=0;` keeps HDR on but prevents
Windows from dynamically toggling it.

### Disable Game Bar

Xbox Game Bar shows Auto HDR recommendation toasts when launching games with HDR
available but Auto HDR disabled. Game Bar features (recording, overlay,
performance monitoring) are unnecessary in a VM.

```powershell
# Machine-wide policy
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord

# User settings
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "UseNexusForGameBarEnabled" -Value 0 -Type DWord
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord
```

### Disable Auto HDR system toast notification

Even with Game Bar disabled, Windows shows an Auto HDR recommendation toast via
the system notification `Windows.SystemToast.Graphics.AutoHDR`. This is a
separate notification source from Game Bar.

```powershell
# Per-user notification setting (use HKU\<SID> for guest agent, HKCU for interactive)
$path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Graphics.AutoHDR"
New-Item -Path $path -Force
Set-ItemProperty -Path $path -Name "Enabled" -Value 0 -Type DWord
```


## Phase 14: Shutdown Signal

vm-overwatch listens on UDP port 9147 for a shutdown timing signal from the guest. A Windows scheduled task fires on any shutdown (Event ID 1074) and sends the signal automatically — no manual `.bat` shortcut needed.

Install the notification script:
```powershell
mkdir C:\ProgramData\vm-overwatch -Force
```

Copy `scripts/notify-host-shutdown.ps1` from this repo to `C:\ProgramData\vm-overwatch\notify-host-shutdown.ps1`. Contents:
```powershell
$udp = New-Object System.Net.Sockets.UdpClient
$bytes = [System.Text.Encoding]::ASCII.GetBytes("shutdown")
$udp.Send($bytes, $bytes.Length, "192.168.0.100", 9147)
$udp.Close()
```

Create the scheduled task (run in an elevated PowerShell):
```powershell
$trigger = New-ScheduledTaskTrigger -AtStartup  # placeholder, replaced by EventTrigger below
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\vm-overwatch\notify-host-shutdown.ps1"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "NotifyHostShutdown" -Action $action -Principal $principal -Force

# Set the trigger to Event ID 1074 (system shutdown initiated)
$task = Get-ScheduledTask -TaskName "NotifyHostShutdown"
$task.Triggers = @(
    $(New-Object Microsoft.PowerShell.Cmdletization.GeneratedTypes.ScheduledTask.CimTrigger)
)
# Use schtasks for the event trigger (PowerShell cmdlets don't support event triggers natively)
schtasks /Change /TN "NotifyHostShutdown" /XML (
    [xml]@"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0"&gt;&lt;Select Path="System"&gt;*[System[EventID=1074]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\vm-overwatch\notify-host-shutdown.ps1</Arguments>
    </Exec>
  </Actions>
  <Principals><Principal><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><Enabled>true</Enabled><AllowStartIfOnBatteries>true</AllowStartIfOnBatteries></Settings>
</Task>
"@ | Out-File "$env:TEMP\nhs.xml" -Encoding Unicode; "$env:TEMP\nhs.xml")
```

Or more simply, create the task via Task Scheduler GUI: trigger on Event Log `System`, Event ID `1074`, action runs the PowerShell script as SYSTEM.
