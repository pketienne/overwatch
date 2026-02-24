# GPU Passthrough: Overwatch on Linux via Windows VM

## Goal
Run Overwatch 2 in a Windows 11 VM with the RX 7900 XTX passed through for native GPU performance, while keeping the Linux desktop on the iGPU. The 7900 XTX should be switchable between host use (ollama, DaVinci Resolve, OBS) and VM use (gaming) without rebooting.

## Hardware Summary
- **CPU**: AMD Ryzen 7 9800X3D (8 cores, SMT disabled)
- **Discrete GPU**: Sapphire NITRO+ RX 7900 XTX Vapor-X (PCI `03:00.0`, IOMMU group 15, device ID `1002:744c`, subsystem `1DA2:E471`)
- **GPU Audio**: Navi 31 HDMI/DP Audio (PCI `03:00.1`, device ID `1002:ab30`)
- **Integrated GPU**: AMD `1002:13c0` (PCI `74:00.0`, IOMMU group 30)
- **Motherboard**: MSI MPG X870E CARBON WIFI (MS-7E49), BIOS 1.A80 (Jan 8, 2026)
- **RAM**: 92GB (16GB allocated to VM)
- **Monitor**: LG ULTRAGEAR+ 45" OLED (3440x1440 native, HDMI to iGPU, DP to 7900 XTX)
- **Input**: Kinesis Advantage2 (29ea:0102), Razer Naga V2 Pro (1532:00a7), Razer Tartarus V2 (1532:022b), Razer Strider Chroma (1532:0c05), SteelSeries Arctis Pro Wireless (1038:1290 + 1038:1294)
- **Bootloader**: GRUB (Ubuntu, kernel 6.17.0-14-generic)
- **Host**: myhost (192.168.0.100), accessed via SSH from devbox (192.168.0.102)

---

## Current State

### What Works
- **Full GPU passthrough lifecycle without rebooting** — unlimited VM cycles via MODE1 software reset (~509ms per reset, no suspend/resume)
- Overwatch runs at 3440x1440 fullscreen with no anti-cheat issues
- iGPU display on Wayland at 3440x1440@85Hz on HDMI1
- **Automatic display switching** — iGPU blanked when VM starts (monitor auto-detects to DP), unblanked on restore
- All USB devices passed through (keyboard, mouse, keypad, mousepad, headset)
- Windows 11 VM with UEFI, TPM 2.0, anti-cheat tweaks
- Bridged networking (VM gets own IP on LAN)
- IVRS ACPI table override to fix VFIO container setup
- One-click desktop shortcut: click → play → shut down Windows → back to desktop
- **Comprehensive error logging** — ERR trap with line numbers, state snapshots at transitions, persistent log files in `/var/log/vm-overwatch/`, `--verbose` flag
- **Lock file** prevents concurrent vm-overwatch instances

### What Doesn't Work (Yet)
- Nothing critical remaining. All major issues resolved.

