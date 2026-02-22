# Navi 31 (RX 7900 XTX) Register Reference for GPU Reset

Extracted from Linux kernel amdgpu driver source. Register offsets from `mp_13_0_0_offset.h`
are **relative** to the IP block base. For Navi 31, both MP0 (PSP) and MP1 (SMU) share the
same IP discovery seg[0] base: **0x00016000 dwords** (= **0x00058000 bytes** in BAR5).

**IMPORTANT**: The raw register offsets in the header files (e.g., `regMP0_SMN_C2PMSG_81 = 0x0091`)
must be added to the IP discovery base to get the actual BAR5 dword offset:
`actual_dword_offset = 0x16000 + raw_offset`. Byte offset = `actual_dword_offset * 4`.

MMIO register space is **BAR5** (1MB, non-prefetchable), NOT BAR0 (which is VRAM).

## SMU Mailbox Protocol

The SMU (System Management Unit) is communicated with via "mailbox" registers —
CPU-to-PMFW message registers in the MP1 address block.

### Normal Mailbox (SMU messages like EnterBaco, ExitBaco)

| Purpose | Register | Offset | Byte Offset |
|---------|----------|--------|-------------|
| Message (command ID) | `MP1_SMN_C2PMSG_66` | 0x0282 | 0x0A08 |
| Argument | `MP1_SMN_C2PMSG_82` | 0x0292 | 0x0A48 |
| Response | `MP1_SMN_C2PMSG_90` | 0x029a | 0x0A68 |

**Protocol:**
1. Wait for response reg to be non-zero (previous command done)
2. Write 0 to response register (clear)
3. Write argument to arg register
4. Write message ID to message register
5. Poll response register until non-zero (command complete)
6. Response value 1 = success

### Debug Mailbox (used for MODE1 reset on Navi 31!)

| Purpose | Register | Offset | Byte Offset |
|---------|----------|--------|-------------|
| Parameter | `MP1_SMN_C2PMSG_53` | 0x0275 | 0x09D4 |
| Message | `MP1_SMN_C2PMSG_75` | 0x028b | 0x0A2C |
| Response | `MP1_SMN_C2PMSG_54` | 0x0276 | 0x09D8 |

**Protocol (fire-and-forget):**
1. Write parameter to param register
2. Write message to message register
3. Write 0 to response register
4. (No polling — the GPU resets and MMIO becomes unavailable)

## SMU Message IDs

From `smu_v13_0_0_message_map`:

| Generic Name | PPSMC Constant | Purpose |
|-------------|----------------|---------|
| `SMU_MSG_EnterBaco` | `PPSMC_MSG_EnterBaco` | Enter BACO (chip off, bus alive) |
| `SMU_MSG_ExitBaco` | `PPSMC_MSG_ExitBaco` | Exit BACO |
| `SMU_MSG_ArmD3` | `PPSMC_MSG_ArmD3` | ARM D3 state (with audio function) |
| `SMU_MSG_Mode1Reset` | `PPSMC_MSG_Mode1Reset` | Mode1 reset (normal mailbox, non-Navi31) |
| `SMU_MSG_Mode2Reset` | `PPSMC_MSG_Mode2Reset` | Mode2 reset (soft reset) |
| `SMU_MSG_PrepareMp1ForUnload` | `PPSMC_MSG_PrepareMp1ForUnload` | Prepare for driver unload |
| `SMU_MSG_TestMessage` | `PPSMC_MSG_TestMessage` | Test SMU communication |
| `SMU_MSG_GetSmuVersion` | `PPSMC_MSG_GetSmuVersion` | Read PMFW version |
| `SMU_MSG_BacoAudioD3PME` | (via set_azalia_d3_pme) | Audio D3 PME notification |

For Navi 31 (IP_VERSION 13,0,0), MODE1 reset uses `DEBUGSMC_MSG_Mode1Reset`
via the **debug** mailbox, NOT the normal mailbox.

## PSP (Platform Security Processor) Registers

