# frozen_string_literal: true

#
# Cookbook:: overwatch
# Resource:: overwatch
#
# Manages GPU-passthrough Windows gaming VM host setup and VM definition.
#
# @since 1.0.0

unified_mode true

provides :overwatch

property :vm_name, String, default: lazy { node['overwatch']['vm_name'] }
property :target_user, String, default: lazy { node['overwatch']['target_user'] }
property :packages, Array, default: lazy { node['overwatch']['packages'] }
property :gpu, String, default: lazy { node['overwatch']['gpu'] }
property :gpu_audio, String, default: lazy { node['overwatch']['gpu_audio'] }
property :bridge_name, String, default: lazy { node['overwatch']['bridge_name'] }
property :physical_interface, String, default: lazy { node['overwatch']['physical_interface'] }

# ============================================================
# Install
# ============================================================

action :install do
  # --- Additional packages (beyond libvirt cookbook) ---

  new_resource.packages.each do |pkg|
    package pkg do
      action :install
    end
  end

  # --- User groups ---

  %w(libvirt kvm).each do |grp|
    group grp do
      members [new_resource.target_user]
      append true
      action :modify
      only_if "getent group #{grp}"
    end
  end

  # --- GRUB: kernel parameters for VFIO passthrough ---

  grub_params = node['overwatch']['grub_cmdline_params']

  ruby_block 'configure_grub_cmdline' do
    block do
      grub_file = '/etc/default/grub'
      content = ::File.read(grub_file)
      if content =~ /^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"/
        current = Regexp.last_match(1)
        missing = grub_params.reject { |p| current.include?(p.split('=').first) }
        unless missing.empty?
          new_val = "#{current} #{missing.join(' ')}".strip
          content.sub!(/^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*"/, "GRUB_CMDLINE_LINUX_DEFAULT=\"#{new_val}\"")
          ::File.write(grub_file, content)
        end
      end
    end
    not_if do
      content = ::File.read('/etc/default/grub')
      grub_params.all? { |p| content.include?(p) }
    end
    notifies :run, 'execute[update-grub]', :immediately
  end

  # GRUB early initrd for IVRS ACPI override (MSI X870E firmware bug)
  ruby_block 'configure_grub_early_initrd' do
    block do
      grub_file = '/etc/default/grub'
      content = ::File.read(grub_file)
      unless content.include?('GRUB_EARLY_INITRD_LINUX_CUSTOM')
        content << "\nGRUB_EARLY_INITRD_LINUX_CUSTOM=\"ivrs-override.img\"\n"
        ::File.write(grub_file, content)
      end
    end
    not_if 'grep -q "GRUB_EARLY_INITRD_LINUX_CUSTOM" /etc/default/grub'
    notifies :run, 'execute[update-grub]', :immediately
  end

  execute 'update-grub' do
    command 'update-grub'
    action :nothing
  end

  # --- Network bridge: netplan ---

  template "/etc/netplan/01-#{new_resource.bridge_name}.yaml" do
    source 'netplan-bridge.yaml.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0600'
    variables(
      bridge_name: new_resource.bridge_name,
      physical_interface: new_resource.physical_interface,
    )
    not_if { ::File.exist?("/etc/netplan/01-#{new_resource.bridge_name}.yaml") }
  end

  log 'netplan_warning' do
    message "Netplan bridge config written. Run 'sudo netplan apply' manually (risky over SSH)."
    level :warn
    not_if "ip link show #{new_resource.bridge_name} 2>/dev/null | grep -q UP"
  end

  # --- Libvirt bridged network ---

  template '/tmp/overwatch-bridged-net.xml' do
    source 'libvirt-bridged.xml.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    variables(bridge_name: new_resource.bridge_name)
    not_if 'virsh net-info bridged 2>/dev/null'
    notifies :run, 'execute[define-bridged-network]', :immediately
  end

  execute 'define-bridged-network' do
    command 'virsh net-define /tmp/overwatch-bridged-net.xml && rm -f /tmp/overwatch-bridged-net.xml'
    action :nothing
  end

  execute 'autostart-bridged-network' do
    command 'virsh net-autostart bridged'
    not_if 'virsh net-info bridged 2>/dev/null | grep -q "Autostart:.*yes"'
    only_if 'virsh net-info bridged 2>/dev/null'
  end

  execute 'start-bridged-network' do
    command 'virsh net-start bridged'
    not_if 'virsh net-info bridged 2>/dev/null | grep -q "Active:.*yes"'
    only_if 'virsh net-info bridged 2>/dev/null'
  end

  # --- GPU ROM check ---

  gpu_rom = node['overwatch']['gpu_rom']
  log 'gpu_rom_missing' do
    message "GPU ROM not found at #{gpu_rom}. Download VBIOS from TechPowerUp and place it there."
    level :warn
    not_if { ::File.exist?(gpu_rom) }
  end

  # --- Support files ---

  # Overwatch lifecycle script
  template '/usr/local/bin/overwatch' do
    source 'overwatch.sh.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
    variables(
      gpu: node['overwatch']['gpu'],
      gpu_audio: node['overwatch']['gpu_audio'],
      igpu: node['overwatch']['igpu'],
      host_cpus: node['overwatch']['host_cpus'],
      shutdown_signal_port: node['overwatch']['shutdown_signal_port'],
      transition_signal_port: node['overwatch']['transition_signal_port'],
      vm_name: new_resource.vm_name,
    )
  end

  # Overwatch background monitors (sourced by overwatch.sh)
  template '/usr/local/bin/overwatch-monitors.sh' do
    source 'overwatch-monitors.sh.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
  end

  # Systemd service
  template '/etc/systemd/system/overwatch.service' do
    source 'overwatch.service.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    notifies :run, 'execute[systemctl-daemon-reload]', :immediately
  end

  execute 'systemctl-daemon-reload' do
    command 'systemctl daemon-reload'
    action :nothing
  end

  # Udev rules — seat prevention for passthrough GPU
  template '/etc/udev/rules.d/99-gpu-passthrough.rules' do
    source '99-gpu-passthrough.rules.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    variables(gpu: node['overwatch']['gpu'])
    notifies :run, 'execute[udevadm-reload]', :immediately
  end

  execute 'udevadm-reload' do
    command 'udevadm control --reload-rules && udevadm trigger'
    action :nothing
  end

  # amdgpu modprobe config
  file '/etc/modprobe.d/amdgpu.conf' do
    content "options amdgpu runpm=0\n"
    owner 'root'
    group 'root'
    mode '0644'
  end

  # modules-load for vfio-pci
  file '/etc/modules-load.d/vfio-pci.conf' do
    content "vfio-pci\n"
    owner 'root'
    group 'root'
    mode '0644'
  end

  # Libvirt hooks (no-op)
  file '/etc/libvirt/hooks/qemu' do
    content "#!/bin/bash\nexit 0\n"
    owner 'root'
    group 'root'
    mode '0755'
  end

  # GDM monitors.xml sync
  user_monitors = "/home/#{new_resource.target_user}/.config/monitors.xml"
  gdm_monitors = '/var/lib/gdm3/.config/monitors.xml'

  execute 'sync-gdm-monitors' do
    command "mkdir -p $(dirname #{gdm_monitors}) && cp #{user_monitors} #{gdm_monitors} && chown gdm:gdm #{gdm_monitors}"
    only_if { ::File.exist?(user_monitors) }
    not_if { ::File.exist?(gdm_monitors) && ::FileUtils.compare_file(user_monitors, gdm_monitors) }
  end

  # --- Sudoers ---

  template '/etc/sudoers.d/overwatch' do
    source 'sudoers-overwatch.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0440'
    variables(target_user: new_resource.target_user)
    verify 'visudo -cf %{path}'
  end

  # --- Desktop shortcut ---

  desktop_dir = "/home/#{new_resource.target_user}/Desktop"
  template "#{desktop_dir}/overwatch.desktop" do
    source 'overwatch.desktop.erb'
    cookbook 'overwatch'
    owner new_resource.target_user
    group new_resource.target_user
    mode '0755'
    only_if { ::File.directory?(desktop_dir) }
  end

  # --- VM disk ---

  execute "create-vm-disk-#{new_resource.vm_name}" do
    command "qemu-img create -f qcow2 #{node['overwatch']['vm_disk_path']} #{node['overwatch']['vm_disk_size']}"
    not_if { ::File.exist?(node['overwatch']['vm_disk_path']) }
  end

  # --- VM definition ---

  smbios = node['overwatch']['smbios']

  template "/tmp/#{new_resource.vm_name}-vm.xml" do
    source 'overwatch-vm.xml.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    variables(
      vm_name: new_resource.vm_name,
      vm_ram_kib: node['overwatch']['vm_ram_kib'],
      vm_vcpus: node['overwatch']['vm_vcpus'],
      vm_mac: node['overwatch']['vm_mac'],
      vm_disk_path: node['overwatch']['vm_disk_path'],
      gpu: node['overwatch']['gpu'],
      gpu_audio: node['overwatch']['gpu_audio'],
      gpu_rom: node['overwatch']['gpu_rom'],
      vcpu_pins: node['overwatch']['vcpu_pins'],
      emulator_cpuset: node['overwatch']['emulator_cpuset'],
      smbios: smbios,
      usb_devices: node['overwatch']['usb_devices'],
      virtio_iso: node['overwatch']['virtio_iso'],
      vm_app_disk_path: node['overwatch']['vm_app_disk_path'],
      tartarus: node['overwatch']['tartarus'],
    )
    not_if "virsh dominfo #{new_resource.vm_name} 2>/dev/null"
    notifies :run, "execute[define-vm-#{new_resource.vm_name}]", :immediately
  end

  execute "define-vm-#{new_resource.vm_name}" do
    command "virsh define /tmp/#{new_resource.vm_name}-vm.xml && rm -f /tmp/#{new_resource.vm_name}-vm.xml"
    action :nothing
  end

  # --- Guest setup scripts (deployed for manual use) ---

  directory '/usr/local/share/overwatch' do
    owner 'root'
    group 'root'
    mode '0755'
  end

  template '/usr/local/share/overwatch/setup-guest.sh' do
    source 'setup-guest.sh.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
    variables(
      vm_name: new_resource.vm_name,
      host_ip: node['overwatch']['host_ip'],
      shutdown_signal_port: node['overwatch']['shutdown_signal_port'],
      transition_signal_port: node['overwatch']['transition_signal_port'],
    )
  end

  # Transition throttle script (read by setup-guest.sh for guest deployment)
  cookbook_file '/usr/local/share/overwatch/transition-throttle.ps1' do
    source 'transition-throttle.ps1'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
  end

  # autounattend.xml for Windows reinstalls
  cookbook_file '/usr/local/share/overwatch/autounattend.xml' do
    source 'autounattend.xml'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
  end
