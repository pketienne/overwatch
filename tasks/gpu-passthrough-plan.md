# GPU Passthrough: Overwatch on Linux via Windows VM

## Goal

One-click GPU passthrough for Overwatch 2 on myhost. The RX 7900 XTX is switchable between host use (ollama, DaVinci Resolve, OBS) and VM use (gaming) without rebooting.

---

## Hardware Summary

- **CPU**: AMD Ryzen 7 9800X3D (8 cores, SMT disabled)
- **Discrete GPU**: Sapphire NITRO+ RX 7900 XTX Vapor-X (PCI `03:00.0`, IOMMU group 15, device ID `1002:744c`, subsystem `1DA2:E471`)
- **GPU Audio**: Navi 31 HDMI/DP Audio (PCI `03:00.1`, device ID `1002:ab30`)
- **Integrated GPU**: AMD `1002:13c0` (PCI `74:00.0`, IOMMU group 30)
- **Motherboard**: MSI MPG X870E CARBON WIFI (MS-7E49), BIOS 1.A80 (Jan 8, 2026)
- **RAM**: 96GB DDR5 (16GB allocated to VM)
- **Monitor**: LG ULTRAGEAR+ 45" OLED (3440x1440 native, HDMI to iGPU, DP to 7900 XTX)
- **Input**: Kinesis Advantage2 (29ea:0102), Razer Naga V2 Pro (1532:00a7), Razer Tartarus V2 (1532:022b), Razer Strider Chroma (1532:0c05), SteelSeries Arctis Pro Wireless (1038:1290 + 1038:1294)
- **Bootloader**: GRUB (Ubuntu, kernel 6.17.0-14-generic)
- **Host**: myhost (192.168.0.100), accessed via SSH from devbox (192.168.0.102)

---

## Current State

- Full GPU passthrough lifecycle without rebooting — unlimited VM cycles via driver bind/unbind (amdgpu <-> vfio-pci)
- Overwatch runs at 3440x1440 fullscreen with no anti-cheat issues
- iGPU display on Wayland at 3440x1440@85Hz on HDMI
- Automatic display switching — iGPU blanked when VM starts (monitor auto-detects to DP), unblanked on restore
- All USB devices passed through (keyboard, mouse, keypad, mousepad, headset)
- Windows 11 VM with UEFI, TPM 2.0, anti-cheat tweaks
- Bridged networking (VM gets own IP on LAN)
- IVRS ACPI table override to fix VFIO container setup
- One-click desktop shortcut: click -> play -> shut down Windows -> back to desktop
- Lock file prevents concurrent vm-overwatch instances

### Kernel Parameters

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
| `/usr/local/bin/vm-overwatch` | VM lifecycle script — stops services, switches GPU drivers, starts VM, waits for shutdown, restores host. Runs as systemd transient unit. Logs to journald |
| `/etc/modprobe.d/amdgpu.conf` | `options amdgpu runpm=0` — disables runtime PM to prevent GPU crashes during D3 resume |
| `/etc/udev/rules.d/99-gpu-passthrough.rules` | Prevents discrete GPU DRM device from getting a logind seat (stops GDM greeter on dGPU) |
| `/etc/modules-load.d/vfio-pci.conf` | Ensures vfio-pci module loads at boot |
| `/var/lib/gdm3/.config/monitors.xml` | GDM display config (3440x1440@85Hz on iGPU HDMI, dGPU DP disabled) |
| `/etc/libvirt/hooks/qemu` | No-op (`exit 0`) — prevents hook deadlocks with systemctl/virsh |
| `C:\ProgramData\vm-overwatch\notify-host-shutdown.ps1` | Sends UDP shutdown signal to vm-overwatch; triggered by `NotifyHostShutdown` scheduled task on Event ID 1074 |

---

## Rebuild Guide

### Phase 1: BIOS Settings

These must be set before the OS install (or at least before Phase 2).

| Setting | Value | Location (MSI MPG X870E CARBON WIFI) |
|---|---|---|
| IOMMU | Enabled | AMD CBS or Advanced |
| Initiate Graphic Adapter | **IGD** (iGPU primary) | Advanced > Integrated Graphics Configuration |
| Integrated Graphics | **Force** | Same section |
| HybridGraphics | **Disabled** | Same section |
| Secure Boot | **Disabled** | Security > Secure Boot |

