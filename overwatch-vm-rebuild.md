# Overwatch VM Rebuild Guide (Post Ubuntu Reinstall on Myhost)

This is a step-by-step implementation plan for recreating the Overwatch GPU passthrough VM after a fresh Ubuntu install on myhost. Everything here is derived from [gpu-passthrough-plan.md](gpu-passthrough-plan.md) and [vbios-reverse-engineering-plan.md](vbios-reverse-engineering-plan.md).

**Prerequisites:** Fresh Ubuntu 24.04 install on myhost T705 (btrfs, as described in [backup-strategy.md](backup-strategy.md)), kernel 6.17+ (HWE), Secure Boot **disabled**.

---

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

---

## Phase 2: Install Virtualization Stack

```bash
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst virt-manager ovmf swtpm swtpm-tools bridge-utils
sudo usermod -aG libvirt,kvm myuser
```

Verify:
```bash
virt-host-validate
# Should show all PASS for QEMU/KVM
```

---

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

**Do NOT use** `iommu=pt` or `amd_iommu=force_isolation` — the former is unnecessary, the latter breaks iGPU display (white screen).

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

---

## Phase 4: Network — Bridge Setup

The VM uses bridged networking (gets its own LAN IP via DHCP). Create a bridge over the internet-facing NIC.

In `/etc/netplan/50-cloud-init.yaml` (or equivalent):
```yaml
network:
  version: 2
  ethernets:
    enp8s0:
      dhcp4: true    # Router connection (2.5G NIC)
    enp9s0:
      dhcp4: false   # Direct link to devbox / bridge member
  bridges:
    br0:
      interfaces: [enp9s0]
      dhcp4: true
      parameters:
        stp: false
```

**Note:** Which NIC goes in the bridge depends on the final network topology. If the direct devbox link uses enp9s0, the bridge may need to be on enp8s0 instead (the router-facing NIC). Verify before applying.

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

## Phase 5: GPU ROM File

The discrete GPU boots on amdgpu, so its VBIOS ROM BAR may not be readable when QEMU needs it. A standalone ROM file is required.

