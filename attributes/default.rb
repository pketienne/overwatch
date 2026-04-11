# frozen_string_literal: true

#
# Cookbook:: overwatch
# Attributes:: default
#
# Multi-instance attribute model.
#
# Each VM is declared as a key in node['overwatch']['instances']:
#
#   default['overwatch']['instances']['dva'] = {
#     'vm_mac'           => '34:5a:60:b2:e7:41',
#     'vm_ip'            => '192.168.0.111',
#     'gpu_passthrough'  => true,
#     'tartarus_attach'  => true,
#     ...
#   }
#
# Top-level node['overwatch'][...] keys define cookbook-wide defaults
# that each instance inherits unless explicitly overridden in the
# instance hash. The resource merges them at converge time.
#
# This file does NOT declare any instances. Per-(host, vm) policyfiles
# (in symmetra: policyfiles/overwatch/<host>-<vm>.rb) populate the
# instances hash with concrete values.
#

# =============================================================================
# Cookbook-wide defaults (host-level)
# =============================================================================

default['overwatch']['packages'] = %w(
  qemu-kvm
  ovmf
  swtpm
  swtpm-tools
  bridge-utils
)

# Linux user that owns the host-side overwatch ergonomics (Desktop shortcut,
# group memberships). One per host, not per VM.
default['overwatch']['target_user'] = '' # must override

# Network bridge & uplink (one per host)
default['overwatch']['bridge_name']         = 'br0'
default['overwatch']['physical_interface']  = '' # must override
default['overwatch']['host_ip']             = '' # must override

# vm_mac + vm_ip are HOST-WIDE, not per-instance.
#
# !!! ANTI-CHEAT LOCKED !!!
# All overwatch instances on this host share a single Windows registration,
# Razer Synapse cloud binding, Battle.net hardware identity, and OW2 Ricochet
# hardware-fingerprint hash. Windows binds these to the NIC MAC + SMBIOS +
# disk serials + CPU + RAM. Two instances with the same MAC + SMBIOS look
# like one machine to Windows — a fresh install on either activates against
# the same entitlement.
#
# Concurrency safety (same MAC on the same L2 segment is normally a disaster):
#   1. /run/overwatch/active-vm  cross-VM mutex (refuses concurrent starts)
#   2. libvirt lock manager      on the shared D: qcow2
#   3. /run/overwatch/<vm>.lock  per-VM flock (auto-released on crash)
# These three layers ensure only one instance is ever on the bridge.
#
# Once registered, vm_mac MUST NEVER change. Editing it forces Windows
# re-registration and may trigger an anti-cheat ban review.
default['overwatch']['vm_mac'] = '' # must override per host
default['overwatch']['vm_ip']  = '' # must override per host

# Windows computer name — also HOST-WIDE for the same shared-registration
# reasons as vm_mac. The Windows hostname is part of how Razer Synapse,
# Battle.net, and (some) anti-cheat systems identify "the same machine I
# saw last time". Every overwatch instance on this host boots into a
# Windows install that uses this hostname (autounattend.xml during fresh
# install; preserved across reboots thereafter). Once an instance has
# registered Windows under this hostname, it must NEVER change without
# planning re-registration.
default['overwatch']['windows_hostname'] = '' # must override per host

# =============================================================================
# Reboot-based host-mode / vm-mode switching
# =============================================================================
#
# The GRUB kernel cmdline is split into two distinct boot entries:
#
#   host-mode: dGPU on amdgpu, ollama (and other host-mode workloads) can
#              run inference, full host CPU/RAM available, no hugepages or
#              core isolation.
#   vm-mode:   dGPU on vfio-pci at boot, hugepages reserved, host CPUs 2-7
#              isolated, VM auto-started by overwatch-resume.service.
#
# Mode switching is reboot-based via `overwatch-mode require vm <name>` or
# `overwatch-mode require host`, which writes a persistent saved_entry to
# grubenv (via grub-set-default) and schedules a reboot. The 10-second
# visible grub menu gives the user an escape hatch for troubleshooting.
#
# These three attributes are consumed by templates/40_overwatch_modes.erb,
# rendered into /etc/grub.d/40_overwatch_modes.
default['overwatch']['grub_cmdline_common'] = %w(
  amd_iommu=on
  iommu=pt
  kvm_amd.avic=1
  kvm.ignore_msrs=1
  kvm.report_ignored_msrs=0
)
default['overwatch']['grub_cmdline_host_mode'] = %w(
  overwatch.mode=host
)
default['overwatch']['grub_cmdline_vm_mode'] = %w(
  overwatch.mode=vm
  hugepages=24576
  isolcpus=domain,2-7
  nohz_full=2-7
  rcu_nocbs=2-7
  vfio-pci.ids=1002:744c,1002:ab30
  vfio-pci.disable_vga=1
)

