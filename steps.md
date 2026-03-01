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
| UUID | `ee9489dc-57fe-4405-ace6-73dcf9074201` | `<uuid>` in VM XML |
| MAC address | `aa:bb:cc:dd:ee:ff` | `<mac address>` in VM XML (Realtek OUI) |
| SMBIOS system | MS-7E49 / Micro-Star International | `<sysinfo>` in VM XML |

Activation steps:

1. Boot the VM and sign in with a Microsoft account that has a Windows 11 Pro digital license
2. Go to Settings > System > Activation — confirm it says "Windows is activated with a digital license linked to your Microsoft account"
3. Switch to a local account: Settings > Accounts > Your info > "Sign in with a local account instead"
4. Enable auto-login (no password prompt):

```bash
# From the host, via guest agent (uses Set-ItemProperty to avoid reg.exe empty-string escaping issues):
sudo virsh qemu-agent-command overwatch '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-Command","$p = \"HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\"; Set-ItemProperty $p AutoAdminLogon 1; Set-ItemProperty $p DefaultUserName myuser; Set-ItemProperty $p DefaultPassword \"\""],"capture-output":true}}'
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

Configure the Windows guest for GPU passthrough stability and performance. All commands run from devbox via the guest agent on myhost.

### TDR timeout

Extend the GPU Timeout Detection and Recovery deadline from the default 2s to 60s. Under passthrough, the AMD driver's WDDM init takes longer because every GPU register access goes through VFIO's MMIO trap-and-forward path. Combined with Windows Defender boot contention, init can exceed the default timeout, causing a watchdog reset (black screen → recovery). 25s still produced dumps; 60s eliminated them (0/4).

```bash
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"\$p = \\\"HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Control\\\\GraphicsDrivers\\\"; Set-ItemProperty \$p -Name TdrDelay -Value 60 -Type DWord; Set-ItemProperty \$p -Name TdrDdiDelay -Value 60 -Type DWord\"],\"capture-output\":true}}"'
```

Verify:

```bash
# Check registry values
ssh myhost 'sudo virsh qemu-agent-command overwatch ...'
# Expected: TdrDelay=60, TdrDdiDelay=60

# Check LiveKernelReports for new dumps after reboot
ssh myhost 'sudo virsh qemu-agent-command overwatch ...'
# Expected: no new WATCHDOG dumps after the change
```

### AMD HD Audio driver removal

Removes the AMD HD Audio driver (`atihdwt6.inf`) from the Windows driver store. The GPU audio function (03:00.1) is passed through, but the HDAudBus driver sends power IRPs during GPU state transitions that vfio-pci can't handle — causing TDR and 0x9F BSODs.

Steps: disable the devices, remove the device nodes, then delete the driver from the store.

```bash
# Disable all AMD HD Audio devices
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"Get-PnpDevice | Where-Object InstanceId -like \\\"HDAUDIO*VEN_1002*\\\" | ForEach-Object { Disable-PnpDevice -InstanceId \$_.InstanceId -Confirm:0 -EA SilentlyContinue; Write-Output \\\"Disabled: \$(\$_.InstanceId)\\\" }\"],\"capture-output\":true}}"'

# Remove device nodes
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"Get-PnpDevice | Where-Object InstanceId -like \\\"HDAUDIO*VEN_1002*\\\" | ForEach-Object { pnputil /remove-device \$_.InstanceId }\"],\"capture-output\":true}}"'

# Find and delete the driver from the store
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"pnputil /enum-drivers /class MEDIA\"],\"capture-output\":true}}"'
# Find the oem*.inf with atihdwt6.inf as Original Name, then:
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"pnputil /delete-driver oem28.inf /force\"],\"capture-output\":true}}"'
```

Verify:

```bash
# No AMD HD Audio devices should be listed
ssh myhost 'sudo virsh qemu-agent-command overwatch ...'
# Expected: no HDAUDIO*VEN_1002* devices