### Current Kernel Parameters
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on"
GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi-ivrs-override.img"
```

### Key Files on myhost
| File | Purpose |
|---|---|
| `/etc/default/grub` | Kernel params: `amd_iommu=on`, IVRS override initrd |
| `/boot/acpi-ivrs-override.img` | Patched IVRS ACPI table (zeroed exclusion flags, OEM rev 2) |
| `/usr/share/qemu/gpu-rom.bin` | Sapphire NITRO+ RX 7900 XTX Vapor-X VBIOS (2MB, from TechPowerUp) |
| `/etc/libvirt/hooks/qemu` | Libvirt hook dispatcher (currently no-op to avoid deadlocks) |
| `/usr/local/bin/vm-overwatch` | VM lifecycle wrapper script (MODE1 reset, runs as systemd transient unit). Logs to `/var/log/vm-overwatch/` |
| `/home/myuser/navi31-reset/navi31_reset.ko` | Standalone Navi 31 GPU reset kernel module |
| `/dev/navi31-reset` | Character device for GPU reset (write "mode1" to trigger) |
| `/usr/local/bin/vm-overwatch-launch` | Launcher that starts vm-overwatch via `systemd-run` |
| `/etc/modules-load.d/vfio-pci.conf` | Ensures vfio-pci module loads at boot |
| `/etc/udev/rules.d/99-gpu-passthrough.rules` | Prevents discrete GPU from getting a seat |
| `/var/lib/gdm3/.config/monitors.xml` | GDM display config (3440x1440@85Hz) |

---

## Implementation History

### Phase 1: IOMMU and Display Setup (Completed)

#### BIOS Settings
- IOMMU: Enabled
- Initiate Graphic Adapter: IGD (iGPU primary)
- Integrated Graphics: Force
- HybridGraphics: Disabled
- Secure Boot: **Disabled** (required for ACPI table override)

#### GRUB Configuration
Initial: `amd_iommu=on iommu=pt`
Final: `amd_iommu=on` (see Phase 3 for why `iommu=pt` and `force_isolation` were removed)

### Phase 2: Virtualization Stack (Completed)
Installed qemu-kvm, libvirt, OVMF. Standard setup, no issues.

### Phase 3: IOMMU / VFIO Container Fix (Completed)

#### Problem: "Failed to set group container: Invalid argument"
When starting the VM, VFIO refused to set up the container for IOMMU group 15 (discrete GPU).

#### Root Cause
The motherboard's BIOS IVRS (I/O Virtualization Reporting Structure) ACPI table declares three IVMD exclusion range entries (type 0x22, flags 0x08) covering device range 0x0000-0x0FFF. These tell the kernel to set `IOMMU_RESV_DIRECT` reserved regions on affected devices. Since kernel 6.6 (Lu Baolu's patch), the kernel strictly enforces `require_direct` for these devices, blocking VFIO container setup.

#### Approaches Tried

1. **Remove `iommu=pt` from kernel params** — Did not help. The `require_direct` flag is set by the IVRS table, independent of the default domain type.

2. **`amd_iommu=force_isolation`** — Changed IOMMU group 15 type from `identity` to `DMA-FQ`, but `require_direct` persisted independently. Also caused iGPU display to show white screen (broke display scanout DMA for the iGPU).

3. **BIOS "Kernel DMA Protection" setting** — The recommended fix is to disable this in BIOS. On MSI MPG X870E CARBON WIFI BIOS 1.A80, **this setting is not exposed**. Checked under AMD CBS > NBIO Common Options, Security, and all other sections. Not available.

4. **BIOS update** — Already on latest version (1.A80, Jan 2026).

5. **IVRS ACPI table override (SUCCESSFUL)** — Patched the IVRS binary to zero the exclusion flags:
   - Zeroed IVMD flags at bytes 0xC9, 0xE9, 0x109 (from 0x08 to 0x00)
   - Bumped OEM revision from 1 to 2 (kernel requires higher revision to accept override)
   - Recalculated checksum
   - Packed into CPIO archive at `/boot/acpi-ivrs-override.img`
   - Loaded via `GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi-ivrs-override.img"`
   - Required `CONFIG_ACPI_TABLE_UPGRADE=y` in kernel (confirmed)
   - Required Secure Boot disabled (kernel lockdown blocks ACPI overrides)

   Python script to create the patched table:
   ```python
   import struct
   with open("/sys/firmware/acpi/tables/IVRS", "rb") as f:
       data = bytearray(f.read())
   data[0xC9] = 0x00
   data[0xE9] = 0x00
   data[0x109] = 0x00
   struct.pack_into("<I", data, 0x18, 2)  # OEM revision
   data[9] = 0
   checksum = (256 - (sum(data) % 256)) % 256
   data[9] = checksum
   with open("/tmp/ivrs-patched.dat", "wb") as f:
       f.write(data)
   ```