| Register | Offset | Byte Offset | Purpose |
|----------|--------|-------------|---------|
| `MP0_SMN_C2PMSG_35` | 0x0063 | 0x018C | Bootloader command/status (bit 31 = ready) |
| `MP0_SMN_C2PMSG_36` | 0x0064 | 0x0190 | Firmware load address (addr >> 20) |
| `MP0_SMN_C2PMSG_58` | 0x007a | 0x01E8 | SOS firmware version |
| `MP0_SMN_C2PMSG_64` | 0x0080 | 0x0200 | PSP ring control/command |
| `MP0_SMN_C2PMSG_67` | 0x0083 | 0x020C | PSP ring write pointer |
| `MP0_SMN_C2PMSG_69` | 0x0085 | 0x0214 | Ring buffer address low |
| `MP0_SMN_C2PMSG_70` | 0x0086 | 0x0218 | Ring buffer address high |
| `MP0_SMN_C2PMSG_71` | 0x0087 | 0x021C | Ring buffer size |
| **`MP0_SMN_C2PMSG_81`** | **0x0091** | **0x0244** | **SOL (Sign of Life) — sOS alive** |

**SOL register**: Read this to check if PSP Secure OS is alive.
Value != 0 means the GPU has been initialized and may need a reset.

## MMIO Indirect Access (SMN)

The ATOM BIOS and some driver code uses MM_INDEX/MM_DATA for SMN (System Management
Network) indirect register access:

| Register | ATOM offset | MMIO byte offset | Purpose |
|----------|-------------|-------------------|---------|
| MM_INDEX | REG[0x000C] | 0x0030 | SMN address to access |
| MM_DATA | REG[0x000D] | 0x0034 | Data read/written at SMN address |

**Usage**: Write the full SMN address to MM_INDEX, then read/write MM_DATA.

### Key SMN Addresses (from ATOM BIOS asic_init)

| SMN Address | Purpose |
|-------------|---------|
| `0x00058184` | SMU mailbox (used during ASIC init, waits for bit 31) |

---

## BACO (Bus Active, Chip Off) Reset Sequence

### Prerequisites
1. Check PowerPlay table `platform_caps` for `SMU_13_0_0_PP_PLATFORM_CAP_BACO`
2. Verify `SMU_FEATURE_BACO_BIT` is enabled in SMU firmware

### Enter BACO (Direct Path — no audio function)
```
1. Send SMU_MSG_EnterBaco via normal mailbox
   - Param: BACO_SEQ_BACO (full chip off) or BACO_SEQ_BAMACO (memory stays alive)
2. Sleep 10-11ms
```

### Enter BACO (ARM D3 Path — with audio function)
```
1. Send SMU_MSG_ArmD3 via normal mailbox
   - Param: BACO_SEQ_BACO or BACO_SEQ_BAMACO
   (PMFW handles the actual power transition when PCIe signals D3)
```

### Exit BACO (Direct Path)
```
1. Send SMU_MSG_ExitBaco via normal mailbox (no param)
2. Clear VBIOS scratch registers 6 and 7 (signals full ASIC reinit needed)
3. Set gfx.is_poweron = false (GFX engine needs full re-init)
```

### Exit BACO (ARM D3 Path)
```
1. Wait 10-11ms for PMFW D-state change
2. Send SMU_MSG_ArmD3 with BACO_SEQ_ULPS param (Ultra Low Power State = exit)
```

### BACO Feature Bits
| Feature | Purpose |
|---------|---------|
| `FEATURE_BACO_BIT` | Core BACO functionality |
| `FEATURE_BACO_MPCLK_DS_BIT` | MP clock deep sleep during BACO |
| `FEATURE_BACO_CG_BIT` | Clock gating during BACO |

---

## MODE1 Reset Sequence (Default for Navi 31)

This is what the kernel driver does to hardware-reset Navi 31:

```
 1. Mark engine hung in ATOMBIOS scratch registers
 2. Save PCI config space (amdgpu_device_cache_pci_state)
 3. Disable PCI bus mastering (pci_clear_master)
 4. Determine reset param:
    - If PMFW >= v78.77 AND RAS fatal error active: param = (1 << 16)
    - Otherwise: param = 0
 5. Send DEBUGSMC_MSG_Mode1Reset via DEBUG mailbox:
    WREG32(MP1_SMN_C2PMSG_53, param)             # 0x0275: write parameter
    WREG32(MP1_SMN_C2PMSG_75, DEBUGSMC_MSG_Mode1Reset)  # 0x028b: write message
    WREG32(MP1_SMN_C2PMSG_54, 0)                  # 0x0276: clear response
 6. Disable MMIO access (set no_hw_access flag)
 7. Wait 500ms (SMU13_MODE1_RESET_WAIT_TIME_IN_MS)
 8. Re-enable MMIO access
 9. Restore PCI config space (amdgpu_device_load_pci_state)
10. Wait for PSP bootloader ready:
    Poll MP0_SMN_C2PMSG_35 (0x0063) until (val & 0xFFFFFFFF) == 0x80000000
11. Wait for ASIC:
    Poll NBIO MEMSIZE register until != 0xFFFFFFFF (up to usec_timeout us)
12. Clear engine hung in ATOMBIOS scratch registers
```

