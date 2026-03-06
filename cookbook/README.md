# overwatch cookbook

GPU-passthrough Windows 11 gaming VM on myhost. Configures the host
(GRUB, VFIO, network bridge, libvirt VM definition, lifecycle tooling)
and deploys guest setup scripts for manual execution after Windows
installation.

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

After the cookbook converges on myhost:

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

## Template strategy

The lifecycle script is split into two files: `overwatch.sh.erb` (~920
lines) for core logic and `overwatch-monitors.sh.erb` (~465 lines) for
background monitors and deferred boot tasks (sourced at runtime). The
guest setup script is `setup-guest.sh.erb` (~1075 lines). All three
template only a small block of machine-specific constants in the header;
the rest is verbatim bash. This keeps them maintainable and diffable.

Templated constants in `overwatch.sh.erb`: `GPU`, `GPU_AUDIO`, `IGPU`,
`HOST_CPUS`, `SHUTDOWN_SIGNAL_PORT`, `TRANSITION_SIGNAL_PORT`, `VM_NAME`.

`overwatch-monitors.sh.erb` has no templated constants — it is pure bash,
sourced by `overwatch.sh` at runtime.

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

## Uninstall

`recipes/uninstall.rb` reverses the install: removes the systemd
service, lifecycle script, guest setup, udev rules, and GRUB
parameters. Run via `chef-client -o overwatch::uninstall`.

## Verification

```
virsh dominfo overwatch            # VM is defined
systemctl cat overwatch            # service unit installed
/usr/local/bin/overwatch status    # host-ready report
ls /usr/local/bin/overwatch*       # lifecycle script + monitors
ls /usr/local/share/overwatch/     # guest setup + autounattend available
```

InSpec: `cinc-auditor exec cookbooks/overwatch/compliance/profiles/default`