**Note:** "Kernel DMA Protection" is **not exposed** in BIOS 1.A80 on this board. The IVRS ACPI table override (Phase 3) works around this.

---

### Phase 2: Install Virtualization Stack

```bash
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst virt-manager ovmf swtpm swtpm-tools bridge-utils irqbalance
sudo usermod -aG libvirt,kvm myuser
```

Verify:
```bash
virt-host-validate
# Should show all PASS for QEMU/KVM
```

---

### Phase 3: IVRS ACPI Table Override

**Why:** The motherboard's IVRS table declares exclusion ranges that block VFIO container setup ("Failed to set group container: Invalid argument"). We patch the table to zero these flags.

#### 3.1 Extract and patch the IVRS table

```python
import struct
with open("/sys/firmware/acpi/tables/IVRS", "rb") as f:
    data = bytearray(f.read())
# Zero IVMD exclusion flags
data[0xC9] = 0x00
data[0xE9] = 0x00
data[0x109] = 0x00
# Bump OEM revision (kernel requires higher revision to accept override)
struct.pack_into("<I", data, 0x18, 2)
# Recalculate checksum
data[9] = 0
checksum = (256 - (sum(data) % 256)) % 256
data[9] = checksum
with open("/tmp/ivrs-patched.dat", "wb") as f:
    f.write(data)
```

#### 3.2 Create CPIO initrd image

```bash
mkdir -p /tmp/ivrs-img/kernel/firmware/acpi
cp /tmp/ivrs-patched.dat /tmp/ivrs-img/kernel/firmware/acpi/ivrs.dat
cd /tmp/ivrs-img
find . -print0 | cpio --null --create --format=newc > /boot/acpi-ivrs-override.img
```

#### 3.3 Configure GRUB

In `/etc/default/grub`:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on"
GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi-ivrs-override.img"
```

**Do NOT use** `iommu=pt` or `amd_iommu=force_isolation` — the former is unnecessary, the latter breaks iGPU display (white screen due to broken display scanout DMA).

```bash
sudo update-grub
sudo reboot
```

#### 3.4 Verify

```bash
dmesg | grep -i ivrs
# Should show the patched table being loaded
dmesg | grep -i iommu
# Should show IOMMU groups without errors
```

---

### Phase 4: Network Bridge Setup

The VM uses bridged networking (gets its own LAN IP via DHCP). Create a bridge over the internet-facing NIC.

In `/etc/netplan/50-cloud-init.yaml` (or equivalent):
```yaml
network:
  version: 2
  ethernets:
    enp9s0:
      dhcp4: false
  bridges:
    br0:
      interfaces: [enp9s0]
      dhcp4: true
```

**Note:** Which NIC goes in the bridge depends on the final network topology. If myhost has two NICs, the bridge should be on the one facing the router/LAN. Verify before applying.

```bash
sudo netplan apply
```

Create a libvirt bridge network:
```bash
cat <<'EOF' > /tmp/bridged.xml
<network>
  <name>bridged</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF
virsh net-define /tmp/bridged.xml
virsh net-start bridged
virsh net-autostart bridged
```

---

### Phase 5: GPU ROM File

The discrete GPU boots on amdgpu, so its VBIOS ROM BAR may not be readable when QEMU needs it. A standalone ROM file is required.

1. Download the VBIOS from [TechPowerUp VGA BIOS Collection](https://www.techpowerup.com/vgabios/) — search for **Sapphire NITRO+ RX 7900 XTX Vapor-X** (subsystem ID `1DA2:E471`, ~2MB file)
2. Place it where QEMU's sandbox allows access:

```bash
sudo cp 272613.rom /usr/share/qemu/gpu-rom.bin
```

---

### Phase 6: Install Support Files

#### 6.1 vm-overwatch lifecycle script

```bash
sudo cp scripts/vm-overwatch.sh /usr/local/bin/vm-overwatch
sudo chmod +x /usr/local/bin/vm-overwatch
```

Source is in this repo at `scripts/vm-overwatch.sh`. The script manages the full GPU passthrough lifecycle:

1. **Pre-VM**: Stop services (ollama, openrgb, GDM) → release device FDs (`fuser -k` on DRM and i2c devices) → unbind VT consoles → unbind snd_hda_intel from GPU audio → unbind amdgpu → bind GPU + audio to vfio-pci
2. **VM running**: Start VM → re-attach USB devices (Kinesis, Tartarus detach/reattach to clear ghost entries) → blank iGPU → set CPU governor to `performance`, pin all IRQs to CPU 0, stop irqbalance, move RCU callbacks to CPU 0
3. **Post-VM**: Restore CPU governor to `powersave`, restart irqbalance → unbind vfio-pci → rebind VT consoles → bind amdgpu → PCI remove+rescan GPU audio (re-enumerates from D3cold) → disable runtime PM → unblank iGPU → restart services

#### 6.2 udev rules — seat prevention

Create `/etc/udev/rules.d/99-gpu-passthrough.rules`:
```
# Prevent the 7900 XTX from being assigned to any seat.
# This stops GDM from spawning a greeter on it.
# The render node remains available for compute (ollama).
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}=="pci-0000:03:00.0", ENV{ID_SEAT}=""
```

This clears the seat assignment on the dGPU's DRM device so logind doesn't assign it a seat. Without this, GDM would try to manage the dGPU output, interfering with GPU passthrough. The render node (`renderD128`) is unaffected and remains available for compute workloads (ollama).

**Note:** Runtime PM for the GPU is handled by `/etc/modprobe.d/amdgpu.conf` (`runpm=0`), not by udev rules.

#### 6.3 amdgpu runtime PM fix

Create `/etc/modprobe.d/amdgpu.conf`:
```
options amdgpu runpm=0
```

This prevents amdgpu from enabling runtime PM at the driver level. Without this, the GPU enters D3 during idle and crashes on resume (`device lost from bus`, soft lockup). The default `runpm=-1` (auto) enables runtime PM on desktop GPUs.

#### 6.4 Auto-load vfio-pci module

Create `/etc/modules-load.d/vfio-pci.conf`:
```
vfio-pci
```

#### 6.5 GDM monitors.xml

Copy your monitors.xml (with iGPU HDMI as primary, dGPU DP disabled) to both locations:
```bash
cp ~/.config/monitors.xml /var/lib/gdm3/.config/monitors.xml
sudo chown gdm:gdm /var/lib/gdm3/.config/monitors.xml
```

The monitors.xml must list the iGPU output (e.g. `HDMI-3`) as the active monitor at 3440x1440@85Hz, and mark the dGPU output (e.g. `DP-1`) as `<disabled>`. The exact connector names may change after reinstall — check with `gnome-display-settings` or `xrandr`.

#### 6.6 libvirt hooks (no-op)

Create `/etc/libvirt/hooks/qemu`:
```bash
#!/bin/bash
exit 0
```
```bash
sudo chmod +x /etc/libvirt/hooks/qemu
```

This prevents libvirt from running any hook logic (which causes deadlocks with systemctl/virsh). All lifecycle management is handled by the vm-overwatch wrapper.

#### 6.7 Passwordless sudo

The desktop shortcut (Phase 9) runs `sudo systemd-run ...` with `Terminal=false`, so there is no terminal to enter a password. The `myuser` user needs passwordless sudo for at least `systemctl` and `systemd-run`.

Create `/etc/sudoers.d/vm-overwatch`:
```
myuser ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop vm-overwatch, /usr/bin/systemd-run *
```

Or, if the user already has blanket NOPASSWD (`myuser ALL=(ALL) NOPASSWD: ALL`), no additional configuration is needed.

---

### Phase 7: Create the VM

#### 7.1 Create the disk

```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/overwatch.qcow2 200G
```

On the reinstalled system, this will be on the Samsung 990 PRO `@vms` subvolume (mounted at `/var/lib/libvirt/images`, with `nodatacow`).

#### 7.2 Define the VM

Use `virt-install` or import the XML from the VM XML Reference section. Key configuration:

| Setting | Value |
|---|---|
| **Name** | `overwatch` |
| **vCPUs** | 7, pinned to cores 1-7 (core 0 reserved for host) |
| **Topology** | 1 socket, 7 cores, 1 thread |
| **RAM** | 16 GB |
| **CPU** | host-passthrough, cache passthrough |
| **Firmware** | OVMF (UEFI) with TPM 2.0 (tpm-crb, emulator backend) |
| **Disk** | VirtIO, `/var/lib/libvirt/images/overwatch.qcow2` |
| **Network** | VirtIO NIC on `bridged` network (br0) |
| **Display** | None (remove Spice/QXL — native GPU output only) |

#### 7.3 GPU passthrough devices

```xml
<!-- GPU: managed=no (vm-overwatch handles driver binding) -->
<hostdev mode="subsystem" type="pci" managed="no">
  <driver name="vfio"/>
  <source><address domain="0x0000" bus="0x03" slot="0x00" function="0x0"/></source>
  <rom bar="off" file="/usr/share/qemu/gpu-rom.bin"/>
