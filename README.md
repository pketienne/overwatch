# Overwatch

GPU-passthrough Windows 11 gaming VM. AMD RX 7900 XTX passed through
to a Windows guest for Overwatch 2 with Ricochet anti-cheat.

This repo is a [Cinc](https://cinc.sh) (open-source Chef) cookbook that
configures the host (GRUB, VFIO, network bridge, libvirt VM definition,
lifecycle tooling) and deploys guest setup scripts for manual execution
after Windows installation.

## Install Cinc

```bash
curl -L https://omnitruck.cinc.sh/install.sh | sudo bash
```

Verify:

```bash
cinc-client --version
cinc-solo --version
```

## Run the cookbook

The cookbook depends on `symmetra_core` and `libvirt` cookbooks from the
symmetra repo. To converge:

```bash
# From the symmetra repo (has all dependency cookbooks)
cd ~/Projects/symmetra/master

# Run just the overwatch cookbook
sudo cinc-client -z -o 'recipe[overwatch::default]'
```

To uninstall:

```bash
sudo cinc-client -z -o 'recipe[overwatch::uninstall]'
```

## Required attributes

The cookbook ships with generic defaults. The following attributes must
be overridden in a policyfile or node JSON before converging:

```ruby
# Network
default['overwatch']['host_ip']             = '192.168.0.100' # host bridge IP
default['overwatch']['vm_ip']               = '192.168.0.101' # VM IP (static DHCP lease)
default['overwatch']['vm_mac']              = 'aa:bb:cc:dd:ee:ff'
default['overwatch']['physical_interface']  = 'enp8s0' # NIC for bridge

# Users
default['overwatch']['target_user']         = 'myuser' # Linux account
default['overwatch']['windows_user']        = 'myuser' # Windows guest account

# SMBIOS — must match real hardware for anti-cheat
default['overwatch']['smbios'] = {
  'bios_vendor'        => 'American Megatrends International, LLC.',
  'bios_version'       => '1.00',
  'bios_date'          => '01/01/2025',
  'sys_manufacturer'   => 'My Vendor',
  'sys_product'        => 'My Product',
  'sys_version'        => '1.0',
  'board_manufacturer' => 'My Vendor',
  'board_product'      => 'My Board',
  'board_version'      => '1.0',
  'board_serial'       => 'XXXXXXXXXX',    # your board serial
  'sys_serial'         => 'To be filled by O.E.M.',
}

# USB devices to pass through to the VM
default['overwatch']['usb_devices'] = [
  { 'vid' => '0x1234', 'pid' => '0x5678', 'name' => 'My Keyboard' },
]
```

Read your host's SMBIOS values with `sudo dmidecode -t bios -t system -t baseboard`.

These attributes have sensible defaults but may need adjustment per host:

| Attribute | Default | Notes |
|---|---|---|
| `gpu` | `0000:03:00.0` | dGPU PCI address (`lspci -D \| grep VGA`) |
| `gpu_audio` | `0000:03:00.1` | GPU HDMI/DP audio function |
| `igpu` | `0000:74:00.0` | iGPU PCI address (for display switching) |
| `host_cpus` | `0-1` | CPUs reserved for host (not pinned to VM) |
| `emulator_cpuset` | `0-1` | CPUs for QEMU emulator threads |
| `vcpu_pins` | cores 2-7 | vCPU-to-physical-core pinning map |
| `vm_ram_kib` | 50331648 (48G) | VM RAM in KiB |
| `vm_vcpus` | 6 | Number of vCPUs |
| `grub_cmdline_params` | IOMMU + hugepages + CPU isolation | Kernel parameters |
| `virtio_iso` | (empty) | Path to `virtio-win.iso` for driver install |

## Prerequisites

- `libvirt` cookbook (base packages, libvirtd service)
- GPU ROM (`/usr/share/qemu/gpu-rom.bin`) — download the VBIOS for your
  specific GPU from [TechPowerUp VGA BIOS Collection][vbios]. The
  cookbook logs a warning if the file is missing but does not fail.
- VirtIO ISO (`~/Downloads/virtio-win.iso`) — optional; mounted as a
  CDROM if present during VM definition for driver installation.

[vbios]: https://www.techpowerup.com/vgabios/

## What the cookbook does NOT do

- **Run guest configuration automatically.** The guest must be running
  with QEMU guest agent installed before `setup-guest.sh` can execute.
- **Install Windows.** This is manual; `autounattend.xml` is deployed
  to assist unattended installs.
- **Download the GPU ROM.** This is specific to the GPU model and must
  be placed manually.
- **Apply netplan.** The bridge config is written but `netplan apply`
  is not called — this is dangerous over SSH and could sever the
  connection. A warning is logged instead.

## Post-converge workflow

After the cookbook converges:

1. **Reboot** to pick up GRUB IOMMU and VFIO module changes.
2. **Apply netplan** (if first run): `sudo netplan apply`
3. **Install Windows** into the VM:
   - Attach a Windows ISO to the VM definition.
   - `virsh start overwatch` and connect via VNC/Spice for initial setup.
   - Install VirtIO drivers from the mounted ISO.
   - Install QEMU guest agent.
4. **Run guest setup**: `sudo /usr/local/share/overwatch/setup-guest.sh all`
   from the host. This configures power settings, removes HDA audio,
   disables Defender telemetry, sets up the shutdown signal listener,
   and tunes display/performance settings inside the guest.

## VM lifecycle

**Always use systemd:**

```bash
sudo systemctl start overwatch
sudo systemctl stop overwatch
```

**Never use these directly:**

- `virsh destroy` — yanks GPU mid-operation, corrupts GPU state
- `virsh reboot` — causes grey screen / TDR with GPU passthrough
- `virsh shutdown` — bypasses cleanup sequence
- `sudo overwatch start` — must go through systemd
- `virsh undefine --nvram` — destroys UEFI NVRAM. To update XML, use `virsh define <file>`.

**Before modifying VM XML or NVRAM:**

```bash
sudo cp /var/lib/libvirt/qemu/nvram/overwatch_VARS.fd{,.bak}
```

**Before risky guest operations** (no qcow2 snapshots exist by default):

```bash
sudo virsh snapshot-create-as overwatch --name <label> --disk-only
```

Host and guest configs must stay in sync. A change that prevents the VM
from booting risks a host kernel panic — a failed boot leaves the GPU
held via vfio with no guest to release it.

## Frozen guest recovery

1. Wait 30-60s — AMD GPU driver init can take this long. It often recovers.
2. Check guest agent: `sudo virsh qemu-agent-command overwatch '{"execute":"guest-ping"}'`
3. If the agent responds, Windows is running — wait longer for the display.
4. Only if unrecoverable: `sudo systemctl stop overwatch`
5. Host reboot only needed on kernel panic (green screen).
6. After forced stop, check `sudo dmesg | grep -i amdgpu` before restarting.

## Guest agent

The agent runs as SYSTEM. Commands via `guest-exec` run in the SYSTEM
session, not the interactive user session:

- GUI apps are invisible to the logged-in user
- `HKCU:` maps to SYSTEM's hive, not the user's
- Use `HKU\<SID>` for per-user registry access

Windows Defender and Tamper Protection must always remain on.

## Template strategy

The lifecycle script is split into two files: `overwatch.sh.erb` (~920
lines) for core logic and `overwatch-monitors.sh.erb` (~465 lines) for
background monitors and deferred boot tasks (sourced at runtime). The
guest setup script is `setup-guest.sh.erb` (~1075 lines). All three
template only a small block of machine-specific constants in the header;
the rest is verbatim bash. This keeps them maintainable and diffable.

Templated constants in `overwatch.sh.erb`: `GPU`, `GPU_AUDIO`, `IGPU`,
`HOST_CPUS`, `SHUTDOWN_SIGNAL_PORT`, `TRANSITION_SIGNAL_PORT`, `VM_NAME`.

Templated constants in `overwatch-monitors.sh.erb`: `VM_IP`,
`WINDOWS_USER`.

Templated constants in `setup-guest.sh.erb`: `VM_NAME`, `HOST_IP`,
`SHUTDOWN_SIGNAL_PORT`, `TRANSITION_SIGNAL_PORT`.

The VM XML (`overwatch-vm.xml.erb`) is fully generated from attributes.

## Anti-cheat design

The VM definition includes five vectors to avoid hypervisor detection
by anti-cheat software:

1. **KVM hidden** — hides CPUID leaf `0x40000000`
2. **Hyper-V vendor ID** — spoofs to `AuthenticAMD` (avoids `Microsoft Hv`)
3. **CPU host-passthrough** — exposes the real CPU model
4. **SMBIOS strings** — real motherboard vendor/product/version from host
5. **GPU VFIO passthrough** — real GPU, not emulated

## GRUB kernel parameters

The cookbook manages these via `node['overwatch']['grub_cmdline_params']`:

- `amd_iommu=on` — enable IOMMU for VFIO passthrough
- `iommu=pt` — passthrough mode (only VFIO devices use IOMMU)
- `hugepages=24576` — 48GiB of 2MB huge pages for VM memory
- `isolcpus=domain,managed_irq,2-7` — isolate vCPU cores from host scheduler
- `nohz_full=2-7` — disable periodic timer tick on vCPU cores
- `rcu_nocbs=2-7` — move RCU callbacks off vCPU cores

An IVRS ACPI override (`/boot/ivrs-override.img` via
`GRUB_EARLY_INITRD_LINUX_CUSTOM`) patches the MSI X870E firmware's
broken IOMMU exclusion flags that block VFIO.

## Verification

```bash
virsh dominfo overwatch            # VM is defined
systemctl cat overwatch            # service unit installed
/usr/local/bin/overwatch status    # host-ready report
ls /usr/local/bin/overwatch*       # lifecycle script + monitors
ls /usr/local/share/overwatch/     # guest setup + autounattend available
```

InSpec: `cinc-auditor exec compliance/profiles/default`

## Reference

- [`reference.md`](reference.md) — Known problems, debugging checklists, stress tests
