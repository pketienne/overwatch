# VBIOS Reverse Engineering Plan: RX 7900 XTX (Navi 31)

## Context

We have a working GPU passthrough setup using suspend/resume for hardware reset. This works but adds ~20 seconds per transition (two suspend/resume cycles per gaming session). A software-only reset would be faster and more elegant. This plan documents how to reverse engineer the VBIOS/firmware to achieve that.

## Current State

Our suspend/resume approach is essentially a brute-force hardware equivalent of **BACO** (Bus Active, Chip Off) — the exact mechanism that `vendor-reset` uses for older GPUs via SMU commands. The difference is we're using platform-level suspend to physically power-cycle the GPU, while vendor-reset sends SMU mailbox messages to do it in software.

The kernel's amdgpu driver already implements BACO and MODE1 reset for Navi 31 (SMU v13.0.0). The challenge is triggering these resets *outside* the full driver context, from a standalone module or script.

---

## Why This Is Hard

1. **No existing RDNA 3 vendor-reset support** — gnif/vendor-reset only covers up to RDNA 1 (Navi 14). gnif was hired by AMD; no public RDNA 3 progress.
2. **PowerPlay lockdown** — AMD cryptographically locked RDNA 3 power management tables. MorePowerTool developers: "there will be no MPT for RDNA3."
3. **Signed/encrypted firmware** — PSP and SMU firmware cannot be modified without breaking the signature chain.
4. **No community RE** — No published RDNA 3 VBIOS reverse engineering work exists as of early 2026.
5. **Chiplet complexity** — Navi 31 uses MCM design (1 GCD + 6 MCDs), adding inter-die reset coordination.

---

## Architecture Overview

### GPU POST Sequence (Navi 31)

1. **Hardware power-on** → PCIe link establishes
2. **PSP boot** → On-die ARM Cortex-A5 boots from ROM, loads IPL from SPI flash, validates chain
3. **PSP firmware** → Loads Secure OS, SMU firmware, trusted applications
4. **SMU init** → Configures clocks, voltages, power rails, thermal monitoring
5. **VBIOS execution** → System BIOS/UEFI executes GOP driver or VGA BIOS; ATOM BIOS `asic_init` runs
6. **OS driver** → amdgpu parses ATOM tables, initializes IP blocks, loads firmware from `/lib/firmware/amdgpu/`

### Key Components

| Component | Architecture | Firmware | Encrypted? |
|-----------|-------------|----------|------------|
| **PSP** (Platform Security Processor) | ARM Cortex-A5, on-die | `psp_13_0_0_sos.bin`, `psp_13_0_0_ta.bin` | Yes (signed + encrypted) |
| **SMU** (System Management Unit) | Autonomous microcontroller | `smu_13_0_0.bin` | Yes (signed) |
| **GFX** (Graphics Core) | GFX 11.0 | `gc_11_0_0_{pfp,me,mec,rlc}.bin` | Signed |
| **ATOM BIOS** | Bytecode VM | Embedded in VBIOS ROM | No (readable bytecode) |

### Reset Mechanisms

| Type | How It Works | Who Triggers | Navi 31 Support |
|------|-------------|-------------|-----------------|
| **PCI FLR** | PCIe standard reset | vfio-pci (default) | Insufficient — doesn't reset internal state |
| **Secondary Bus Reset** | Reset all devices on bus | PCI subsystem | Insufficient |
| **BACO** | SMU powers off chip, keeps PCIe alive | amdgpu via SMU mailbox | Supported in driver |
| **MODE1** | PSP hard reset | amdgpu via PSP ring | **Default for Navi 31** in amdgpu |
| **MODE2** | SMU soft reset (selective IP blocks) | amdgpu via SMU mailbox | Available but not default |
| **Suspend/resume** | Platform power-cycles everything | Our current approach | Works (brute force) |

### amdgpu Reset Method Selection (from `soc21.c`)