</hostdev>

<!-- GPU audio -->
<hostdev mode="subsystem" type="pci" managed="no">
  <driver name="vfio"/>
  <source><address domain="0x0000" bus="0x03" slot="0x00" function="0x1"/></source>
</hostdev>
```

**PCI addresses may change after reinstall.** Verify with:
```bash
lspci -nn | grep -i "navi\|7900"
# Expected: 03:00.0 and 03:00.1, but confirm
```

#### 7.4 Anti-cheat features

```xml
<features>
  <hyperv mode="custom">
    <relaxed state="on"/>
    <vapic state="on"/>
    <spinlocks state="on" retries="8191"/>
    <vendor_id state="on" value="AuthenticAMD"/>
  </hyperv>
  <kvm><hidden state="on"/></kvm>
</features>
```

#### 7.5 USB passthrough

All matched by vendor/product ID only — **no hardcoded bus/device addresses** (Tartarus V2 re-enumerates on the USB bus after passthrough, causing stale address references):

```xml
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x29ea"/><product id="0x0102"/></source>  <!-- Kinesis Advantage2 -->
</hostdev>
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x1532"/><product id="0x00a7"/></source>  <!-- Razer Naga V2 Pro -->
</hostdev>
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x1532"/><product id="0x022b"/></source>  <!-- Razer Tartarus V2 -->
</hostdev>
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x1532"/><product id="0x0c05"/></source>  <!-- Razer Strider Chroma -->
</hostdev>
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x1038"/><product id="0x1290"/></source>  <!-- SteelSeries Arctis Pro Wireless (1) -->
</hostdev>
<hostdev mode="subsystem" type="usb" managed="yes">
  <source><vendor id="0x1038"/><product id="0x1294"/></source>  <!-- SteelSeries Arctis Pro Wireless (2) -->