# List of systemd units that are host-mode services — i.e., they require
# the dGPU to be on amdgpu (not vfio-pci) and therefore cannot run while
# the host is booted into vm-mode. Each unit in this list gets:
#
#   1. A drop-in at /etc/systemd/system/<unit>.d/00-host-mode-require.conf
#      with `ExecStartPre=+/usr/local/bin/overwatch-mode require host` —
#      invoking the unit while in vm-mode triggers a reboot to host-mode
#      instead.
#   2. An explicit `systemctl disable` so it does NOT auto-start via
#      multi-user.target. overwatch-resume.service is the single owner of
#      boot-time starts and explicitly starts each host-mode service when
#      booted into host-mode.
#
# Default: ['ollama.service']. Override to extend (e.g., add a blender
# daemon, stable-diffusion service, etc.) or set to [] to leave host-mode
# with no auto-started workloads (pure desktop mode). Units listed here
# that are NOT installed on the host are silently skipped (only_if guards
# on disable + soft-fail on start).
default['overwatch']['host_mode_services'] = ['ollama.service']

# Per-host GPU topology (passthrough VMs reference this; non-passthrough VMs ignore)
default['overwatch']['gpu']       = '0000:03:00.0'
default['overwatch']['gpu_audio'] = '0000:03:00.1'

# gpu_rom: !!! ANTI-CHEAT RELEVANT !!!
# The vBIOS file QEMU loads for the passthrough GPU. Its contents
# determine the device subsystem ID and init sequence Windows sees on
# boot. Replacing this file changes how the dGPU appears to the guest
# and may affect Ricochet's hardware-fingerprint hash. Don't swap it
# unless you've also planned for re-registration.
default['overwatch']['qemu_binary'] = '/usr/local/bin/qemu-system-x86_64'
default['overwatch']['gpu_rom'] = '/usr/share/qemu/gpu-rom.bin'

# Reserved host CPU set (used by passthrough launcher to confine host work)
default['overwatch']['host_cpus']       = '0-1'
default['overwatch']['emulator_cpuset'] = '0-1'

# Optional virtio-win.iso (used during fresh Windows install only)
default['overwatch']['virtio_iso'] = ''

# SMBIOS — host motherboard fingerprint shown to every guest for anti-cheat.
# Tied to the physical host, not the VM, so it's host-wide. Each VM presents
# the SAME smbios to its guest, matching the real hardware on this host.
# Override the populated values in the host-(or per-(host,vm)) policyfile.
#
# !!! ANTI-CHEAT LOCKED !!!
# Every field in this hash contributes to the Windows hardware hash that
# OS licensing, MS Store activation, Razer Synapse cloud binding, and OW2
# Ricochet anti-cheat use to fingerprint the machine. Once an instance has
# booted Windows for the first time, these values must NEVER change for
# that instance. Edit only when the actual host hardware (motherboard /
# BIOS) is replaced; then plan a Windows re-registration.
default['overwatch']['smbios'] = {
  'bios_vendor' => 'American Megatrends International, LLC.',
  'bios_version' => '',
  'bios_date' => '',
  'sys_manufacturer' => '',
  'sys_product' => '',
  'sys_version' => '1.0',
  'board_manufacturer' => '',
  'board_product' => '',
  'board_version' => '1.0',
  'board_serial' => 'To be filled by O.E.M.',
  'sys_serial' => 'To be filled by O.E.M.',
}