1. Download the VBIOS from [TechPowerUp VGA BIOS Collection](https://www.techpowerup.com/vgabios/) — search for **Sapphire NITRO+ RX 7900 XTX Vapor-X** (subsystem ID `1DA2:E471`, ~2MB file)
2. Place it where QEMU's sandbox allows access:

```bash
sudo cp 272613.rom /usr/share/qemu/gpu-rom.bin
```

---

## Phase 6: Build navi31_reset Kernel Module

The custom kernel module performs MODE1 reset of the GPU in ~509ms. Source is in this repo at `navi31-reset/`.

```bash
cd /home/myuser/navi31-reset   # or wherever you clone the kb repo
make
# Produces navi31_reset.ko
```

Test:
```bash
sudo insmod navi31_reset.ko
cat /dev/navi31-reset
# Should show SOL and bootloader status
sudo rmmod navi31_reset
```

**DKMS (optional, recommended):** Set up DKMS so the module rebuilds automatically on kernel updates. Without DKMS, you must `make` again after every kernel upgrade.

---

## Phase 7: Install Support Files

### 7.1 vm-overwatch lifecycle script

```bash
sudo cp navi31-reset/vm-overwatch /usr/local/bin/vm-overwatch
sudo chmod +x /usr/local/bin/vm-overwatch
```

### 7.2 Launcher (for desktop shortcut)

Create `/usr/local/bin/vm-overwatch-launch`:
```bash
#!/bin/bash
exec systemd-run --unit=vm-overwatch /usr/local/bin/vm-overwatch
```
```bash
sudo chmod +x /usr/local/bin/vm-overwatch-launch
```

### 7.3 udev rule — prevent dGPU from getting a logind seat

Create `/etc/udev/rules.d/99-gpu-passthrough.rules`:
```
# Prevent discrete GPU from being assigned a seat by logind
# (avoids GDM trying to use it for display)
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x744c", TAG-="seat"
```

### 7.4 Auto-load vfio-pci module

Create `/etc/modules-load.d/vfio-pci.conf`:
```
vfio-pci
```

### 7.5 GDM monitors.xml

Copy your monitors.xml (with iGPU HDMI as primary, dGPU DP disabled) to both locations:
```bash
cp ~/.config/monitors.xml /var/lib/gdm3/.config/monitors.xml
sudo chown gdm:gdm /var/lib/gdm3/.config/monitors.xml
```

The monitors.xml must list the iGPU output (e.g. `HDMI-3`) as the active monitor at 3440x1440@85Hz, and mark the dGPU output (e.g. `DP-1`) as `<disabled>`. The exact connector names may change after reinstall — check with `xrandr` or `gnome-display-settings`.

### 7.6 libvirt hooks (no-op)

Create `/etc/libvirt/hooks/qemu`:
```bash
#!/bin/bash
exit 0
```
```bash
sudo chmod +x /etc/libvirt/hooks/qemu
```

This prevents libvirt from running any hook logic (which causes deadlocks with systemctl/virsh). All lifecycle management is handled by the vm-overwatch wrapper.

---

## Phase 8: Create the VM

### 8.1 Create the disk

```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/overwatch.qcow2 200G
```

On the reinstalled system, this will be on the Samsung 990 PRO `@vms` subvolume (mounted at `/var/lib/libvirt/images`, with `nodatacow`).

### 8.2 Define the VM

Use `virt-install` or import the XML directly. Key configuration:

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

### 8.3 GPU passthrough devices

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

### 8.4 Anti-cheat features

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

### 8.5 USB passthrough

All matched by vendor/product ID only — **no hardcoded bus/device addresses**:

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

## Phase 9: Install Windows 11 + Overwatch

1. Attach a Windows 11 ISO to the VM (or create USB via `scripts/create_win11_usb.sh`)
2. Install Windows with UEFI + TPM 2.0
3. Install AMD GPU drivers (Adrenalin) inside Windows
4. Install Battle.net (~738 MB) and Overwatch (~66 GB)
5. Set Overwatch aspect ratio to **21:9** in game settings (for 3440x1440)

---

## Phase 10: Desktop Shortcut

Create `~/.local/share/applications/overwatch.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=Overwatch
Exec=pkexec /usr/local/bin/vm-overwatch-launch
Icon=applications-games
Terminal=false
Categories=Game;
```

The script needs root (it stops/starts system services, binds/unbinds PCI drivers). `pkexec` provides a graphical authentication prompt.

---

## Post-Rebuild Verification Checklist

- [ ] `dmesg | grep -i ivrs` shows patched table loaded
- [ ] IOMMU groups correct: GPU in group 15, iGPU in group 30
- [ ] `cat /dev/navi31-reset` shows GPU health info
- [ ] `virsh start overwatch` works (via vm-overwatch wrapper)
- [ ] Windows visible on DisplayPort output
- [ ] All USB devices work in VM (especially Tartarus after 30s cycle)
- [ ] VM has internet (bridged networking, DHCP)
- [ ] Overwatch launches and plays without anti-cheat issues
- [ ] After VM shutdown: GDM returns, iGPU display at 3440x1440@85Hz
- [ ] Second VM cycle works (MODE1 reset successful)
- [ ] ollama and openrgb services restart after VM shutdown

---

## Things That May Change After Reinstall

| Item | Why it might change | How to fix |
|---|---|---|
| PCI bus addresses (`03:00.0`) | Different kernel/BIOS enumeration | Check `lspci -nn`, update VM XML and vm-overwatch script |
| i2c device numbers (`/dev/i2c-4` through `/dev/i2c-10`) | Different driver probe order | Check `ls /sys/bus/i2c/devices/`, update vm-overwatch `fuser` lines |
| DRM card numbers (`/dev/dri/card0`, `card1`) | Different GPU probe order | Check `ls -la /dev/dri/by-path/` |
| Monitor connector names (`HDMI-3`, `DP-1`) | Different GPU/output enumeration | Check `xrandr --listmonitors`, update monitors.xml |
| Netplan config filename | Ubuntu installer may use different naming | Adjust bridge config to match |
| Kernel version | HWE kernel updates | Rebuild navi31_reset module (or set up DKMS) |

---

## Artifacts to NOT Carry Over (Cleanup List)

These files exist on the current myhost install but are **no longer needed**:

| File | What it was | Why it's unnecessary |
|---|---|---|
| `vm-overwatch.bak` (location TBD on myhost) | Old suspend/resume VM lifecycle script | Replaced entirely by MODE1 reset. The current `vm-overwatch` is the only version needed. |
| `/usr/share/X11/xorg.conf.d/20-igpu.conf` | X11 config forcing iGPU BusID | Only needed for X11 fallback. Myhost runs Wayland — this file is dead weight. If X11 is ever needed again, recreate it (BusID may change anyway). |
| `/etc/libvirt/hooks/qemu` (no-op, `exit 0`) | Placeholder to prevent default hook behavior | Harmless but confusing. On a fresh install there are no hooks by default, which is the correct state. Only recreate if libvirt adds default hooks that interfere. |
| Old NTFS partitions on Samsung 990 PRO | Windows dual-boot remnants | Already repartitioned as single 3.6T ext4. Gone on current system, won't exist after reinstall. |
| `/mnt/ntfs/` | Mount point for old NTFS partition | Already cleaned up on current system. |

**Still needed (carry over):**

| File | Why |
|---|---|
| `/boot/acpi-ivrs-override.img` | Must be regenerated (Phase 3) — the patched IVRS table |
| `/usr/share/qemu/gpu-rom.bin` | VBIOS ROM for GPU passthrough — redownload from TechPowerUp |
| `/usr/local/bin/vm-overwatch` | VM lifecycle script — copy from this repo (`navi31-reset/vm-overwatch`) |
| `/usr/local/bin/vm-overwatch-launch` | Launcher — recreate (Phase 7.2) |
| `/etc/udev/rules.d/99-gpu-passthrough.rules` | Prevents dGPU seat assignment — recreate (Phase 7.3) |
| `/etc/modules-load.d/vfio-pci.conf` | Auto-loads vfio-pci at boot — recreate (Phase 7.4) |
| `/var/lib/gdm3/.config/monitors.xml` | GDM display config — copy from `~/.config/monitors.xml` after setting up displays |
| `navi31_reset.ko` | Kernel module — rebuild from source (Phase 6) |
| VM XML definition (`virsh dumpxml overwatch`) | Libvirt VM config — recreate or import saved XML (Phase 8) |
| `overwatch.qcow2` | Windows VM disk image — **back this up before reinstall** or reinstall Windows |