### Key Timing
| Constant | Value | Purpose |
|----------|-------|---------|
| `SMU13_MODE1_RESET_WAIT_TIME_IN_MS` | 500ms | Wait after sending MODE1 message |
| Bootloader poll | up to ~10s | Wait for PSP to reboot |
| MEMSIZE poll | up to ~10s | Wait for ASIC to come online |

---

## PSP Ring Buffer Protocol

For firmware loading and trusted app communication (not directly needed for reset):

### Ring Creation
1. Wait for sOS ready: Poll `MP0_SMN_C2PMSG_64` (0x0080) for bit 31 set
2. Write ring address low to `MP0_SMN_C2PMSG_69` (0x0085)
3. Write ring address high to `MP0_SMN_C2PMSG_70` (0x0086)
4. Write ring size to `MP0_SMN_C2PMSG_71` (0x0087)
5. Write init command to `MP0_SMN_C2PMSG_64`: `(ring_type << 16)`
6. Wait 20ms, then poll `MP0_SMN_C2PMSG_64` for response (bit 31)

### Command Submission
1. Read write pointer from `MP0_SMN_C2PMSG_67` (0x0083)
2. Fill 64-byte ring buffer frame (cmd address, fence address, fence value)
3. Advance write pointer: `(ptr + 16) % ring_size_dw`
4. Write new pointer to `MP0_SMN_C2PMSG_67`

---

## ATOM BIOS Command Tables (from navi31-vbios.rom)

Our VBIOS has 5 active command tables:

| Index | Name | Offset | Size | Notes |
|-------|------|--------|------|-------|
| 0 | ASIC_Init | 0x4314 | 132B | Uses SMN indirect to access SMU mailbox |
| 6 | EnableCRTCMemReq | 0x496C | 75B | Display controller memory request |
| 22 | EnableGraphSurfaces | 0x44F4 | 68B | Graphics surface enable |
| 53 | ReadEfuseValue | 0x4398 | 347B | eFuse reading via SMU |
| 66 | cmd_function66 | 0x4538 | 1075B | Large init function, writes many registers |

### ASIC_Init Analysis
The ASIC_Init table:
1. Sends an SMU mailbox command via SMN indirect (MM_INDEX=0x00058184)
2. Waits for response bit 31 with timeout (~200K iterations * 20us = ~4 seconds)
3. Checks ObjectHeader data table for configuration flags
4. Reads REG[0x0DE3] (likely GFX config), derives a value, writes to REG[0x0006] and REG[0x0053]

## ATOM BIOS Data Tables

| Index | Name | Offset | Size | Rev |
|-------|------|--------|------|-----|
| 2 | MultimediaConfigInfo (smc_dpm_info) | 0x2980 | 460B | 5.0 |
| 3 | StandardVESA_Timing | 0x2084 | 368B | 2.1 |
| 4 | FirmwareInfo | 0x2914 | 108B | 3.4 |
| 7 | DIGTransmitterInfo | 0x054C | 568B | 5.4 |
| 8 | SMU_Info | 0x2B4C | 288B | 4.0 |
| 9 | SupportedDevicesInfo (connector/encoder info) | 0x22E4 | 788B | 3.2 |
| 14 | GFX_Info | 0x2C6C | 136B | 3.0 |
| 24 | MC_InitParameter | 0x2D5C | 68B | 3.3 |
| 25 | ASIC_VDDC_Info (PowerPlayInfo) | 0x0784 | 5728B | 1.0 |
| 28 | VRAM_Info | 0x2DA0 | 4810B | 3.0 |
| 32 | VoltageObjectInfo | 0x406C | 204B | 5.0 |

---

## Standalone Reset Module — Minimum Register Access

For a vendor-reset style kernel module that can reset Navi 31 without the full amdgpu driver.

**CRITICAL**: MMIO registers are in **BAR5** (not BAR0). All dword offsets need the IP
discovery base offset **0x16000** added. See `navi31-reset/navi31_reset.c` for the
working implementation.