#### White Screen Fix
`amd_iommu=force_isolation` was causing the iGPU display to output a white screen (even on VT consoles). The iGPU's display scanout DMA was broken by the forced DMA-FQ domain. Removing `force_isolation` and relying solely on the IVRS patch fixed both the VFIO issue and the display issue. The iGPU's IOMMU group 30 uses `identity` domain (correct for display scanout), while the patched IVRS ensures no `RESV_DIRECT` regions block VFIO on group 15.

### Phase 4: VM Creation (Completed)

#### VM Configuration ("overwatch")
- 7 vCPUs pinned to cores 1-7 (core 0 reserved for host)
- Topology: 1 socket, 7 cores, 1 thread
- 16GB RAM
- UEFI/OVMF with TPM 2.0 (tpm-crb, emulator backend)
- host-passthrough CPU with cache passthrough
- Anti-cheat: `<kvm><hidden state="on"/>` and `<vendor_id state="on" value="AuthenticAMD"/>`
- VirtIO disk: /var/lib/libvirt/images/overwatch.qcow2 (200GB)
- VirtIO NIC on bridged network
- GPU passthrough with ROM file and `rom bar="off"`
- GPU audio passthrough
- USB passthrough for all input devices + headset
- No virtual display (Spice/QXL removed)

#### GPU ROM File
The GPU boots on amdgpu (host driver), so the VBIOS ROM BAR may not be readable while the driver holds it. A standalone ROM file is provided to QEMU.

**Solution**: Downloaded VBIOS from TechPowerUp (272613.rom for Sapphire NITRO+ RX 7900 XTX Vapor-X, subsystem ID 1DA2:E471, 2MB). Placed at `/usr/share/qemu/gpu-rom.bin` (QEMU sandbox restricts access to other paths like /var/lib/libvirt/images/).

#### Network
Initially used NAT (libvirt default network). YouTube videos wouldn't load (likely QUIC/UDP issues with NAT). Switched to **bridged networking**:
- Created `br0` bridge over `enp9s0` in `/etc/netplan/50-cloud-init.yaml`
- Created libvirt `bridged` network definition
- VM gets its own IP on the LAN via DHCP

### Phase 5: Overwatch Installation (Completed)
- Mounted old NTFS Windows partition (`nvme0n1p3`) as SATA disk in VM
- Copied Overwatch (66GB) and Battle.net (738MB) to VM's C: drive
- Overwatch runs fullscreen at 3440x1440 (aspect ratio must be set to 21:9 in game settings)

### Phase 6: GPU Reset Bug (RESOLVED)

#### Problem
After the VM uses the RX 7900 XTX and shuts down, the GPU cannot be properly reset for a second VM session. The second VM start produces a grey or black screen on the DisplayPort output. This is a **known hardware limitation** of Navi 31 (RDNA 3) GPUs.

The `vendor-reset` kernel module (gnif/vendor-reset) does **not** support Navi 31. It only covers up to Navi 14 (RDNA 1). No forks or PRs add RDNA 3 support.

#### Solution: MODE1 Software Reset via navi31_reset Kernel Module

~~The initial solution used dual suspend/resume hardware reset (~20s per cycle + 35s network recovery). This has been replaced with a custom kernel module.~~

The `navi31_reset` kernel module performs a MODE1 reset of the GPU in **509ms** by writing 3 registers to the SMU debug mailbox. This replaces the suspend/resume approach entirely:

1. **Pre-VM reset**: After unbinding amdgpu → `echo mode1 > /dev/navi31-reset` (509ms) → bind vfio-pci → start VM
2. **Post-VM reset**: After VM shutdown → unbind vfio-pci → `echo mode1 > /dev/navi31-reset` (509ms) → bind amdgpu

**Advantages over suspend/resume:**
- **~130x faster**: ~1s total vs ~130s (2× suspend/resume + network recovery)
- **No network disruption**: br0 bridge stays up (no NetworkManager teardown/rebuild)
- **No PCI remove/rescan**: simpler, more reliable

The module (`navi31-reset/navi31_reset.c`) uses direct `ioremap` of BAR5 to access MMIO registers, making it safe to load alongside amdgpu for diagnostics. Reset is blocked while a driver is bound (safety check). Register offsets use the IP discovery base (0x16000 dwords for Navi 31 MP0/MP1).