# Per-VM application disk (D:) default size. Each instance gets its own
# <vm_name>-app.qcow2 (path derived from vm_name in resources/overwatch.rb's
# instance_for method). No shared D: — instances are fully isolated to
# avoid cross-contamination between production (dva) and test (mercy) VMs.
default['overwatch']['vm_app_disk_size'] = '128G'

# =============================================================================
# Instance defaults (template merged into each instance hash)
# =============================================================================
#
# A policyfile sets node['overwatch']['instances']['<vm>'] = { ... }; the
# resource deep-merges these defaults underneath so policyfiles only need to
# specify the keys that differ from the default.

default['overwatch']['instance_defaults'] = {
  # --- VM topology ---
  #
  # !!! ANTI-CHEAT LOCKED FIELDS !!!
  # vm_ram_kib and vm_vcpus feed the Windows hardware hash used by OS
  # licensing, MS Store activation, Razer Synapse cloud binding, and OW2
  # Ricochet anti-cheat. All instances on this host share a single
  # registration (see node['overwatch']['vm_mac'] / smbios), so editing
  # these for one instance breaks the shared fingerprint for all of them.
  # Once any instance has booted Windows for the first time, these values
  # must NEVER change.
  'vm_disk_size' => '200G',
  'vm_ram_kib' => 50_331_648, # 48 GB
  'vm_vcpus' => 6,

  # --- Capability toggles ---
  # gpu_passthrough = true  → launcher runs the full vfio handoff dance,
  #                           XML includes the dGPU hostdev, host CPU isolation
  #                           is applied, services (gdm/openrgb/ollama) cycle
  # gpu_passthrough = false → launcher just `virsh start`s the VM as-is,
  #                           XML uses virtio-vga, no host disruption
  'gpu_passthrough' => true,

  # tartarus_attach = true  → launcher runs the deferred Tartarus hot-plug
  #                           loop after Synapse is ready (and re-fires on
  #                           every guest reboot). Tartarus is NOT in the
  #                           static XML in this case.
  # tartarus_attach = false → no deferred attach loop; Tartarus (if any) is
  #                           in the static USB hostdev list
  'tartarus_attach' => false,

  # vfio_instrument = true  → start vfio-instrument daemon bound to the VM
  #                           lifecycle (BindsTo). Logs GPU IRQ rate, KVM
  #                           exit counts, and NIC packet flow to
  #                           /var/log/overwatch/<vm>/vfio-instrument.csv.
  # vfio_instrument = false → instrumentation disabled.
  # Enable only for investigation sessions; per-second polling has negligible
  # CPU cost but the log grows ~1MB/hour.
  'vfio_instrument' => false,

  # --- vCPU pinning (only used when gpu_passthrough = true) ---
  'vcpu_pins' => [
    { 'vcpu' => 0, 'cpuset' => '2' },
    { 'vcpu' => 1, 'cpuset' => '3' },
    { 'vcpu' => 2, 'cpuset' => '4' },
    { 'vcpu' => 3, 'cpuset' => '5' },
    { 'vcpu' => 4, 'cpuset' => '6' },
    { 'vcpu' => 5, 'cpuset' => '7' },
  ],

  # --- USB devices (libvirt static hostdev list) ---
  'usb_devices' => [],

  # --- Tartarus device id (consumed by deferred-attach when enabled) ---
  'tartarus' => { 'vid' => '0x1532', 'pid' => '0x022b' },

  # --- Per-VM listener ports ---
  # Distinct per instance even though only one VM ever runs at a time
  # (the launcher mutex enforces single-instance). Distinct ports keep
  # journald log lines unambiguous about which VM emitted what.
  'shutdown_signal_port' => 9147,
  'transition_signal_port' => 9148,

  # --- Guest user ---
  'windows_user' => '', # must override per instance

  # --- Packet capture toggles ---
  'pcap_capture' => false,
  'pcap_snapshots' => false,
  'pcap_snapshot_keep' => 0,

  # --- Transition throttle (only meaningful when gpu_passthrough = true) ---
  'transition_throttle' => {
    'enabled' => true,
    'auto_detect' => false,
    'staleness_detection' => false,
  },
}

# =============================================================================
# Instances — populated by per-(host, vm) policyfiles, NOT here
# =============================================================================

default['overwatch']['instances'] = {}