end

# ============================================================
# Uninstall
# ============================================================

action :uninstall do
  # Stop and disable the service
  service 'overwatch' do
    action %i(stop disable)
    only_if 'systemctl list-unit-files overwatch.service | grep -q overwatch'
  end

  # Remove support files
  %w(
    /usr/local/bin/overwatch
    /usr/local/bin/overwatch-monitors.sh
    /etc/systemd/system/overwatch.service
    /etc/udev/rules.d/99-gpu-passthrough.rules
    /etc/modprobe.d/amdgpu.conf
    /etc/modules-load.d/vfio-pci.conf
    /etc/sudoers.d/overwatch
  ).each do |path|
    file path do
      action :delete
    end
  end

  execute 'systemctl-daemon-reload-uninstall' do
    command 'systemctl daemon-reload'
    action :run
  end

  # Remove desktop shortcut
  file "/home/#{new_resource.target_user}/Desktop/overwatch.desktop" do
    action :delete
  end

  # Remove guest setup scripts
  directory '/usr/local/share/overwatch' do
    action :delete
    recursive true
  end

  # Remove additional packages
  new_resource.packages.each do |pkg|
    package pkg do
      action :purge
    end
  end

  execute 'overwatch_autoremove' do
    command 'apt-get autoremove -y'
    only_if 'apt-get -s autoremove 2>/dev/null | grep -q "^Remv "'
  end

  # NOTE: VM definition, disk, GRUB config, netplan bridge, and libvirt
  # bridged network are intentionally preserved. Use virsh undefine and
  # manual cleanup for destructive teardown.
end