For Navi 31 (`IP_VERSION(13, 0, 0)`), the driver defaults to **MODE1** reset. This is mediated by the PSP.

---

## VBIOS Structure

The VBIOS is a PCI Expansion ROM containing:

1. **Legacy VGA BIOS image** (Code Type 0x00) — contains ATOM BIOS tables and bytecode
2. **UEFI GOP driver image** (Code Type 0x03) — EFI driver for display output

### ATOM BIOS

ATOM BIOS v2.x (used by RDNA 3) contains:
- **Master Command Table** — bytecode functions (`asic_init`, encoder control, clock setup, etc.)
- **Master Data Table** — structured data (firmware info, clocks, GPIO, connectors, PowerPlay)
- **Bytecode interpreter** — register read/write, arithmetic, branching, parameter passing

The bytecode is **not encrypted** — it can be disassembled with AtomDis. The command tables directly write GPU MMIO registers, making them a valuable source for understanding the initialization sequence.

Key kernel header: `drivers/gpu/drm/amd/include/atomfirmware.h` — defines all v2.x structure layouts.

### IFWI (Integrated Firmware Image)

Navi 3x uses IFWI format for the full SPI flash content:
- **PSP Directory Tables** — firmware entry table pointing to PSP/BIOS directories
- **Dual partitions** — active/inactive for brick protection during flashing
- Flash updates go through PSP sysfs interface (`psp_vbflash`)

---

## Tools

### VBIOS Dumping

| Tool | Command/Usage |
|------|--------------|
| **amdvbflash** | `amdvbflash -s 0 navi31.rom` |
| **sysfs** | `echo 1 > /sys/bus/pci/devices/0000:03:00.0/rom && cat rom > dump.rom` |
| **GPU-Z** (Windows) | GUI dump (only reads first partition on RDNA 3) |

### ATOM BIOS Analysis

| Tool | Purpose | URL |
|------|---------|-----|
| **AtomDis** | Disassemble command table bytecode | github.com/gpuhw/AtomDis |
| **YAABE** | Full data structure editor | github.com/netblock/yaabe |
| **ATOMBIOSReader** | Generate master table lists | github.com/kizwan/ATOMBIOSReader |
| **UEFITool 0.25.1** | Extract GOP driver (GUID `BAE7599F-3C6B-43B7-BDF0-9CE07AA91AA6`) | github.com/LongSoft/UEFITool |

### PSP/Firmware Analysis

| Tool | Purpose | URL |
|------|---------|-----|
| **PSPTool** | Extract/analyze PSP firmware | github.com/PSPReverse/PSPTool |
| **AMD-SP Loader** | Binary Ninja plugin for PSP | github.com/dayzerosec/AMD-SP-Loader |

### Kernel Source Reference

| File | Purpose |
|------|---------|
| `amdgpu/soc21.c` | ASIC-level init, reset method selection |
| `amdgpu/psp_v13_0.c` | PSP communication protocol |
| `pm/swsmu/smu13/smu_v13_0.c` | SMU common functions (BACO, mode1) |
| `pm/swsmu/smu13/smu_v13_0_0_ppt.c` | SMU message IDs, PowerPlay table driver |
| `amdgpu/gfx_v11_0.c` | GFX engine init |
| `amdgpu/amdgpu_device.c` | Core device init and reset orchestration |
| `amdgpu/amdgpu_reset.c` | GPU reset framework |
| `amdgpu/atom.c` / `atom.h` | ATOM bytecode interpreter |
| `include/atomfirmware.h` | ATOM BIOS v2.x structure definitions |

---

## Implementation Plan

### Phase 1: Information Gathering — COMPLETE

**Goal**: Understand the exact register sequences used for Navi 31 reset.

