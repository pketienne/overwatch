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

## 7. Eliminate remaining WATCHDOG TDR dumps (~1 in 3 boots)

**Status:** Open — two options to evaluate

**Problem:** Intermittent non-fatal `VIDEO_DXGKRNL_LIVEDUMP` (0x1B0) WATCHDOG
dumps at ~T+49s and ~T+78s after boot. Root cause is DxgKrnl initializing the
WDDM driver on the VFIO GPU during boot contention (proven by BasicDisplay test
— not AMD-specific).

**Previous attempts:**
- TdrDelay increase to 25s — dumps persisted (60-120s never tested)
- Defender exclusions — reduced from 2 dumps to 1, not eliminated
- Deferred driver load (Disable-PnpDevice/Enable-PnpDevice) — 1/5 dumps, PnP
  state corruption on repeated cycles
- GPU hot-plug after boot — 0/5 dumps but **no display output** (WDDM can't
  register hot-added display adapters). See
  [case study](../troubleshooting-methodology/case-studies.md#gpu-hot-plug-attempt-method-2).

### 7a. Increase TDR timeout to 60s

Set `TdrDelay` and `TdrDdiDelay` to 60s in the guest registry. The dumps are
non-fatal livedumps — the GPU recovers on its own. A longer timeout gives
DxgKrnl more time to complete WDDM init under contention, preventing the
timeout from firing. No impact on normal boot time (timeout only matters if the
GPU doesn't respond). Previous testing only went up to 25s; subagent research
recommended 60-120s but 25s was the highest value tested before this.

Downside: if the GPU actually hangs during gameplay, recovery takes 60s instead
of 2s. Acceptable tradeoff given actual hangs are rare.

Registry keys:
```
HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\TdrDelay = 60 (DWORD)
HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\TdrDdiDelay = 60 (DWORD)
```

**Test results (2026-02-26):** 0/3 WATCHDOG dumps with TdrDelay=60,
TdrDdiDelay=60. Cycle 1 GPU status OK; cycles 2-3 GPU status `Unknown` (may be
PnP query timing during rapid test cycling — needs investigation). Compared to
baseline ~60% dump rate (3/5) and previous TdrDelay=25 which still produced
dumps.

### 7b. Combine hot-plug with a display solution

Hot-plug eliminates 100% of dumps (0/5) but WDDM doesn't register hot-added
display adapters. If a method exists to activate display output on a hot-plugged
GPU, this would be the ideal fix. Potential avenues:

**Looking Glass** — open-source IVSHMEM-based framebuffer sharing. Guest
captures GPU framebuffer to shared memory; host displays it in a window with
sub-millisecond latency. However, it still needs the GPU registered as a WDDM
display adapter to have a framebuffer to capture. Would require an Indirect
Display Driver (IDD) on the guest side to give the GPU something to render to,
and it's unclear whether that works on a hot-plugged GPU that WDDM never
registered. Most realistic option but unproven for this use case.

**Sunshine/Moonlight streaming** — Sunshine (game streaming server) in the guest
can create virtual displays without a physical monitor and hooks into DXGI
directly, bypassing WDDM display registration. Moonlight (client) on the host
decodes and displays it. Over localhost the latency could be minimal. Tradeoff
is encoding overhead and added complexity.

**Future WDDM updates** — not actionable, just noting the possibility.

This is a research item, not an immediate fix.