### Register Access Pattern
```c
// Map BAR5 via direct ioremap (safe alongside amdgpu — no pci_enable_device needed)
resource_size_t bar5_start = pci_resource_start(pdev, 5);
resource_size_t bar5_len = pci_resource_len(pdev, 5);
void __iomem *mmio = ioremap(bar5_start, bar5_len);
// WARNING: Do NOT use pci_enable_device_mem/pci_disable_device when amdgpu is bound.
// This will cause a GPU soft lockup (SMU register access hang on CPU for 200+ seconds).
// Direct ioremap is safe because multiple mappings of the same physical MMIO are allowed.

// IP discovery base for MP0/MP1 seg[0] on Navi 31
#define MP_BASE  0x00016000

// Read/write using dword offsets (multiply by 4 for byte address in BAR5)
#define RREG32(off)    readl(mmio + (u64)(off) * 4)
#define WREG32(off, v) writel((v), mmio + (u64)(off) * 4)

// Register dword offsets (with base applied)
#define MP0_C2PMSG_35  (MP_BASE + 0x0063)  // Bootloader ready (bit 31)
#define MP0_C2PMSG_81  (MP_BASE + 0x0091)  // SOL (Sign of Life)
#define MP1_C2PMSG_53  (MP_BASE + 0x0275)  // Debug mailbox param
#define MP1_C2PMSG_66  (MP_BASE + 0x0282)  // Normal mailbox message
#define MP1_C2PMSG_75  (MP_BASE + 0x028b)  // Debug mailbox message
// ... etc
```

### MODE1 Reset (Navi 31 default — verified register access)
```c
pci_save_state(pdev);
pci_clear_master(pdev);

WREG32(MP_BASE + 0x0275, 0);       // Param = 0
WREG32(MP_BASE + 0x028b, 0x02);    // DEBUGSMC_MSG_Mode1Reset
WREG32(MP_BASE + 0x0276, 0);       // Clear response

msleep(500);

pci_restore_state(pdev);

// Wait for bootloader (bit 31)
while ((RREG32(MP_BASE + 0x0063) & 0x80000000) == 0)
    usleep_range(100, 500);
```

### BACO Reset
```c
// Clear response, set param, send EnterBaco
WREG32(MP_BASE + 0x029a, 0);
WREG32(MP_BASE + 0x0292, 1);       // BACO_SEQ_BACO
WREG32(MP_BASE + 0x0282, 0x15);    // PPSMC_MSG_EnterBaco

// Poll response
while (RREG32(MP_BASE + 0x029a) == 0) udelay(10);

usleep_range(10000, 11000);

// Send ExitBaco
WREG32(MP_BASE + 0x029a, 0);
WREG32(MP_BASE + 0x0282, 0x16);    // PPSMC_MSG_ExitBaco

while (RREG32(MP_BASE + 0x029a) == 0) udelay(10);

// Wait for SOL
while (RREG32(MP_BASE + 0x0091) == 0) usleep_range(100, 500);
```

### Numeric Message IDs (from `smu_v13_0_0_ppsmc.h`)

```c
// BACO messages (normal mailbox via C2PMSG_66)
#define PPSMC_MSG_EnterBaco        0x15
#define PPSMC_MSG_ExitBaco         0x16
#define PPSMC_MSG_ArmD3            0x17
#define PPSMC_MSG_BacoAudioD3PME   0x18

// Reset messages
#define PPSMC_MSG_Mode1Reset       0x2F  // normal mailbox (NOT used for Navi 31!)
#define PPSMC_MSG_Mode2Reset       0x4F

// Debug mailbox messages (via C2PMSG_75)
#define DEBUGSMC_MSG_Mode1Reset    0x02  // THIS is what Navi 31 actually uses!

// Utility
#define PPSMC_MSG_TestMessage      0x01
#define PPSMC_MSG_GetSmuVersion    0x02
#define PPSMC_MSG_PrepareMp1ForUnload  0x2E
```

---

## Tested Results (2026-02-21)

MODE1 reset via `navi31_reset` kernel module — verified working on RX 7900 XTX:

| Metric | Value |
|--------|-------|
| Reset time | 509ms |
| PSP bootloader recovery | Immediate (bit 31 set within first poll) |
| amdgpu rebind after reset | ~3s (firmware load + ring init, 96 CUs, all engines) |
| VM VBIOS POST after reset | Working (Windows boots, Overwatch renders) |
| Consecutive VM cycles | Tested multiple cycles without reboot |

### Unbind Requirements
Before resetting, these services must be stopped to release GPU resources:
1. **OpenRGB** — holds DP AUX I2C adapters (`/dev/i2c-*`), blocks `i2c_del_adapter`
2. **GDM** — GNOME Shell opens all DRM cards for multi-GPU, blocks `drm_dev_unplug`
3. **ollama** — may use render node for GPU compute
