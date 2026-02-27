# Setup — Phases 1-8: Host Infrastructure

## Phase 1: BIOS Settings

These must be set before the OS install (or at least before Phase 2).

| Setting | Value | Location (MSI MPG X870E CARBON WIFI) |
|---|---|---|
| IOMMU | Enabled | AMD CBS or Advanced |
| Initiate Graphic Adapter | **IGD** (iGPU primary) | Advanced > Integrated Graphics Configuration |
| Integrated Graphics | **Force** | Same section |
| HybridGraphics | **Disabled** | Same section |
| Secure Boot | **Disabled** | Security > Secure Boot |

**Note:** "Kernel DMA Protection" is **not exposed** in BIOS 1.A80 on this board. The IVRS ACPI table override (Phase 3) works around this.


## Phase 2: Install Virtualization Stack

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


## Phase 3: IVRS ACPI Table Override

**Why:** The motherboard's IVRS table declares exclusion ranges that block VFIO container setup ("Failed to set group container: Invalid argument"). We patch the table to zero these flags.

### 3.1 Extract and patch the IVRS table

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

### 3.2 Create CPIO initrd image

```bash
mkdir -p /tmp/ivrs-img/kernel/firmware/acpi
cp /tmp/ivrs-patched.dat /tmp/ivrs-img/kernel/firmware/acpi/ivrs.dat
cd /tmp/ivrs-img
find . -print0 | cpio --null --create --format=newc > /boot/acpi-ivrs-override.img
```

### 3.3 Configure GRUB

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

### 3.4 Verify

```bash
dmesg | grep -i ivrs
# Should show the patched table being loaded
dmesg | grep -i iommu
# Should show IOMMU groups without errors
```


## Phase 4: Network Bridge Setup

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


## Phase 5: GPU ROM File

The discrete GPU boots on amdgpu, so its VBIOS ROM BAR may not be readable when QEMU needs it. A standalone ROM file is required.