# atihdwt6.inf should not be in the driver store
ssh myhost 'sudo virsh qemu-agent-command overwatch ...'
# Expected: no AtiHDAudio entry in pnputil /enum-drivers /class MEDIA
```

### Power settings & AMD driver tuning

Sets High Performance power plan, disables ULPS, deep sleep, and DRMDMA power off. Already applied and active.

### OneDrive removal

```bash
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"Stop-Process -Name OneDrive -Force -EA SilentlyContinue; Start-Process \\\"C:\\\\Windows\\\\System32\\\\OneDriveSetup.exe\\\" -ArgumentList \\\"/uninstall\\\" -Wait\"],\"capture-output\":true}}"'
```

### Windows suggestion toasts

Disables OneDrive privacy toasts and other Windows "suggestion" notifications:

```bash
ssh myhost 'sudo virsh qemu-agent-command overwatch "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-Command\",\"New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -EA SilentlyContinue | Out-Null; \$sid = \\\"S-1-5-21-XXXXXXXXXX-XXXXXXXXXX-XXXXXXXXXX-1001\\\"; \$cdm = \\\"HKU:\\\\\$sid\\\\SOFTWARE\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\ContentDeliveryManager\\\"; Set-ItemProperty \$cdm -Name SubscribedContent-310093Enabled -Value 0 -EA SilentlyContinue; Set-ItemProperty \$cdm -Name SubscribedContent-338389Enabled -Value 0 -EA SilentlyContinue; Set-ItemProperty \$cdm -Name SubscribedContent-338393Enabled -Value 0 -EA SilentlyContinue; Set-ItemProperty \$cdm -Name SilentInstalledAppsEnabled -Value 0 -EA SilentlyContinue\"],\"capture-output\":true}}"'
```

### Pending guest config

- Defender exclusions for AMD driver paths
- AMD telemetry disable (AUEPLauncher + StartAUEP)
- Display config (Auto HDR off, Game Bar off)
- Shutdown signal (UDP packet to host on Windows shutdown)
- Razer Synapse delayed start (Tartarus deferred attach implemented in overwatch.sh)

**Note:** `AutoAdminLogon` (step 9) tends to reset to `0` after account changes or failed logins. If Windows prompts for credentials after a reboot, re-apply it:

```bash
sudo virsh qemu-agent-command overwatch '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-Command","Set-ItemProperty \"HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\" AutoAdminLogon 1"],"capture-output":true}}'
```

## 12. Lifecycle script (dynamic GPU binding)

The lifecycle script (`overwatch.sh`) manages the full VM lifecycle: stops host services, swaps the GPU from amdgpu to vfio-pci, starts the VM, waits for shutdown, then restores everything. This eliminates the need for host reboots between VM sessions.

### Phase A: Install script (while still on static vfio-pci)

```bash
# Copy script and service to myhost
scp scripts/overwatch.sh myhost:/tmp/overwatch.sh
scp scripts/overwatch.service myhost:/tmp/overwatch.service

# Install
ssh myhost 'sudo install -m 755 /tmp/overwatch.sh /usr/local/bin/overwatch'
ssh myhost 'sudo cp /tmp/overwatch.service /etc/systemd/system/overwatch.service'
ssh myhost 'sudo systemctl daemon-reload'
```

Verify:

```bash
ssh myhost 'sudo overwatch status'
# Expected: GPU/VM/service state summary

ssh myhost 'bash -n /usr/local/bin/overwatch && echo "Syntax OK"'
# Expected: Syntax OK
```

Test start/stop cycle (GPU is still on static vfio-pci, so the script skips the driver swap):

```bash
ssh myhost 'sudo systemctl start overwatch'
# Expected: VM starts, script waits for shutdown

# Shut down the VM from inside Windows, then check:
ssh myhost 'journalctl -u overwatch --no-pager -n 50'
# Expected: clean start → wait → shutdown → restore sequence
```

### Phase B: Switch to dynamic binding

Remove static vfio-pci binding so the GPU boots on amdgpu:

```bash
# Remove static binding files
ssh myhost 'sudo rm /etc/modprobe.d/vfio.conf'
ssh myhost 'sudo rm /etc/modules-load.d/vfio-pci.conf'

# Disable GPU runtime PM (crashes on D3 resume)
ssh myhost 'echo "options amdgpu runpm=0" | sudo tee /etc/modprobe.d/amdgpu.conf'

# Prevent GDM from using the dGPU (seat rule empties seat assignment)
ssh myhost 'echo '\''ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}=="pci-0000:03:00.0", ENV{ID_SEAT}=""'\'' | sudo tee /etc/udev/rules.d/99-gpu-passthrough.rules'

# Rebuild initramfs and reboot
ssh myhost 'sudo update-initramfs -u && sudo reboot'
```

### Phase C: Verify dynamic binding

After reboot, the GPU should be on amdgpu (not vfio-pci):

```bash
ssh myhost 'lspci -nnk -s 03:00.0 | grep "driver in use"'
# Expected: Kernel driver in use: amdgpu

ssh myhost 'lspci -nnk -s 03:00.1 | grep "driver in use"'
# Expected: Kernel driver in use: snd_hda_intel
```

Test the full lifecycle:

```bash
# Start VM (script swaps GPU to vfio-pci)
ssh myhost 'sudo systemctl start overwatch'

# Verify GPU is on vfio-pci
ssh myhost 'lspci -nnk -s 03:00.0 | grep "driver in use"'
# Expected: Kernel driver in use: vfio-pci

ssh myhost 'sudo virsh domstate overwatch'
# Expected: running

# Shut down the VM from inside Windows, then verify host restored:
ssh myhost 'lspci -nnk -s 03:00.0 | grep "driver in use"'
# Expected: Kernel driver in use: amdgpu

ssh myhost 'systemctl is-active gdm ollama openrgb'
# Expected: active (for each)

ssh myhost 'journalctl -u overwatch --no-pager -n 50'
# Expected: clean lifecycle with no errors
```

If the GPU fails to rebind after stop (shows `unbound` or header type '127'), the stop sequence logs a warning but the host remains usable on the iGPU. Check `sudo dmesg | grep -i amdgpu` for errors. A host reboot will reset the GPU to a clean state.
