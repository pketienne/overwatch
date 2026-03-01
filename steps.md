# Overwatch VM Setup Steps

## Motherboard Firmware Quality (VFIO Passthrough)

GPU passthrough depends heavily on standards-compliant UEFI firmware. Motherboard vendors vary significantly in firmware quality for VFIO use cases:

| Vendor | Reputation | Notes |
|--------|-----------|-------|
| **ASRock** | Best | Clean IOMMU groups, honors IGD/dGPU settings, standards-compliant ACPI tables. Most recommended in VFIO communities. |
| **ASUS** | Good (high-end) | ROG/ProArt boards generally solid. Budget boards can have quirks. |
| **Gigabyte** | Mixed | Some good, some problematic. Check specific board before buying. |
| **MSI** | Poor | Most complaints in VFIO forums. Firmware ignores its own settings and ships broken ACPI tables. |

**MSI MPG X870E CARBON WIFI firmware bugs encountered in this project:**
1. **IVRS ACPI table** — Ships with IVMD exclusion flags that block VFIO container setup. Required patching the ACPI table and loading via early initrd (step 2).
2. **Boot VGA assignment** — Ignores "Initiate Graphic Adapter = IGD" BIOS setting. Initializes the dGPU as boot display regardless, including the BIOS setup screen itself. No workaround at the firmware level.