**Tested**: Multiple consecutive VM cycles without rebooting — Windows visible on DP every time, GPU returned to amdgpu with all services working after each cycle.

#### Previous Solution: Dual Suspend/Resume (Replaced)

The original workaround used `rtcwake`/`systemctl suspend` with PCI remove/rescan to hardware power-cycle the GPU. This worked but added ~65s overhead per reset (suspend + resume + br0 recovery). Kept as `vm-overwatch.bak` on myhost for reference.

#### Approaches Tried (Before Solution)

1. **`rom bar="off"` in VM XML** — Did not fix the reset issue alone.

2. **amdgpu driver bind/unbind cycle after VM shutdown** — amdgpu reinitializes but subsequent VM start still shows no display.

3. **Post-VM suspend/resume only** — Hardware reset after VM but not before. First VM start works, second shows black screen (GPU left in amdgpu-teardown state, not power-on-reset state).

4. **Combined suspend/resume + amdgpu cycle** — Same result as #3.

5. **Boot with GPU on amdgpu + wrapper script** — Correct approach (GPU on amdgpu by default, wrapper manages lifecycle), but required solving several sub-problems:
   - **OpenRGB holding i2c FDs**: `openrgb.service` (with `Restart=always`) held open FDs on all 7 dGPU i2c adapters, causing `i2c_del_adapter()` to hang in uninterruptible D state during amdgpu unbind. Fix: `systemctl stop openrgb` before unbinding.
   - **GNOME Shell using dGPU**: GDM uses dGPU for GPU-accelerated rendering. Fix: stop GDM before unbinding, run wrapper as `systemd-run` transient service.
   - **GDM monitors.xml mismatch**: Both dGPU DP-1 and iGPU HDMI-3 connected to same monitor; config must include `<disabled>` for DP-1.

#### libvirt Hook Deadlock Issues
Multiple approaches to automate GPU reset via libvirt hooks failed due to deadlocks:
- **`systemctl` calls from hooks**: Hooks are called synchronously by libvirtd, causing deadlocks.
- **`virsh` calls from hooks**: Same deadlock issue.
- **Backgrounding**: libvirtd waits for all child processes.

**Solution**: Replaced all hooks with a no-op (`exit 0`). All lifecycle management is handled by `/usr/local/bin/vm-overwatch` wrapper script which runs outside libvirtd.

### USB Issues

#### Razer Tartarus V2 Re-enumeration
The Tartarus V2 re-enumerates on the USB bus (changes device number) after passthrough, causing libvirt to grab a stale device address. Fixed by removing hardcoded `<address bus=... device=...>` from USB hostdev source entries in VM XML.

~~Previously included a detach/reattach cycle 30s after VM start as a workaround for USB hub timing issues. Removed — not needed with direct USB connections (no hub). The hack was preventing Razer Synapse from detecting the Tartarus.~~

#### Hardcoded USB Addresses
Libvirt saves host bus/device addresses into the running VM config. On next boot, these addresses may be stale. Fixed by stripping `<address bus=... device=...>` from all USB `<source>` blocks in the persistent config.

### Network Issues

#### Bridge Not Attaching After Suspend/Resume
The pre-VM suspend/resume (GPU hardware reset) causes NetworkManager to tear down `br0` — it detaches `enp9s0` from the bridge. After resume, it takes ~25-35 seconds for NetworkManager to re-attach the port, detect carrier, and obtain a DHCP lease. Without waiting, the VM starts with a non-functional bridge and has no network connectivity.

**Fix**: Added a polling loop in the wrapper script that waits for `br0` to have both link carrier and an IP address (up to 60 seconds) before starting the VM. Typical wait is ~24 seconds.

---

## VM XML Reference

The VM "overwatch" is defined in libvirt. Key elements:

```xml
<!-- Anti-cheat -->
<features>
  <hyperv mode="custom">
    <relaxed state="on"/>
    <vapic state="on"/>
    <spinlocks state="on" retries="8191"/>
    <vendor_id state="on" value="AuthenticAMD"/>
  </hyperv>
  <kvm><hidden state="on"/></kvm>
</features>

<!-- CPU pinning -->
<cputune>
  <vcpupin vcpu="0" cpuset="1"/>
  <!-- ... through vcpu 6 / cpuset 7 -->
</cputune>
<cpu mode="host-passthrough" check="none" migratable="off">
  <topology sockets="1" dies="1" cores="7" threads="1"/>
  <cache mode="passthrough"/>
</cpu>

<!-- GPU passthrough with ROM file (managed=no — wrapper handles driver binding) -->
<hostdev mode="subsystem" type="pci" managed="no">
  <driver name="vfio"/>
  <source><address domain="0x0000" bus="0x03" slot="0x00" function="0x0"/></source>
  <rom bar="off" file="/usr/share/qemu/gpu-rom.bin"/>
</hostdev>

<!-- GPU audio (managed=no) -->
<hostdev mode="subsystem" type="pci" managed="no">
  <driver name="vfio"/>
  <source><address domain="0x0000" bus="0x03" slot="0x00" function="0x1"/></source>
</hostdev>

<!-- USB devices matched by vendor/product only (no hardcoded bus/device) -->
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x29ea"/><product id="0x0102"/></source>
</hostdev>
<!-- ... etc for all USB devices -->
```

---

## Daily Usage (Current)

### Start gaming
```bash
# Use the "Overwatch" desktop shortcut, which runs:
#   systemd-run --unit=vm-overwatch /usr/local/bin/vm-overwatch
# Flow: disable GPU runtime PM → stops ollama/openrgb/GDM → unbinds amdgpu
#       → MODE1 reset (509ms) → binds vfio-pci → starts VM
#       → blanks iGPU (monitor auto-switches to DP) → performance tuning
#       → waits for VM shutdown
#       → unbinds vfio-pci → MODE1 reset (509ms) → binds amdgpu
#       → unblanks iGPU → starts openrgb/ollama/GDM
```

### Stop gaming
Shut down Windows from the Start menu. The wrapper script handles GPU reset, display switching, and service restart.

The GPU is software-reset via MODE1 (SMU debug mailbox) on both sides of the VM lifecycle. No suspend/resume, no network disruption, no reboot needed between sessions. The monitor auto-switches between HDMI (iGPU/Linux) and DisplayPort (dGPU/VM) via iGPU framebuffer blanking.

### Monitor
```bash
journalctl -u vm-overwatch -f   # Live logs
cat /dev/navi31-reset            # GPU health (SOL + bootloader)
ls /var/log/vm-overwatch/        # Persistent per-run logs
vm-overwatch --verbose           # Full bash trace logging
```

---

## Troubleshooting Reference

