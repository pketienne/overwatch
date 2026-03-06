# frozen_string_literal: true

#
# Cookbook:: overwatch
# Attributes:: default
#
# System-level only. All values are myhost-specific defaults.
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
default['overwatch']['vm_mac']       = 'aa:bb:cc:dd:ee:ff'

# =============================================================================
# GPU / PCI
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
# SMBIOS (match real host hardware for anti-cheat)
# =============================================================================

default['overwatch']['smbios'] = {
  'bios_vendor'        => 'American Megatrends International, LLC.',
  'bios_version'       => '1.A80',
  'bios_date'          => '01/08/2026',
  'sys_manufacturer'   => 'Micro-Star International Co., Ltd.',
  'sys_product'        => 'MS-7E49',
  'sys_version'        => '1.0',
  'board_manufacturer' => 'Micro-Star International Co., Ltd.',
  'board_product'      => 'MPG X870E CARBON WIFI (MS-7E49)',
  'board_version'      => '1.0',
  'board_serial'       => 'XXXXXXXXXX',
  'sys_serial'         => 'To be filled by O.E.M.',
}

# =============================================================================
# USB Devices (passthrough to VM)
# =============================================================================

default['overwatch']['usb_devices'] = [
  { 'vid' => '0x29ea', 'pid' => '0x0102', 'name' => 'Kinesis Advantage2' },
  { 'vid' => '0x1532', 'pid' => '0x00a7', 'name' => 'Razer Naga V2 Pro' },
  { 'vid' => '0x1532', 'pid' => '0x0c05', 'name' => 'Razer Strider Chroma' },
  { 'vid' => '0x1038', 'pid' => '0x1294', 'name' => 'SteelSeries Arctis Pro Wireless' },
]

# Tartarus V2: attached at runtime by overwatch.sh after Synapse is running
default['overwatch']['tartarus'] = { 'vid' => '0x1532', 'pid' => '0x022b' }

# =============================================================================
# Network
# =============================================================================

default['overwatch']['bridge_name']         = 'br0'
default['overwatch']['physical_interface']  = 'enp8s0'
default['overwatch']['host_ip']             = '192.168.0.100'
default['overwatch']['shutdown_signal_port'] = 9147
default['overwatch']['transition_signal_port'] = 9148

# =============================================================================
# Host / User
# =============================================================================

default['overwatch']['target_user'] = 'myuser'
default['overwatch']['virtio_iso']  = '/home/myuser/Downloads/virtio-win.iso'

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
)
