# frozen_string_literal: true

#
# Cookbook:: overwatch
# Attributes:: default
#
# Generic defaults. Override machine-specific values (SMBIOS, network,
# user, etc.) in a policyfile or node attributes.
#

# =============================================================================
# Additional Packages (beyond libvirt cookbook)
# =============================================================================

default['overwatch']['packages'] = %w(
  qemu-kvm
  ovmf
  swtpm
  swtpm-tools
  bridge-utils
)

# =============================================================================
# VM Definition
# =============================================================================

default['overwatch']['vm_name']      = 'overwatch'
default['overwatch']['vm_disk_path'] = '/var/lib/libvirt/images/overwatch.qcow2'
default['overwatch']['vm_disk_size'] = '200G'
default['overwatch']['vm_app_disk_path'] = '/var/lib/libvirt/images/overwatch-app.qcow2'
default['overwatch']['vm_ram_kib']   = 50_331_648 # 48 GB
default['overwatch']['vm_vcpus']     = 6
default['overwatch']['vm_mac']       = '' # must override

# =============================================================================
# GPU / PCI (topology-specific — override per host)
# =============================================================================

default['overwatch']['gpu']       = '0000:03:00.0'
default['overwatch']['gpu_audio'] = '0000:03:00.1'
default['overwatch']['igpu']      = '0000:74:00.0'
default['overwatch']['gpu_rom']   = '/usr/share/qemu/gpu-rom.bin'

# =============================================================================
# CPU Pinning
# =============================================================================

default['overwatch']['host_cpus']       = '0-1'
default['overwatch']['emulator_cpuset'] = '0-1'
default['overwatch']['vcpu_pins'] = [
  { 'vcpu' => 0, 'cpuset' => '2' },
  { 'vcpu' => 1, 'cpuset' => '3' },
  { 'vcpu' => 2, 'cpuset' => '4' },
  { 'vcpu' => 3, 'cpuset' => '5' },
  { 'vcpu' => 4, 'cpuset' => '6' },
  { 'vcpu' => 5, 'cpuset' => '7' },
]

# =============================================================================
# SMBIOS (match real host hardware for anti-cheat — override per host)
# =============================================================================

default['overwatch']['smbios'] = {
  'bios_vendor'        => 'American Megatrends International, LLC.',
  'bios_version'       => '',
  'bios_date'          => '',
  'sys_manufacturer'   => '',
  'sys_product'        => '',
  'sys_version'        => '1.0',
  'board_manufacturer' => '',
  'board_product'      => '',
  'board_version'      => '1.0',
  'board_serial'       => 'To be filled by O.E.M.',
  'sys_serial'         => 'To be filled by O.E.M.',
}

# =============================================================================
# USB Devices (passthrough to VM)
# =============================================================================

default['overwatch']['usb_devices'] = []

# Tartarus V2: attached at runtime by overwatch.sh after Synapse is running
default['overwatch']['tartarus'] = { 'vid' => '0x1532', 'pid' => '0x022b' }

# =============================================================================
# Network
# =============================================================================

default['overwatch']['bridge_name']         = 'br0'
default['overwatch']['physical_interface']  = '' # must override
default['overwatch']['host_ip']             = '' # must override
default['overwatch']['vm_ip']               = '' # must override
default['overwatch']['shutdown_signal_port'] = 9147
default['overwatch']['transition_signal_port'] = 9148
default['overwatch']['pcap_snapshots']         = false

# =============================================================================
# Host / User
# =============================================================================

default['overwatch']['target_user']  = '' # must override (Linux username)
default['overwatch']['windows_user'] = '' # must override (Windows guest username)
default['overwatch']['virtio_iso']   = '' # path to virtio-win.iso (optional)

# =============================================================================
# GRUB Kernel Parameters
# =============================================================================

default['overwatch']['grub_cmdline_params'] = %w(
  amd_iommu=on
  iommu=pt
  hugepages=24576
  isolcpus=domain,managed_irq,2-7
  nohz_full=2-7
  rcu_nocbs=2-7
  vfio-pci.ids=1002:744c,1002:ab30
  vfio-pci.disable_vga=1
  kvm_amd.avic=1
  kvm.ignore_msrs=1
  kvm.report_ignored_msrs=0
)