| Problem | Cause | Solution |
|---|---|---|
| "Failed to set group container: Invalid argument" | IVRS ACPI table exclusion ranges | IVRS table override (zeroed flags, OEM rev bump) |
| "kernel is locked down, ignoring table override" | Secure Boot enabled | Disable Secure Boot in BIOS |
| IVRS override not applied | OEM revision same as original | Bump OEM revision to 2 |
| White screen on iGPU | `amd_iommu=force_isolation` breaks iGPU DMA | Remove `force_isolation`, use patched IVRS alone |
| GPU not visible in Windows | GPU never initialized, QEMU can't read ROM | Download VBIOS from TechPowerUp, add as ROM file |
| "failed to find romfile" | QEMU sandbox restricts file access | Place ROM in `/usr/share/qemu/` |
| Xorg fails to start (GDM crash loop) | Xorg picks discrete GPU (on vfio-pci) instead of iGPU | Create `/usr/share/X11/xorg.conf.d/20-igpu.conf` with `BusID "PCI:116:0:0"` (only needed for X11 fallback) |
| YouTube won't load in VM | NAT/QUIC issues | Switch to bridged networking |
| Tartarus not detected in VM | USB re-enumeration, stale addresses | Remove hardcoded `<address bus=... device=...>` from USB source entries in VM XML. ~~Old hub workaround: detach/reattach cycle (30s delay) — removed, not needed with direct USB connections~~ |
| VM has no internet (old suspend/resume method) | br0 bridge torn down during suspend/resume | ~~Wait for br0~~ — no longer needed with MODE1 reset (no suspend) |
| Grey/black screen on 2nd VM start | Navi 31 GPU reset bug | MODE1 reset via `navi31_reset` module before and after each VM session |
| Black screen on 1st VM start after amdgpu | GPU in driver-teardown state, not power-on-reset | Pre-VM MODE1 reset after unbinding amdgpu |
| amdgpu unbind hangs (D state, i2c_del_adapter) | OpenRGB holding `/dev/i2c-*` FDs via DP AUX I2C adapters | `systemctl stop openrgb` before unbinding |
| amdgpu unbind hangs (D state, drm_dev_unplug) | GDM/GNOME Shell has DRM card FDs open (multi-GPU) | `systemctl stop gdm` before unbinding |
| GPU soft lockup after loading navi31_reset | Module used `pci_enable_device_mem`/`pci_disable_device` alongside amdgpu | Use direct `ioremap` of BAR5, never call `pci_enable_device` |
| Reset blocked ("Device or resource busy") | Driver still bound to GPU | Unbind amdgpu/vfio-pci first, or use `force_mode1` if driver is in teardown |
| vfio-pci bind fails after PCI rescan | Kernel auto-probes amdgpu on rescan | Unbind auto-probed amdgpu before setting driver_override and binding vfio-pci |
| libvirt hooks deadlock | Hooks call systemctl/virsh synchronously | Use wrapper script instead of hooks |
| No display after VM shutdown | iGPU display goes to DPMS off | `systemctl restart gdm` (handled by wrapper script) |
| GDM wrong aspect ratio (single GPU) | monitors.xml connector mismatch | Update connector name (e.g. `HDMI-1` → `HDMI-3` when dGPU on amdgpu shifts numbering) |
| GDM wrong aspect ratio (dual GPU) | Both dGPU DP-1 and iGPU HDMI-3 connected to same monitor; monitors.xml lists only one output so config doesn't match and GDM falls back to auto (3840x2160) | Add `<disabled>` section for DP-1 in monitors.xml |
| GNOME Shell crashes when GPU unbinds | dGPU used for GPU-accelerated rendering | Stop GDM before unbinding amdgpu; run wrapper via `systemd-run` |
| Wrapper script dies when GDM stops | Script runs in GNOME terminal session | Use `systemd-run --unit=vm-overwatch` transient service |
| Audio volume much lower in VM than native Windows | Windows volume slider shows 100% but internal state out of sync after USB passthrough | Move volume slider to 0% then back to 100% to force Windows to re-apply the level. Also check: SteelSeries GG EQ/gain settings, Volume Mixer per-app levels, Loudness Equalization (if accessible via device properties). Note: `mmsys.cpl` may freeze the VM — use Settings → System → Sound instead |
| GPU reads 0xffffffff between service stop and unbind | GPU runtime PM puts device in D3 (PCIe link down) when all DRM FDs close after GDM stops | `echo on > /sys/bus/pci/devices/$GPU/power/control` before stopping services. Safety net: if GPU unresponsive at unbind time, use PCI remove/rescan instead of amdgpu unbind |
| Concurrent vm-overwatch instances cause dirty state | Second instance finds GPU on vfio-pci, tries to operate on poisoned state | Lock file via `flock /run/vm-overwatch.lock` prevents concurrent instances |
| Windows BSOD 0x9F DRIVER_POWER_STATE_FAILURE | Windows "Balanced" power plan sends power IRPs to passthrough GPU/USB devices; vfio-pci owns the hardware so guest driver can't complete power transitions | Switch to **High Performance** power plan; disable PCI Express ASPM, USB selective suspend, display timeout, sleep, hybrid sleep (see Windows VM Power Settings section) |
| Need to manually switch monitor input | iGPU HDMI stays active when VM starts on DP, monitor doesn't auto-switch | Blank iGPU framebuffer (`echo 4 > /sys/class/graphics/fbN/blank`) when VM starts; monitor auto-detects to DP. Unblank (`echo 0`) before GDM restarts. fb matched by PCI device path, not hardcoded number |