</hostdev>
```

---

### Phase 8: Install Windows 11 + Overwatch

1. Download the [virtio-win ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) to `/home/myuser/Downloads/virtio-win.iso` (referenced by VM XML)
2. Attach a Windows 11 ISO to the VM
3. Install Windows with UEFI + TPM 2.0
4. Install AMD GPU drivers (Adrenalin) inside Windows
5. Install VirtIO drivers (attach virtio-win.iso, install via Device Manager)
6. Install QEMU Guest Agent (`qemu-ga-x86_64.msi` from virtio-win ISO)
7. Install Battle.net (~738 MB) and Overwatch (~66 GB)
8. Set Overwatch aspect ratio to **21:9** in game settings (for 3440x1440)
9. Apply Windows VM power settings (see section below)
10. Disable GPU HDA audio device (see "Disable GPU HDA Audio Device" section below)

---

### Phase 9: Desktop Shortcut

Create `~/Desktop/start-vm.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=Overwatch
Comment=Start the Overwatch Windows VM with GPU passthrough
Exec=bash -c "sudo systemctl stop vm-overwatch 2>/dev/null; sudo systemd-run --unit=vm-overwatch --collect --description='Overwatch VM lifecycle' /usr/local/bin/vm-overwatch start"
Icon=computer
Terminal=false
Categories=System;
```

The shortcut stops any stale vm-overwatch unit, then starts a fresh one via `systemd-run`. The transient service survives GDM stop/restart (no terminal dependency). Uses `sudo` for root operations (see Phase 6.7 for sudoers config).

#### 9.2 Windows shutdown signal (scheduled task)

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

---

## Daily Usage

**Start gaming**: Click the "Overwatch" desktop shortcut. vm-overwatch stops services (ollama, openrgb, GDM), switches the GPU to vfio-pci, starts the VM, blanks the iGPU (monitor auto-switches to DP), and tunes CPU performance. Takes ~15s from click to Windows desktop.

**Stop gaming**: Shut down Windows from the Start menu. The `NotifyHostShutdown` scheduled task automatically sends a UDP timing signal to vm-overwatch on shutdown. vm-overwatch detects the shutdown, restores the GPU to amdgpu, unblanks the iGPU (monitor switches back to HDMI), and restarts all services.

**Monitor**: `journalctl -u vm-overwatch -f` for live logs. `vm-overwatch status` for a snapshot of GPU driver, VM state, iGPU, services, and CPU governor.

---

## VM XML Reference

Full XML from `virsh dumpxml overwatch`:

```xml
<domain type='kvm'>
  <name>overwatch</name>
  <uuid>ee9489dc-57fe-4405-ace6-73dcf9074201</uuid>
  <memory unit='KiB'>16777216</memory>
  <currentMemory unit='KiB'>16777216</currentMemory>
  <vcpu placement='static'>7</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='1'/>
    <vcpupin vcpu='1' cpuset='2'/>
    <vcpupin vcpu='2' cpuset='3'/>
    <vcpupin vcpu='3' cpuset='4'/>
    <vcpupin vcpu='4' cpuset='5'/>
    <vcpupin vcpu='5' cpuset='6'/>
    <vcpupin vcpu='6' cpuset='7'/>
  </cputune>
  <resource>
    <partition>/machine</partition>
  </resource>
  <os firmware='efi'>
    <type arch='x86_64' machine='pc-q35-noble'>hvm</type>
    <firmware>
      <feature enabled='yes' name='enrolled-keys'/>
      <feature enabled='yes' name='secure-boot'/>
    </firmware>
    <loader readonly='yes' secure='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.ms.fd</loader>
    <nvram template='/usr/share/OVMF/OVMF_VARS_4M.ms.fd'>/var/lib/libvirt/qemu/nvram/overwatch_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vendor_id state='on' value='AuthenticAMD'/>
    </hyperv>
    <kvm>
      <hidden state='on'/>
    </kvm>
    <vmport state='off'/>
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='off'>
    <topology sockets='1' dies='1' cores='7' threads='1'/>
    <cache mode='passthrough'/>
  </cpu>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='/var/lib/libvirt/images/overwatch.qcow2'/>
      <backingStore/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='/home/myuser/Downloads/virtio-win.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
    <controller type='usb' index='0' model='qemu-xhci' ports='15'>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
    </controller>
    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='pci' index='1' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='1' port='0x8'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x0' multifunction='on'/>
    </controller>
    <controller type='pci' index='2' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='2' port='0x9'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x1'/>
    </controller>
    <controller type='pci' index='3' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='3' port='0xa'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x2'/>
    </controller>
    <controller type='pci' index='4' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='4' port='0xb'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x3'/>
    </controller>
    <controller type='pci' index='5' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='5' port='0xc'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x4'/>
    </controller>
    <controller type='pci' index='6' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='6' port='0xd'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x5'/>
    </controller>
    <controller type='pci' index='7' model='pcie-to-pci-bridge'>
      <model name='pcie-pci-bridge'/>
      <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
    </controller>
    <controller type='pci' index='8' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='8' port='0xe'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x6'/>
    </controller>
    <controller type='sata' index='0'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
    </controller>
    <controller type='virtio-serial' index='0'>
      <address type='pci' domain='0x0000' bus='0x08' slot='0x00' function='0x0'/>
    </controller>
    <interface type='network'>
      <mac address='52:54:00:67:c7:3e'/>
      <source network='bridged'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>
    <input type='tablet' bus='usb'>
      <address type='usb' bus='0' port='1'/>
    </input>
    <input type='keyboard' bus='usb'>
      <address type='usb' bus='0' port='2'/>
    </input>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
    <audio id='1' type='none'/>
    <hostdev mode='subsystem' type='pci' managed='no'>
      <driver name='vfio'/>
      <source>
        <address domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
      </source>
      <rom bar='off' file='/usr/share/qemu/gpu-rom.bin'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </hostdev>
    <hostdev mode='subsystem' type='pci' managed='no'>
      <driver name='vfio'/>
      <source>
        <address domain='0x0000' bus='0x03' slot='0x00' function='0x1'/>
      </source>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </hostdev>
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x29ea'/>
        <product id='0x0102'/>
      </source>
      <address type='usb' bus='0' port='3'/>
    </hostdev>
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x1532'/>
        <product id='0x00a7'/>
      </source>
      <address type='usb' bus='0' port='4'/>
    </hostdev>
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x1532'/>
        <product id='0x022b'/>
      </source>
      <address type='usb' bus='0' port='5'/>
    </hostdev>
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x1532'/>
        <product id='0x0c05'/>
      </source>
      <address type='usb' bus='0' port='6'/>
    </hostdev>
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x1038'/>
        <product id='0x1290'/>
      </source>
      <address type='usb' bus='0' port='7'/>
    </hostdev>
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x1038'/>
        <product id='0x1294'/>
      </source>
      <address type='usb' bus='0' port='8'/>
    </hostdev>
    <watchdog model='itco' action='reset'/>
    <memballoon model='none'/>
  </devices>
  <seclabel type='dynamic' model='apparmor' relabel='yes'/>
  <seclabel type='dynamic' model='dac' relabel='yes'/>