1. **[DONE] Dump the VBIOS** — 112KB sysfs ROM BAR dump (`navi31-vbios.rom`) + 2MB full IFWI (`navi31-full-rom.bin`)
2. **[DONE] Disassemble ATOM BIOS** — Custom Python disassembler (`atomdis.py`) based on kernel's atom.c. Full disassembly of all 5 command tables including `asic_init`
3. **[DONE] Parse data tables** — 35 data tables enumerated, FirmwareInfo (rev 3.4), SMU_Info (rev 4.0), GFX_Info (rev 3.0), VRAM_Info (rev 3.0), PowerPlayInfo
4. **[DONE] Read kernel source** for SMU v13.0.0:
   - All SMU message IDs mapped from `smu_v13_0_0_ppsmc.h` (BACO: 0x15/0x16, MODE1 normal: 0x2F, MODE1 debug: 0x02)
   - SMU normal mailbox: C2PMSG_66 (msg, 0x0282), C2PMSG_82 (arg, 0x0292), C2PMSG_90 (resp, 0x029a)
   - SMU debug mailbox: C2PMSG_53 (param, 0x0275), C2PMSG_75 (msg, 0x028b), C2PMSG_54 (resp, 0x0276)
   - PSP SOL: MP0_SMN_C2PMSG_81 (0x0091)
   - PSP bootloader ready: MP0_SMN_C2PMSG_35 (0x0063), bit 31
   - PSP ring: C2PMSG_64 (control), C2PMSG_67 (wptr), C2PMSG_69-71 (addr/size)
   - Full BACO enter/exit sequence documented
   - Full MODE1 reset sequence documented (12-step)
   - All extracted to `navi31-register-reference.md`
