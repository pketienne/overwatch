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

## 3. Disable Auto HDR — Done

Disabled Auto HDR globally (`AutoHDREnable=0`) while keeping native HDR on. Prevents per-app display pipeline mode switching that caused TDR on first Overwatch launch. See [Phase 13](recipe/configure.md#phase-13-display-configuration).

## 4. Disable Game Bar — Done

Disabled Game Bar via `AllowGameDVR` policy + user settings. Suppresses unnecessary overlay and Auto HDR recommendation toasts. See [Phase 13](recipe/configure.md#phase-13-display-configuration).

## 5. Disable Auto HDR system toast — Done

Disabled `Windows.SystemToast.Graphics.AutoHDR` notification (separate from Game Bar). See [Phase 13](recipe/configure.md#phase-13-display-configuration).

## 6. Host-side CPU isolation — Implemented

Three-layer isolation: libvirt `emulatorpin`/`iothreadpin` on core 0, vm-overwatch `AllowedCPUs=0` on system/user/init slices, IRQ pinning. Reduced WATCHDOG dump frequency from ~100% to ~33%. See [CPU Isolation Architecture](recipe/setup.md#cpu-isolation-architecture).

---

## 7. Eliminate remaining WATCHDOG TDR dumps (~1 in 3 boots) — Resolved

**Status:** Resolved — GPU hot-plug after boot

**Problem:** Intermittent non-fatal `VIDEO_DXGKRNL_LIVEDUMP` (0x1B0) WATCHDOG
dumps at ~T+49s and ~T+78s after boot. Initially attributed to Windows Defender
(`MsMpEng`) CPU contention, but the actual root cause was DxgKrnl initializing
the WDDM driver on the VFIO GPU during Windows boot — the GPU was present from
VM start, so the driver init competed with all other boot-time activity.

**Root cause:** DxgKrnl WDDM init on a GPU that's present at boot time. The
driver init window (~T+21-49s) overlaps with boot contention regardless of
Defender — Defender amplifies it but isn't the fundamental cause.

**Fix:** Hot-plug the GPU after Windows boots instead of including it in the
persistent VM XML. `vm-overwatch` now:
1. Starts the VM without GPU hardware (hostdevs removed from persistent config)
2. Waits for the QEMU guest agent (confirms Windows boot is complete)
3. Hot-plugs GPU via `virsh attach-device --live`, then GPU audio 1s later

**Test results:** 0/5 cycles with hot-plug produced WATCHDOG dumps vs 3/5 with
GPU present at boot. The DxgKrnl init happens post-boot with no contention,
eliminating the TDR timeout entirely.

**Implementation:** `ensure_gpu_hotplugged()` in vm-overwatch.sh. GPU/audio PCI
hostdevs removed from persistent VM config — managed entirely by vm-overwatch.