</domain>
```

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

### GPU HDA Audio: AtiHDAudioService Removed

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

### TDR Timeout for GPU Passthrough

The AMD display driver takes longer to initialize after VFIO handoff than a cold
boot (~5s for DWM first frame composition). The default `TdrDelay` of 2s causes
`VIDEO_TDR_TIMEOUT_DETECTED` (0x141) live kernel dumps on every boot. Fix:
increase TDR timeouts in the registry.

```powershell
$path = "HKLM:\System\CurrentControlSet\Control\GraphicsDrivers"
Set-ItemProperty -Path $path -Name TdrDelay -Value 8 -Type DWord
Set-ItemProperty -Path $path -Name TdrDdiDelay -Value 20 -Type DWord
```

| Key | Value | Default | Why |
|-----|-------|---------|-----|
| `TdrDelay` | 8 | 2 | GPU scheduler wait before declaring TDR |
| `TdrDdiDelay` | 20 | 5 | OS wait for threads inside display driver |

No impact on boot speed (timeouts, not delays). A real GPU hang takes 8s instead
of 2s before Windows reacts — negligible in practice.

---

## Troubleshooting Reference

| Problem | Cause | Solution |
|---|---|---|
| "Failed to set group container: Invalid argument" | IVRS ACPI table exclusion ranges | IVRS table override (zeroed flags, OEM rev bump) — see Phase 3 |
| "kernel is locked down, ignoring table override" | Secure Boot enabled | Disable Secure Boot in BIOS |
| IVRS override not applied | OEM revision same as original | Bump OEM revision to 2 |
| White screen on iGPU | `amd_iommu=force_isolation` breaks iGPU DMA | Remove `force_isolation`, use patched IVRS alone |
| GPU not visible in Windows | GPU never initialized, QEMU can't read ROM | Download VBIOS from TechPowerUp, add as ROM file |
| "failed to find romfile" | QEMU sandbox restricts file access | Place ROM in `/usr/share/qemu/` |
| YouTube won't load in VM | NAT/QUIC issues | Switch to bridged networking |
| Tartarus not detected in VM | USB re-enumeration, stale addresses | Remove hardcoded `<address bus=... device=...>` from USB source entries in VM XML |
| amdgpu unbind hangs (D state, i2c_del_adapter) | OpenRGB holding `/dev/i2c-*` FDs via DP AUX I2C adapters | `systemctl stop openrgb` before unbinding (vm-overwatch does this) |
| amdgpu unbind hangs (D state, drm_dev_unplug) | GDM/GNOME Shell has DRM card FDs open (multi-GPU) | `systemctl stop gdm` before unbinding (vm-overwatch does this) |
| libvirt hooks deadlock | Hooks call systemctl/virsh synchronously | Use vm-overwatch wrapper instead of hooks; hook file is no-op `exit 0` |
| No display after VM shutdown | iGPU display in DPMS off state | vm-overwatch unblanks iGPU and restarts GDM |
| GDM wrong aspect ratio (single GPU) | monitors.xml connector mismatch | Update connector name (e.g. `HDMI-1` -> `HDMI-3` when dGPU on amdgpu shifts numbering) |
| GDM wrong aspect ratio (dual GPU) | Both dGPU DP-1 and iGPU HDMI-3 connected to same monitor; monitors.xml lists only one output so GDM falls back to auto (3840x2160) | Add `<disabled>` section for DP-1 in monitors.xml |
| GNOME Shell crashes when GPU unbinds | dGPU used for GPU-accelerated rendering | Stop GDM before unbinding amdgpu; run wrapper via `systemd-run` |
| vm-overwatch dies when GDM stops | Script runs in GNOME terminal session | Runs as systemd service (`systemctl start vm-overwatch`); SIGTERM handler runs full host restore on stop |
| Audio volume much lower in VM | Windows volume state desyncs after USB passthrough | Move volume slider to 0% then back to 100%. Check SteelSeries GG EQ, Volume Mixer per-app levels. Use Settings -> System -> Sound (not `mmsys.cpl` which may freeze the VM) |
| GPU crashes during desktop use | amdgpu runtime PM puts GPU into D3; resume finds device unresponsive (`0xffffffff` registers), `device lost from bus`, soft lockup | `/etc/modprobe.d/amdgpu.conf` with `options amdgpu runpm=0`. vm-overwatch also writes `power/control=on` after amdgpu bind on restore |
| GPU audio D3cold after VM passthrough | Audio function stuck in D3cold after VFIO; binding snd_hda_intel triggers failed power transition that crashes the entire GPU | PCIe bus reset (SBR) resets both GPU and audio function; vm-overwatch binds snd_hda_intel directly without PCI remove/rescan |
| Concurrent vm-overwatch instances cause dirty state | Second instance finds GPU in unexpected driver state | Lock file via `flock /run/vm-overwatch.lock` prevents concurrent instances |
| Windows BSOD 0x9F DRIVER_POWER_STATE_FAILURE | Windows "Balanced" power plan sends power IRPs to passthrough GPU/USB devices; vfio-pci owns the hardware so guest driver can't complete power transitions | Switch to **High Performance** power plan; disable PCI Express ASPM, USB selective suspend, display timeout, sleep, hybrid sleep (see Windows VM Power Settings section) |
| Frequent 0x9F BSODs after Windows Update | Windows Update pushed AMD driver 31.0.14000.58004 (Feb 2026) which corrupts GPU state every 2-5 min during gameplay | Roll back via Device Manager -> Display adapters -> Roll Back Driver. Block reinstall: Settings -> Windows Update -> Pause updates, or `wushowhide.diagcab` to hide the driver update. Known-good driver: Radeon Software 32.0.23017.1001 (2026-01-08) |
| Windows BSOD 0x9F during shutdown specifically | `HDAudBus!HdaController::TransferCodecVerbs` blocks waiting for GPU HDA audio codec to respond during power-down (`IRP_MN_SET_POWER` to D1); codec never responds because it's behind vfio-pci | Uninstall AtiHDAudioService driver (`pnputil /delete-driver oem39.inf /force`); Windows generic HD Audio driver handles the device without triggering the issue. GPU audio PCI function (`03:00.1`) must still be passed through (AMD driver Code 43 without it). Also disable AMD driver power features via registry (see Power Settings section) |
| WATCHDOG/AMD_WATCHDOG live kernel dumps on every VM boot | AMD display driver init after VFIO handoff takes >2s (default TdrDelay); DWM first frame composition triggers `VIDEO_TDR_TIMEOUT_DETECTED` (0x141) | Set `TdrDelay=8` and `TdrDdiDelay=20` in `HKLM\System\CurrentControlSet\Control\GraphicsDrivers`. Timeouts not delays — no boot speed impact |
| amdgpu bind hangs after VM passthrough (`trn=2 ACK should not assert`) | GPU SMU mailbox stuck after heavy GPU usage in VM (e.g. gaming); VFIO release doesn't fully reset the GPU, amdgpu probe loops forever on SMU communication | Reboot required. This is a hardware-level issue — the GPU needs a full PCI bus reset that only a machine reboot provides. Lightweight test cycles may restore fine but extended gaming sessions can leave the GPU in an unrecoverable state |
| Monitor doesn't auto-switch to DP when VM starts | iGPU HDMI stays active, monitor doesn't detect DP | Blank iGPU framebuffer (`echo 4 > /sys/class/graphics/fbN/blank`) when VM starts; monitor auto-detects to DP. fb matched by PCI device path, not hardcoded number. vm-overwatch handles this |

---

## Action Items

### 1. Add PCIe bus reset before amdgpu rebind

**Status:** Implemented (vm-overwatch.sh lines 519-530)

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
to a clean power state. This may make the existing PCI remove/rescan of
`03:00.1` unnecessary — test after implementing the bus reset.

### 2. Test removing PCI remove/rescan for GPU audio after bus reset

**Status:** Done — direct bind works, remove/rescan deleted

**Problem:** `ensure_gpu_on_host()` does a PCI remove + full bus rescan on
`03:00.1` (lines 502-520) to work around the audio function being stuck in
D3cold after VFIO passthrough. This is the riskiest operation in the rebind
— `echo 1 > /sys/bus/pci/rescan` re-enumerates the entire PCI bus, which can
cause side effects when amdgpu is loaded.

**Rationale:** The bus reset from Action Item 1 resets both `03:00.0` and
`03:00.1` via the PCIe link (SBR hits all functions behind the bridge). If the
audio device comes back in a clean power state after the bus reset, the PCI
remove/rescan is unnecessary.

**Next steps:**
- Implement Action Item 1 first
- Test a VM cycle with the bus reset but without the PCI remove/rescan
- If `snd_hda_intel` binds cleanly to `03:00.1` after a direct bind (no
  remove/rescan), remove the remove/rescan block
- If it still fails (D3cold, failed power transition), keep the remove/rescan

### 3. Test: disable Auto HDR to isolate hiccup root cause

**Status:** Pending

**Problem:** Overwatch gameplay hiccups (brief screen freezes) occur most reliably
at match→menu transitions. Display event instrumentation shows Windows Auto HDR
(Event ID 4125) activating every session. Each HDR mode switch reconfigures the
display pipeline, which in exclusive fullscreen can cause a visible stall. Alt+tab
instantly fixes the hiccup (forces a clean fullscreen exit/re-entry).

**Goal:** Determine whether Auto HDR mode switching is the root cause. This is a
diagnostic test only — HDR should remain enabled in the final configuration.

**Test:** Windows Settings → System → Display → HDR → turn off Auto HDR. Play
several matches and observe whether match→menu hiccups still occur. Re-enable
Auto HDR after testing.

### 4. Test: force HDR always-on to prevent mode switching

**Status:** Pending — test after Action Item 3 confirms HDR is the cause

**Problem:** If Action Item 3 confirms HDR mode switching causes the hiccups, the
fix is to keep HDR always-on rather than letting Windows toggle it per-app. This
avoids the display pipeline reconfiguration while preserving HDR output.

**Test:** Windows Settings → System → Display → HDR → keep HDR enabled, disable
Auto HDR. Ensure Overwatch uses HDR natively (Video settings → HDR Display). Play
several matches and observe whether match→menu hiccups still occur with HDR
permanently active.

---

## Things That May Change After Reinstall

| Item | Why it might change | How to fix |
|---|---|---|
| PCI bus addresses (`03:00.0`) | Different kernel/BIOS enumeration | Check `lspci -nn`, update VM XML and vm-overwatch script |
| i2c device numbers (`/dev/i2c-4` through `/dev/i2c-10`) | Different driver probe order | Check `ls /sys/bus/i2c/devices/`, update vm-overwatch `fuser` lines |
| DRM card numbers (`/dev/dri/card0`, `card1`) | Different GPU probe order | Check `ls -la /dev/dri/by-path/` |
| Monitor connector names (`HDMI-3`, `DP-1`) | Different GPU/output enumeration | Check `xrandr --listmonitors`, update monitors.xml |
| virtio-win.iso path | VM XML references `/home/myuser/Downloads/virtio-win.iso` | Re-download ISO to same path, or update VM XML |
| Netplan config filename | Ubuntu installer may use different naming | Adjust bridge config to match |