1. Download the VBIOS from [TechPowerUp VGA BIOS Collection](https://www.techpowerup.com/vgabios/) — search for **Sapphire NITRO+ RX 7900 XTX Vapor-X** (subsystem ID `1DA2:E471`, ~2MB file)
2. Place it where QEMU's sandbox allows access:

```bash
sudo cp 272613.rom /usr/share/qemu/gpu-rom.bin
```


## Phase 6: Install Support Files

### 6.1 overwatch lifecycle script

```bash
sudo cp scripts/overwatch.sh /usr/local/bin/overwatch
sudo chmod +x /usr/local/bin/overwatch
```

Source is in this repo at `scripts/overwatch.sh`. The script manages the full GPU passthrough lifecycle:

1. **Pre-VM**: Stop services (ollama, openrgb, GDM) → release device FDs (`fuser -k` on DRM and i2c devices) → unbind VT consoles → unbind snd_hda_intel from GPU audio → unbind amdgpu → bind GPU + audio to vfio-pci
2. **VM running**: Start VM → re-attach USB devices (Kinesis, Tartarus detach/reattach to clear ghost entries) → blank iGPU → set CPU governor to `performance`, pin all IRQs to CPU 0, stop irqbalance, move RCU callbacks to CPU 0
3. **Post-VM**: Restore CPU governor to `powersave`, restart irqbalance → unbind vfio-pci → PCIe bus reset (SBR) → rebind VT consoles → bind amdgpu → direct bind snd_hda_intel (no PCI rescan) → disable runtime PM → unblank iGPU → restart services

### 6.2 overwatch systemd service

```bash
sudo cp scripts/overwatch.service /etc/systemd/system/overwatch.service
sudo systemctl daemon-reload
```

Source is in this repo at `scripts/overwatch.service`. The service wraps `overwatch start` with proper lifecycle management: `Type=simple` (long-running foreground process), `TimeoutStartSec=infinity` (VM sessions last hours), `TimeoutStopSec=120` (graceful shutdown + host restore). `systemctl stop` sends SIGTERM, which triggers the script's cleanup handler.

### 6.3 udev rules — seat prevention

Create `/etc/udev/rules.d/99-gpu-passthrough.rules`:
```
# Prevent the 7900 XTX from being assigned to any seat.
# This stops GDM from spawning a greeter on it.
# The render node remains available for compute (ollama).
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}=="pci-0000:03:00.0", ENV{ID_SEAT}=""
```

This clears the seat assignment on the dGPU's DRM device so logind doesn't assign it a seat. Without this, GDM would try to manage the dGPU output, interfering with GPU passthrough. The render node (`renderD128`) is unaffected and remains available for compute workloads (ollama).

**Note:** Runtime PM for the GPU is handled by `/etc/modprobe.d/amdgpu.conf` (`runpm=0`), not by udev rules.

### 6.4 amdgpu runtime PM fix

Create `/etc/modprobe.d/amdgpu.conf`:
```
options amdgpu runpm=0
```

This prevents amdgpu from enabling runtime PM at the driver level. Without this, the GPU enters D3 during idle and crashes on resume (`device lost from bus`, soft lockup). The default `runpm=-1` (auto) enables runtime PM on desktop GPUs.

### 6.5 Auto-load vfio-pci module

Create `/etc/modules-load.d/vfio-pci.conf`:
```
vfio-pci
```

### 6.6 GDM monitors.xml

Copy your monitors.xml (with iGPU HDMI as primary, dGPU DP disabled) to both locations:
```bash
cp ~/.config/monitors.xml /var/lib/gdm3/.config/monitors.xml
sudo chown gdm:gdm /var/lib/gdm3/.config/monitors.xml
```

The monitors.xml must list the iGPU output (e.g. `HDMI-3`) as the active monitor at 3440x1440@85Hz, and mark the dGPU output (e.g. `DP-1`) as `<disabled>`. The exact connector names may change after reinstall — check with `gnome-display-settings` or `xrandr`.

### 6.7 libvirt hooks (no-op)

Create `/etc/libvirt/hooks/qemu`:
```bash
#!/bin/bash
exit 0
```
```bash
sudo chmod +x /etc/libvirt/hooks/qemu
```

This prevents libvirt from running any hook logic (which causes deadlocks with systemctl/virsh). All lifecycle management is handled by the overwatch wrapper.

### 6.8 Passwordless sudo

The desktop shortcut (Phase 8) runs `sudo systemctl start overwatch` with `Terminal=false`, so there is no terminal to enter a password. The `myuser` user needs passwordless sudo for at least `systemctl`.

Create `/etc/sudoers.d/overwatch`:
```
myuser ALL=(ALL) NOPASSWD: /usr/bin/systemctl start overwatch, /usr/bin/systemctl stop overwatch
```

Or, if the user already has blanket NOPASSWD (`myuser ALL=(ALL) NOPASSWD: ALL`), no additional configuration is needed.


## Phase 7: Create the VM

### 7.1 Create the disk

```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/overwatch.qcow2 200G
```

On the reinstalled system, this will be on the Samsung 990 PRO `@vms` subvolume (mounted at `/var/lib/libvirt/images`, with `nodatacow`).

### 7.2 Define the VM

Use `virt-install` or import the XML from the [VM XML Reference](vm-xml-reference.md). Key configuration:

| Setting | Value |
|---|---|
| **Name** | `overwatch` |
| **vCPUs** | 7, pinned to cores 1-7 (core 0 reserved for host + emulator + IO) |
| **Topology** | 1 socket, 7 cores, 1 thread |
| **IO threads** | 1 dedicated IO thread, pinned to core 0 |
| **Emulator** | Pinned to core 0 (prevents VFIO interrupt injection contention on vCPU cores) |
| **RAM** | 16 GB |
| **CPU** | host-passthrough, cache passthrough |
| **Firmware** | OVMF (UEFI) with TPM 2.0 (tpm-crb, emulator backend) |
| **Disk** | VirtIO, `/var/lib/libvirt/images/overwatch.qcow2` |
| **Network** | VirtIO NIC on `bridged` network (br0) |
| **Display** | None (remove Spice/QXL — native GPU output only) |

### 7.3 GPU passthrough devices

```xml
<!-- GPU: managed=no (overwatch handles driver binding) -->
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

### 7.4 Anti-cheat features

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

### 7.5 USB passthrough

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


## Phase 8: Desktop Shortcut

Create `~/Desktop/overwatch.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=Overwatch
Comment=Start the Overwatch Windows VM with GPU passthrough
Exec=bash -c "sudo systemctl start overwatch"
Icon=computer
Terminal=false
Categories=System;
```

The shortcut starts the overwatch systemd service. If the service is already running, `systemctl start` is a no-op. The service survives GDM stop/restart (no terminal dependency). Uses `sudo` for root operations (see Phase 6.8 for sudoers config).


## CPU Isolation Architecture

This is not a numbered phase — CPU isolation is built into overwatch and the
libvirt XML (Phase 7), not a manual step. Understanding the architecture helps
with troubleshooting.

overwatch confines all host processes to core 0 during VM runtime, giving
vCPU cores (1-7) zero host interference. This improves VFIO interrupt delivery
latency, reduces boot-time TDR frequency, and provides better gaming frame
consistency.

### Libvirt XML (`cputune`)

```xml
<iothreads>1</iothreads>
<cputune>
  <vcpupin vcpu='0' cpuset='1'/>
  <!-- ... vcpupin 1-6 on cpuset 2-7 ... -->
  <emulatorpin cpuset='0'/>
  <iothreadpin iothread='1' cpuset='0'/>
</cputune>
```

- **emulatorpin**: Confines QEMU emulator thread to core 0. This thread handles
  VFIO interrupt injection — pinning it prevents contention on vCPU cores.
- **iothreadpin**: Confines the IO thread (disk, network) to core 0.

### overwatch: dynamic AllowedCPUs

During VM runtime, `ensure_performance_tuning()` confines all host processes:

```bash
systemctl set-property --runtime -- system.slice AllowedCPUs=0
systemctl set-property --runtime -- user.slice AllowedCPUs=0
systemctl set-property --runtime -- init.scope AllowedCPUs=0
```

On restore, `ensure_cpu_defaults()` lifts the restriction:

```bash
systemctl set-property --runtime -- system.slice AllowedCPUs=0-7
systemctl set-property --runtime -- user.slice AllowedCPUs=0-7
systemctl set-property --runtime -- init.scope AllowedCPUs=0-7
```

Combined with IRQ pinning (all IRQs → core 0) and writeback migration, this
ensures cores 1-7 run only VM vCPU threads during gameplay.
