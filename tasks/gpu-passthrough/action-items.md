# Action Items

## 1. Add PCIe bus reset before amdgpu rebind

**Status:** Implemented (`gpu_bus_reset()` in vm-overwatch.sh, called from `ensure_gpu_on_host()`)

**Problem:** After VFIO releases the GPU, `ensure_gpu_on_host()` binds amdgpu
directly with no hardware reset. The GPU is still in whatever state the Windows
guest left it — firmware state machines running, command queues initialized,
display engine in guest mode. amdgpu tries to initialize on top of this dirty
state, and the firmware (SMU, MES, VCN) is sometimes unresponsive, causing:

- SMU mailbox hang (`trn=2 ACK should not assert` — boot -4, 2026-02-24)
- MES KIQ dequeue soft lockup during `amdgpu_pci_remove` (boot -3, 2026-02-24)
- VCN suspend hang during GPU reset after `amdgpu_job_timedout` (boot -2, 2026-02-24)

**Fix:** Issue a PCIe bus reset after vfio-pci unbind but before amdgpu bind in
`ensure_gpu_on_host()`:

```bash
echo 1 > /sys/bus/pci/devices/$GPU/reset
sleep 1
```

This resets the GPU hardware to power-on state before the driver touches it. The
RX 7900 XTX does not support FLR (`FLReset-` in PCIe DevCap register) — the
only available reset method is Secondary Bus Reset (SBR), which resets both
`03:00.0` and `03:00.1` via the PCIe link.

**Note:** Since the bus reset hits both functions, the audio device also returns
to a clean power state. This eliminated the need for PCI remove/rescan of
`03:00.1` — confirmed in Action Item 2.

## 2. Test removing PCI remove/rescan for GPU audio after bus reset

**Status:** Done — direct bind works, remove/rescan deleted

**Problem:** `ensure_gpu_on_host()` previously did a PCI remove + full bus rescan
on `03:00.1` to work around the audio function being stuck in D3cold after VFIO
passthrough. `echo 1 > /sys/bus/pci/rescan` re-enumerated the entire PCI bus,
which could cause side effects when amdgpu was loaded.

**Resolution:** The bus reset from Action Item 1 resets both `03:00.0` and
`03:00.1` via the PCIe link (SBR hits all functions behind the bridge). After
testing, `snd_hda_intel` binds cleanly to `03:00.1` with a direct bind — no
PCI remove/rescan needed. The remove/rescan code was deleted from vm-overwatch.

## 3. Disable Auto HDR — prevent display pipeline mode switching

**Status:** Done

**Problem:** Overwatch crashed on first launch with a runtime GPU TDR (WATCHDOG
dump). Windows Auto HDR (Event ID 4125) dynamically toggles HDR per-application,
causing display pipeline reconfiguration. During Overwatch's fullscreen + HDR
initialization, this mode switch triggers a GPU timeout at the default 2-second
TDR deadline. Second launch succeeds because the display is already configured.

**Fix:** Disable Auto HDR globally while keeping native HDR enabled. This
eliminates per-app mode switching while preserving HDR output.

```powershell
# Registry: HKU\<SID>\SOFTWARE\Microsoft\DirectX\UserGpuPreferences
# Set global AutoHDREnable=0 (HDR stays on natively, Auto HDR off)
# Remove any per-app Auto HDR overrides (e.g. Overwatch had AutoHDREnable=2097)
```

The registry path is per-user under `DirectXUserGlobalSettings`. The global
setting `SwapEffectUpgradeEnable=1;AutoHDREnable=0;` keeps HDR on but prevents
Windows from dynamically toggling it.

## 4. Disable Game Bar — suppress game overlay and toasts

**Status:** Done

**Problem:** Xbox Game Bar shows Auto HDR recommendation toasts when launching
games with HDR available but Auto HDR disabled. Game Bar features (recording,
overlay, performance monitoring) are unnecessary in a VM.

**Fix:** Disable Game Bar entirely:

```powershell
# Machine-wide policy
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord

# User settings
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "UseNexusForGameBarEnabled" -Value 0 -Type DWord
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord
```

## 5. Disable Auto HDR system toast notification

**Status:** Done

**Problem:** Even with Game Bar disabled, Windows shows an Auto HDR recommendation
toast via the system notification `Windows.SystemToast.Graphics.AutoHDR`. This is
a separate notification source from Game Bar.

**Fix:** Disable the system toast notification:

```powershell
# Per-user notification setting (use HKU\<SID> for guest agent, HKCU for interactive)
$path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Graphics.AutoHDR"
New-Item -Path $path -Force
Set-ItemProperty -Path $path -Name "Enabled" -Value 0 -Type DWord
```

## 6. Host-side CPU isolation — reduce boot TDR and improve runtime performance

**Status:** Implemented

**Problem:** Host processes (systemd services, kernel threads, irqbalance) share
CPU cores with VM vCPU threads, causing interrupt delivery latency and
contributing to boot-time Defender contention.

**Fix:** Three-layer isolation:
1. **Libvirt XML**: `emulatorpin cpuset='0'`, `iothreadpin cpuset='0'` — pins
   QEMU housekeeping to core 0
2. **vm-overwatch**: `AllowedCPUs=0` on system.slice, user.slice, init.scope —
   confines all host processes to core 0 during VM runtime
3. **IRQ pinning**: All IRQs → core 0, irqbalance stopped, writeback migrated

**Results:** Reduced WATCHDOG dump frequency from ~100% to ~33% (2/3 clean boots).
Runtime gaming benefits: cleaner frame delivery, zero host interference on VM cores.

See [Host-Side CPU Isolation](windows-configuration.md#host-side-cpu-isolation) for full implementation details.