If building a new passthrough rig, check the [VFIO subreddit](https://reddit.com/r/VFIO) and [Level1Techs forums](https://forum.level1techs.com) for reports on the specific board before buying.

## Anti-Cheat Mitigations (Ricochet)

Ricochet is a kernel-level anti-cheat. These mitigations reduce the likelihood of VM detection.

| # | Mitigation | Status | How |
|---|---|---|---|
| 1 | KVM CPUID hidden | Done | `<kvm><hidden state='on'/>` in VM XML |
| 2 | Hyper-V vendor ID spoofed | Done | `<vendor_id value='AuthenticAMD'/>` in VM XML |
| 3 | CPU host-passthrough | Done | Real Ryzen 9800X3D CPUID exposed to guest |
| 4 | Real SMBIOS strings | Done | `qemu:commandline` with `-smbios` type 0/1/2 (real host values) |
| 5 | Real GPU passthrough | Done | Physical RX 7900 XTX, not emulated |
| 6 | Realistic MAC address | Done | Realtek OUI (34:5a:60:) instead of QEMU's 52:54:00: |
| 7 | SCSI disk (no virtio-blk fingerprint) | Done | VirtIO SCSI controller, avoids "Red Hat virtio" in device enumeration |
| 8 | Realistic disk identity | Done | `-global scsi-hd.vendor/product` spoofs Samsung SSD; fixed serials |
| 9 | Windows Defender + Tamper Protection | Guest-side | Must remain ON — Ricochet checks OS security features |
| 10 | RDTSC timing | Automatic | host-passthrough exposes real TSC + invtsc; timing profile near bare metal |
| 11 | ACPI table strings | Not done | QEMU embeds "BOCHS"/"BXPC" in ACPI OEM IDs; spoofable but uncommon detection vector |

### Guest Identity Verification

What the guest sees (all clean — no QEMU/VM fingerprints):

| Field | Value |
|---|---|
| BIOS Vendor | American Megatrends International, LLC. |
| BIOS Version | 1.A80 |
| BIOS Serial | To be filled by O.E.M. |
| System Vendor | Micro-Star International Co., Ltd. |
| System Name | MS-7E49 |
| System UUID | EE9489DC-57FE-4405-ACE6-73DCF9074201 |
| Board Manufacturer | Micro-Star International Co., Ltd. |
| Board Product | MPG X870E CARBON WIFI (MS-7E49) |
| Board Serial | XXXXXXXXXX |
| Disk Model | Samsung SSD 870 EVO 1TB |
| Disk Serials | S6XWNG0R401283 (OS), S6XWNG0R401297 (Games) |
| MAC Address | 34-5A-60-B2-E7-41 (Realtek OUI) |
| GPU | AMD Radeon RX 7900 XTX (real hardware) |

**Note:** Libvirt's `<sysinfo>` block is silently ignored when using OVMF firmware — the SMBIOS entries must be passed via `qemu:commandline` with `-smbios` flags. Commas in values must be doubled (`,,`) to escape QEMU's parameter parser.

## 0. BIOS Settings (MSI MPG X870E CARBON WIFI, BIOS 1.A80)

Manual step — must be done in BIOS setup (DEL at boot).

| Setting | Value | Location |
|---|---|---|
| IOMMU | **Enabled** | OC > Advanced CPU Configuration > AMD CBS |
| SVM Mode | **Enabled** | OC > Advanced CPU Configuration > AMD CBS |
| Initiate Graphic Adapter | **IGD** | Advanced > Integrated Graphics Configuration |
| Integrated Graphics | **Force** | Advanced > Integrated Graphics Configuration |
| Hybrid Graphics | **Disabled** | Advanced > Integrated Graphics Configuration |
| Re-Size BAR Support | **Enabled** | Advanced > PCIe Subsystem Settings |
| Above 4G Decoding | **Enabled** | Advanced > PCIe Subsystem Settings |
| Secure Boot | **Disabled** | Security > Secure Boot |

- **IOMMU + SVM**: Required for VFIO GPU passthrough and KVM virtualization.
- **IGD + Force + Hybrid off**: Forces the iGPU as the host's primary display, freeing the discrete GPU for passthrough.
- **Re-Size BAR + Above 4G**: Allows the VM to map the full GPU VRAM (needed for 24GB on the 7900 XTX). ReBAR does NOT cause Code 43 — the fix is the proper VBIOS (step 5).
- **Secure Boot disabled**: Host Secure Boot conflicts with custom VFIO kernel modules. The VM gets its own Secure Boot via OVMF.

## 1. Enable IOMMU

Add `amd_iommu=on iommu=pt` to the kernel command line:

```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on iommu=pt"/' /etc/default/grub
sudo update-grub
sudo reboot
```

- `amd_iommu=on` — enables the IOMMU hardware
- `iommu=pt` — passthrough mode, sets up 1:1 DMA mappings by default (better performance for devices not behind VFIO)

Verify after reboot:

```bash
# Confirm IOMMU is in the kernel cmdline
grep amd_iommu /proc/cmdline
# Expected: ... amd_iommu=on ...

# Confirm IOMMU is active in dmesg
sudo dmesg | grep -i 'iommu'
# Expected: lines showing AMD-Vi / IOMMU enabled

# List IOMMU groups — GPU should be in its own group
for d in /sys/kernel/iommu_groups/*/devices/*; do
  g=$(echo $d | cut -d/ -f5)
  dev=$(basename $d)
  echo "Group $g: $(lspci -nns $dev)"
done | sort -t: -k1 -n
# Expected: GPU and audio in separate, single-device groups:
#   Group 15: 03:00.0 VGA compatible controller [0300]: ... Navi 31 [Radeon RX 7900 XT/7900 XTX/7900M] [1002:744c]
#   Group 16: 03:00.1 Audio device [0403]: ... Navi 31 HDMI/DP Audio [1002:ab30]
# Both isolated — no ACS override needed.
```

## 2. Patch IVRS ACPI table

Even with IOMMU correctly enabled in both BIOS and GRUB, VFIO passthrough will fail on this board with:

> `vfio 0000:03:00.0: Firmware has requested this device have a 1:1 IOMMU mapping, rejecting configuring the device without a 1:1 mapping`

This is a firmware bug in the MSI MPG X870E CARBON WIFI (BIOS 1.A80). The IVRS (I/O Virtualization Reporting Structure) ACPI table — generated by the motherboard firmware — contains three IVMD (I/O Virtualization Memory Definition) entries with exclusion flags (`0x08` at offsets `0xC9`, `0xE9`, `0x109`). These tell the kernel that certain devices require 1:1 IOMMU mappings, which is incompatible with VFIO's container model. The kernel refuses to let VFIO set up its own IOMMU domain for the GPU.

`iommu=pt` alone does not fix this — the exclusion flags are checked regardless of the IOMMU mode.

Fix: patch the IVRS table to zero the exclusion flags, bump the OEM revision so the kernel prefers our override, and load it as an early initrd.

### 2.1 Extract and patch

```bash
sudo python3 -c "
import struct
with open('/sys/firmware/acpi/tables/IVRS', 'rb') as f:
    data = bytearray(f.read())
# Zero IVMD exclusion flags
data[0xC9] = 0x00
data[0xE9] = 0x00
data[0x109] = 0x00
# Bump OEM revision (kernel requires higher revision to accept override)
struct.pack_into('<I', data, 0x18, 2)
# Recalculate checksum
data[9] = 0
checksum = (256 - (sum(data) % 256)) % 256
data[9] = checksum
with open('/tmp/ivrs-patched.dat', 'wb') as f:
    f.write(data)
print('Patched IVRS written')
"
```

### 2.2 Create CPIO initrd and configure GRUB

```bash
# Package as an early initrd
sudo mkdir -p /tmp/ivrs-initrd/kernel/firmware/acpi
sudo cp /tmp/ivrs-patched.dat /tmp/ivrs-initrd/kernel/firmware/acpi/ivrs.dat
cd /tmp/ivrs-initrd
find . -print0 | cpio --null --create --format=newc 2>/dev/null | sudo tee /boot/ivrs-override.img > /dev/null

# Tell GRUB to load it before the main initrd
echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="ivrs-override.img"' | sudo tee -a /etc/default/grub
sudo update-grub
sudo reboot
```

Verify after reboot:

```bash
sudo dmesg | grep -i ivrs
# Expected: "ACPI: IVRS ACPI table found in initrd" and "Table Upgrade: override [IVRS..."

# VFIO container should work now — test by starting the VM (step 5)
# If this error appears, the patch didn't take:
#   "failed to setup container for group 15: Failed to set group container: Invalid argument"
```

## 3. Install virtualization packages

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst ovmf
```

Verify:

```bash
# libvirtd is running
sudo systemctl is-active libvirtd
# Expected: active

# virsh works
sudo virsh list --all
# Expected: empty list, no errors

# OVMF firmware exists (Secure Boot variant)
ls /usr/share/OVMF/OVMF_CODE_4M.ms.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd
# Expected: both files listed

# User is in libvirt group
groups $USER | grep -o libvirt
# Expected: libvirt
```

## 4. GPU driver binding (dynamic, not static)

The GPU is shared between the VM (vfio-pci) and host workloads like ollama (amdgpu). At boot, amdgpu claims the GPU normally. The VM lifecycle script will swap drivers on demand:

- **VM start**: unbind amdgpu → bind vfio-pci
- **VM stop**: unbind vfio-pci → bind amdgpu

No boot-time config files needed. This will be handled by the lifecycle script (later step).

Verify the GPU is on amdgpu at boot (default state):

```bash
lspci -nnk -s 03:00.0 | grep "driver in use"
# Expected: Kernel driver in use: amdgpu

lspci -nnk -s 03:00.1 | grep "driver in use"
# Expected: Kernel driver in use: snd_hda_intel
```

## 5. Download GPU VBIOS

The passed-through GPU needs a VBIOS ROM file. The sysfs ROM dump (`/sys/bus/pci/devices/.../rom`) is only a ~112KB shadow copy — insufficient for VFIO. Download the full 2MB VBIOS from TechPowerUp matching your exact card (check subsystem ID with `lspci -nnk -s 03:00.0`).

For the Sapphire NITRO+ RX 7900 XTX Vapor-X (subsystem `1DA2:E471`):

```bash
wget -O /tmp/gpu-rom.bin 'https://www.techpowerup.com/vgabios/272613/272613.rom'
sudo cp /tmp/gpu-rom.bin /usr/share/qemu/gpu-rom.bin
sudo chmod 644 /usr/share/qemu/gpu-rom.bin
```

Verify:

```bash
ls -la /usr/share/qemu/gpu-rom.bin
# Expected: 2097152 bytes (2MB)

md5sum /usr/share/qemu/gpu-rom.bin
# Expected: 24295086c4ffec8eccb425fb9349cc8d
```

The VM XML references this file with `<rom bar='off' file='/usr/share/qemu/gpu-rom.bin'/>`. The `bar='off'` tells QEMU not to expose the ROM BAR to the guest (avoids conflicts with the physical ROM BAR).

## 6. Create VM disk and define VM

```bash
# Create 100GB sparse qcow2 disk
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/overwatch.qcow2 100G

# Define VM from XML (see overwatch.xml in repo root)
sudo virsh define overwatch.xml
```

Key VM settings (in `overwatch.xml`):
- 88 GB RAM, 6 vCPUs (host-passthrough, 2 cores reserved for host)
- UEFI + Secure Boot (OVMF with Microsoft keys)
- Anti-cheat: KVM hidden, Hyper-V vendor ID spoofed (AuthenticAMD), real SMBIOS from host board
- GPU passthrough: 03:00.0 (VGA) + 03:00.1 (audio)
- GPU VBIOS: `/usr/share/qemu/gpu-rom.bin` with `rom bar='off'` (downloaded from TechPowerUp, not sysfs dump)
- Realtek OUI MAC address (34:5a:60:xx:xx:xx) to avoid QEMU 52:54:00 fingerprint
- virtio disk, NAT networking, QEMU guest agent
- Spice + QXL for initial Windows install (before GPU driver)

Verify:

```bash
sudo virsh list --all
# Expected: overwatch   shut off

sudo virsh dumpxml overwatch | grep -E '<name>|memory|vcpu|hidden|vendor_id|mac address'
# Expected: name=overwatch, 88 GiB, 6 vcpu, hidden on, vendor_id AuthenticAMD, mac 34:5a:60:...
```

**Anti-cheat requirement (guest-side):** After Windows is installed, Windows Defender and Tamper Protection must remain **ON** at all times. Ricochet checks that OS security features are enabled. Never disable them.

## 7. Install Windows 11

The VM XML includes install media (Windows 11 ISO, VirtIO drivers ISO, autounattend floppy) and Spice+QXL display for initial setup. Boot the VM and connect via Spice:

```bash
sudo virsh start overwatch

# From another machine, connect to the Spice display
remote-viewer spice://<host-ip>:5900
```

The autounattend.xml automates most of the install. When prompted, select the 100GB disk partition. Windows will install and reboot several times.

Once at the Windows desktop:

1. **Install VirtIO drivers** — open the virtio-win ISO drive in File Explorer, run `virtio-win-gt-x64.msi`
2. **Install QEMU Guest Agent** — on the same ISO, run `guest-agent/qemu-ga-x86_64.msi`

Verify guest agent from the host:

```bash
sudo virsh qemu-agent-command overwatch '{"execute":"guest-ping"}'
# Expected: {"return":{}}
```

## 8. Post-install cleanup

Remove install media and Spice/QXL from the VM XML. With the proper VBIOS (step 5), the passed-through GPU outputs video directly — Spice/QXL is not needed after Windows install.

Changes to `overwatch.xml`:
- Remove Windows 11 ISO, VirtIO drivers ISO, autounattend floppy
- Remove Spice graphics and QXL video
- Change boot order to HD only (remove cdrom)

```bash
sudo virsh define overwatch.xml
```

**Note:** The GPU enters a bad PCI state (header type '127') after each VM shutdown. A host reboot is required before starting the VM again until the lifecycle script implements proper GPU reset (secondary bus reset). This is a known issue with RDNA3 GPUs that can't do a clean Function Level Reset (FLR).

```bash
# If VM fails to start with "Unknown PCI header type '127'":
sudo reboot
# After reboot:
sudo virsh start overwatch
```

## 9. Activate Windows and set up local account

Windows activation is tied to a hardware fingerprint. The following identifiers must remain stable across VM rebuilds to avoid re-activation:

| Identifier | Value | Where |
|---|---|---|
| UUID | `ee9489dc-57fe-4405-ace6-73dcf9074201` | `<uuid>` in VM XML (carried over from v1) |
| MAC address | `aa:bb:cc:dd:ee:ff` | `<mac address>` in VM XML (Realtek OUI) |
| SMBIOS system | MS-7E49 / Micro-Star International | `<sysinfo>` in VM XML |

Activation steps:

1. Boot the VM and sign in with a Microsoft account that has a Windows 11 Pro digital license
2. Go to Settings > System > Activation — confirm it says "Windows is activated with a digital license linked to your Microsoft account"
3. Switch to a local account: Settings > Accounts > Your info > "Sign in with a local account instead"
4. Enable auto-login (no password prompt):

```bash
# From the host, via guest agent:
sudo virsh qemu-agent-command overwatch '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-Command","reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" /v AutoAdminLogon /t REG_SZ /d 1 /f; reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" /v DefaultUserName /t REG_SZ /d myuser /f; reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" /v DefaultPassword /t REG_SZ /d \"\" /f"],"capture-output":true}}'
```

**Important:** The digital license survives switching to a local account. Once activated and linked to your Microsoft account, the license is tied to the hardware fingerprint, not the signed-in account. If you ever need to re-activate after a rebuild, keep the UUID and SMBIOS strings identical, sign in with the same Microsoft account, and use the Activation Troubleshooter > "I changed hardware on this device recently."

Verify:

```bash
sudo virsh qemu-agent-command overwatch '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-Command","Get-CimInstance SoftwareLicensingProduct | Where-Object PartialProductKey | Select-Object Name,LicenseStatus | Format-List"],"capture-output":true}}'
# Expected: LicenseStatus : 1 (activated)
```

## 10. Install AMD GPU drivers

Connect a monitor to the RX 7900 XTX. The passed-through GPU outputs video via the Microsoft Basic Display Adapter (thanks to the proper VBIOS in step 5).

**Prerequisite:** The proper 2MB VBIOS from TechPowerUp with `rom bar='off'` must be configured (step 5). Without it, the AMD driver reports Code 43. The 112KB sysfs ROM dump (`/sys/bus/pci/devices/.../rom`) is not sufficient — it's a shadow copy missing the full VBIOS initialization tables. ReBAR, multifunction PCI topology, and `video=efifb:off` do not affect Code 43.

In the guest:

1. Open Edge
2. Go to https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7900-xtx.html
3. Download and install the latest AMD Software: Adrenalin Edition
4. Reboot when prompted

Verify from the host:
```bash
sudo virsh qemu-agent-command overwatch '{"execute":"guest-exec","arguments":{"path":"powershell","arg":["-Command","Get-PnpDevice -Class Display | Select-Object Status,Name | Format-Table -AutoSize"],"capture-output":true}}'
# Expected: Status OK, Name AMD Radeon RX 7900 XTX
```

## 11. Guest configuration

Configure the Windows guest for GPU passthrough stability, performance, and Razer peripheral support. The v1 `setup-guest.sh` script automates all phases via the guest agent. Copy it to the host and run each phase:

```bash
scp archive/v1/scripts/setup-guest.sh myhost:/tmp/setup-guest.sh
ssh myhost 'chmod +x /tmp/setup-guest.sh'
```

### Phase 10: Power settings & AMD driver tuning

Sets High Performance power plan, disables PCI Express ASPM, USB selective suspend, display/sleep timeouts, and hybrid sleep. Disables AMD driver internal power management (ULPS, deep sleep, DRMDMA power off) to prevent GPU entering low-power states that cause hangs in passthrough.

```bash
sudo /tmp/setup-guest.sh power
```

### Phase 11: AMD HD Audio driver removal

Removes the AMD HD Audio driver (`AtiHDAudioService`) from the Windows driver store. The GPU audio function (03:00.1) is passed through for HDMI/DP audio, but the HDAudBus driver sends power IRPs during shutdown that vfio-pci can't handle — causing 0x9F BSODs. Removing the driver prevents this.

```bash
sudo /tmp/setup-guest.sh hda-audio
```

### Phase 12: Defender exclusions & AMD telemetry

Adds Windows Defender exclusions for AMD driver paths and processes (prevents Defender from scanning driver files during GPU init, which can cause TDR timeouts). Disables AMD telemetry (AUEPLauncher service + StartAUEP scheduled task) — both launch paths must be disabled or AUEPMaster respawns every boot.

```bash
sudo /tmp/setup-guest.sh defender
sudo /tmp/setup-guest.sh telemetry
```

### Phase 13: Display configuration

Disables Auto HDR (causes flickering with passthrough), Game Bar (unnecessary overhead), and Auto HDR toast notifications. These are per-user settings — the guest must have a user logged in.

```bash
sudo /tmp/setup-guest.sh display
```

### Phase 14: Shutdown signal

Installs a PowerShell script (`C:\ProgramData\overwatch\overwatch.ps1`) and a scheduled task that sends a UDP packet to the host when Windows initiates shutdown. Used by the lifecycle script to detect guest shutdown and begin GPU cleanup.

```bash
sudo /tmp/setup-guest.sh shutdown
```

### Razer Synapse delayed start

Disables Razer's auto-start via StartupApproved registry and creates a scheduled task that launches Synapse after a 15-second logon delay. This gives USB devices time to enumerate before Synapse starts. The Tartarus is currently in the VM XML (attached at boot); once the lifecycle script is built, it will be moved to deferred hot-attach so Synapse detects it via hot-plug.

```bash
sudo /tmp/setup-guest.sh synapse
```

### Verify all guest settings

```bash
sudo /tmp/setup-guest.sh verify
# Expected: All checks passed
```

**Note:** `AutoAdminLogon` (step 9) tends to reset to `0` after account changes or failed logins. If Windows prompts for credentials after a reboot, re-apply it:

```bash
sudo virsh qemu-agent-command overwatch '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-Command","reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" /v AutoAdminLogon /t REG_SZ /d 1 /f"],"capture-output":true}}'
```