---

## Windows VM Power Settings

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

**AMD driver version** (as of 2026-02-23): Radeon Software 32.0.23017.1001 (2026-01-08), with AMD Crash Defender 25.30.0.3.

---

## TODO

- [x] **Test full VM lifecycle (first cycle)** — Verified: GDM stops, GPU switches to vfio-pci, VM starts, Windows visible on DP. Shutdown triggers suspend/resume reset, GPU returns to amdgpu, all services restart, GDM at correct 3440x1440 21:9.
- [x] **Test GPU reset (second cycle)** — Verified: Second VM start without rebooting shows Windows on DP. Navi 31 GPU reset bug solved via dual suspend/resume.
- [x] **Fix for Navi 31 GPU reset bug** — Solved: PCI remove → suspend/resume → PCI rescan on both sides of VM lifecycle.
- [x] **GDM monitors.xml stability** — Verified: GDM consistently shows 3440x1440 21:9 after wrapper restarts GDM. monitors.xml with DP-1 disabled works.
- [x] **Test Overwatch gameplay** — Verified: Overwatch runs, game performance good, no anti-cheat issues.
- [x] **Fix VM networking** — ~~Bridge readiness check after suspend/resume~~ No longer needed — MODE1 reset doesn't disrupt networking.
- [x] **Fix Tartarus USB passthrough** — ~~Detach/reattach workaround removed~~ — only needed with USB hubs. With direct connections, just ensure no hardcoded `<address bus=... device=...>` in USB source entries.
- [x] **VBIOS reverse engineering / standalone GPU reset** — Built `navi31_reset` kernel module implementing MODE1 reset via SMU debug mailbox. Replaces suspend/resume with 509ms software reset. Integrated into `vm-overwatch`. Details at `vbios-reverse-engineering-plan.md`.
- [x] **Disable Windows Backup reminder** — Disabled via registry: `BackupNotificationDisabled=1`, `BackupReminder toast Enabled=0`, `BackupSettingsRoaming=0` (applied via QEMU guest agent).
- [x] **Install QEMU guest agent** — Installed `qemu-ga-x86_64.msi` from virtio-win ISO, plus VirtIO Serial driver via Device Manager. Channel added to VM XML. Agent v110.0.2 working.
- [x] **Fix GPU D3 sleep during teardown** — GPU runtime PM disabled before stopping services (`echo on > power/control`). Safety net: PCI remove/rescan if GPU unresponsive at unbind time.
- [x] **Auto display switching** — iGPU framebuffer blanking (`echo 4 > fbN/blank`) when VM starts, unblank before GDM restarts. Monitor auto-detects between HDMI (iGPU) and DP (dGPU).
- [x] **Error logging and diagnostics** — ERR trap with line numbers, state snapshots at 10+ checkpoints, persistent logs in `/var/log/vm-overwatch/`, `--verbose` flag for full bash trace.
- [x] **Prevent concurrent instances** — Lock file via `flock /run/vm-overwatch.lock`.
- [x] **Fix Windows BSOD during gameplay** — 6× 0x9F (DRIVER_POWER_STATE_FAILURE) caused by Balanced power plan + PCI Express ASPM on passthrough devices. Fixed: High Performance plan, ASPM off, USB selective suspend off, all timeouts disabled.

---

## Shopping List

- [x] **HDMI cable** — motherboard HDMI output to monitor HDMI1
- [x] Windows 11 (installed in VM)
- [x] Fix for Navi 31 GPU reset bug (dual suspend/resume)