5. **[PARTIALLY DONE] Compare with Navi 10 vendor-reset**: The Navi 31 BACO sequence is architecturally identical to Navi 10 (send EnterBaco/ExitBaco via SMU mailbox) but uses different register offsets (MP1 C2PMSG_66/82/90 vs Navi 10's equivalent). MODE1 is new for Navi 31 (uses debug mailbox)

**Key Finding**: For Navi 31, MODE1 reset is the driver's default. It uses the **debug** mailbox (`DEBUGSMC_MSG_Mode1Reset = 0x02` to `C2PMSG_75`) rather than the normal mailbox. This is a fire-and-forget write — no response polling. The GPU fully resets and needs 500ms + bootloader wait to come back.

### Phase 2: Instrumented Tracing (2-4 weeks)

**Goal**: Capture the exact register-level sequence during amdgpu init, reset, and teardown.

6. **Build instrumented amdgpu module** with extra logging:
   - Log every SMU message (ID, params, response)
   - Log every ATOM command table execution
   - Log every register write during `hw_init` and `hw_fini`
7. **Capture traces** for three scenarios:
   - Clean boot initialization (reference)
   - Driver unbind + rebind (what our wrapper does)
   - GPU reset via MODE1 (triggered by `amdgpu.gpu_recovery=1`)
8. **Diff the traces** — identify the minimal set of operations needed for a clean reset

### Phase 3: Standalone Reset Module — COMPLETE

**Goal**: Build a kernel module that can reset Navi 31 without the full amdgpu driver.

**Module built**: `navi31-reset/navi31_reset.c` — compiled, tested, and integrated into `vm-overwatch` on myhost (kernel 6.17.0-14-generic).

**Key Discovery**: Register offsets from `mp_13_0_0_offset.h` require an IP discovery base offset.
For Navi 31, both MP0 and MP1 seg[0] base = **0x00016000 dwords** (0x58000 bytes in BAR5).
MMIO registers are in **BAR5** (1MB non-prefetchable), NOT BAR0 (which is VRAM/32GB).
This was confirmed by parsing the IP discovery table from `amdgpu_discovery` debugfs.

**Verified register reads** (with base offset applied):
| Register | BAR5 Byte Offset | Read Value | Status |
|----------|-------------------|------------|--------|
| SOL (C2PMSG_81) | 0x58244 | 0x0844bfc8 | Non-zero = PSP alive |
| Bootloader (C2PMSG_35) | 0x5818C | 0x80000000 | Bit 31 = ready |
| SOS Version (C2PMSG_58) | 0x581E8 | 0x00310035 | Matches firmware_info |
| SMU Response (C2PMSG_90) | 0x58A68 | 0x00000001 | Success |
| SMU Message (C2PMSG_66) | 0x58A08 | 0x00000012 | Last msg from amdgpu |
| Debug Response (C2PMSG_54) | 0x589D8 | 0x00000001 | Ready |

**Corrected register access** (all dword offsets include base):
```
actual_dword_offset = 0x16000 + raw_register_offset
byte_offset_in_BAR5 = actual_dword_offset * 4
```

**Module features**:
- `/dev/navi31-reset` character device (write "mode1", "baco", "force_mode1", or "force_baco")
- Read `/dev/navi31-reset` for GPU health status (SOL + bootloader values)
- MODE1 reset: PCI save → 3 debug mailbox writes → 500ms wait → PCI restore → bootloader poll
- BACO reset: EnterBaco via normal mailbox → 10ms → ExitBaco → SOL poll
- Direct `ioremap` of BAR5 — safe to load alongside amdgpu (no `pci_enable_device`)
- Driver-bound safety check — blocks reset while amdgpu is active, `force_` prefix to override
- Audio function (03:00.1) PCI config saved/restored alongside GPU

**MODE1 reset tested and verified**:
- Reset completes in **509ms** (500ms wait + 9ms overhead)
- PSP bootloader ready immediately after wait (bit 31 set)
- amdgpu rebinds successfully after reset with all rings initialized
- Full VM lifecycle tested: unbind → reset → vfio-pci → VM → vfio-pci unbind → reset → amdgpu

**Critical lessons learned during development**:
1. **Do NOT use `pci_enable_device_mem`/`pci_disable_device` alongside amdgpu** — this caused a GPU soft lockup (CPU stuck for 200+ seconds in `smu_cmn_send_smc_msg_with_param`). Fixed by using direct `ioremap` of BAR5 physical address instead.
2. **OpenRGB blocks amdgpu unbind** — holds DP AUX I2C adapter FDs, causing `i2c_del_adapter` → `wait_for_completion` to hang indefinitely. Must stop OpenRGB before unbinding.
3. **GDM/GNOME Shell blocks amdgpu unbind** — opens all DRM cards for multi-GPU rendering. Must stop GDM before unbinding.
4. **`device_is_bound()` check for driver state** — `pci_dev->driver` stays non-NULL during stuck `drm_dev_unplug`, but `device_is_bound()` reflects the actual sysfs bind state.

**vm-overwatch integration complete**: Replaced dual suspend/resume with MODE1 reset.
- Old: ~130s total overhead (2× suspend/resume + br0 network recovery)
- New: ~1s total overhead (2× MODE1 reset at 509ms each)
- Network bridge (br0) no longer disrupted — no suspend means no NetworkManager teardown

### Phase 4: Deep Analysis (if Phase 3 fails)

**Key insight from Phase 1**: MODE1 reset does NOT go through the PSP ring buffer.
It uses the SMU **debug** mailbox — just 3 register writes. This is much simpler than
originally anticipated. The PSP ring is only needed for firmware loading, not for reset.

If BACO and MODE1 don't work from outside the driver context:

12. **Investigate pre-conditions**: The SMU may require certain initialization before accepting
    messages. Check if the SMU message handler is active after vfio-pci unbind (it should be,
    since SMU runs independently on its own microcontroller).
13. **Analyze SMU firmware blob** (`smu_13_0_0.bin`): Look for the message dispatch table to
    understand what BACO/MODE1 messages actually do at the firmware level.
14. **Minimal driver approach**: Instead of a standalone module, build a stripped-down amdgpu
    that only does init + teardown (no display, no compute), purely for reset purposes.

---

## Key Insight: Why Suspend/Resume Works

Our current approach works because platform suspend physically power-cycles the GPU's power rails. This is equivalent to — and more thorough than — BACO. During suspend:

1. PCIe link goes down
2. GPU loses all power (VRAM contents lost, all registers reset)
3. On resume, GPU is in true power-on-reset state
4. PCI rescan re-enumerates the device from scratch

A software BACO achieves similar results but keeps the PCIe link alive and VRAM may be preserved. For our use case (VFIO passthrough), we don't need VRAM preservation — we just need the GPU in a clean state for the next VM.

## Most Likely Path to Success

**Ranked by feasibility (updated after Phase 3 completion):**

1. ~~Keep suspend/resume~~ → **REPLACED** by MODE1 reset
2. **MODE1 reset via debug mailbox** — ✅ **IMPLEMENTED AND WORKING**. 3 register writes + 500ms wait + PCI state save/restore. 509ms per reset, integrated into vm-overwatch.
3. **BACO reset via normal mailbox** — Implemented in module but untested. Available as fallback if MODE1 ever fails.
4. ~~Wait for AMD~~ — No longer relevant; we have a working solution.
5. ~~Full VBIOS RE~~ — Not needed; MODE1 reset is sufficient.

---

## References

- [vendor-reset (gnif)](https://github.com/gnif/vendor-reset)
- [Navi 10 reset patch](https://github.com/audiohacked/PKGBUILD-linux-vfio-navi/blob/master/navi10-reset.patch)
- [Linux kernel amdgpu driver](https://github.com/torvalds/linux/tree/master/drivers/gpu/drm/amd/amdgpu)
- [Kernel AMDGPU documentation](https://docs.kernel.org/gpu/amdgpu/driver-core.html)
- [OSDev: AMD Atombios](https://wiki.osdev.org/AMD_Atombios)
- [DayZeroSec: Reversing AMD PSP](https://dayzerosec.com/blog/2023/04/17/reversing-the-amd-secure-processor-psp.html)
- [PSPTool](https://github.com/PSPReverse/PSPTool)
- [Level1Techs: State of AMD RX 7000 VFIO (2024)](https://forum.level1techs.com/t/the-state-of-amd-rx-7000-series-vfio-passthrough-april-2024/210242)
- [Level1Techs: vendor-reset project](https://forum.level1techs.com/t/amd-polaris-vega-navi-reset-project-vendor-reset/163801)
- [AtomDis](https://github.com/gpuhw/AtomDis)
- [YAABE](https://github.com/netblock/yaabe)
- [Kernel dGPU firmware flashing](https://docs.kernel.org/gpu/amdgpu/flashing.html)
- [atomfirmware.h](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/include/atomfirmware.h)
- [smu_v13_0_0_ppsmc.h (message IDs)](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu_v13_0_0_ppsmc.h)
- [mp_13_0_0_offset.h (register offsets)](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/include/asic_reg/mp/mp_13_0_0_offset.h)

---

## Artifacts

### Phase 1

| File | Description |
|------|-------------|
| `navi31-vbios.rom` | 112KB sysfs ROM BAR dump (Legacy + UEFI GOP) |
| `navi31-full-rom.bin` | 2MB full SPI flash image (IFWI, dual partitions) |
| `atomdis.py` | Python ATOM BIOS bytecode disassembler |
| `navi31-register-reference.md` | Complete register reference for standalone reset |

### Phase 3

| File | Description |
|------|-------------|
| `navi31-reset/navi31_reset.c` | Standalone kernel module — MODE1 + BACO reset (direct ioremap, driver-bound safety) |
| `navi31-reset/Makefile` | Out-of-tree kernel module build |
| `navi31-reset/test-reset.sh` | Test script (stop services → unbind → reset → rebind → restart services) |
| `navi31-reset/vm-overwatch` | Updated vm-overwatch using MODE1 reset (deployed to `/usr/local/bin/vm-overwatch`) |
| `myhost:/home/myuser/navi31-reset/` | Deployed + compiled on target machine |
