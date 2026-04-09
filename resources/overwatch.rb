# frozen_string_literal: true

#
# Cookbook:: overwatch
# Resource:: overwatch
#
# Multi-instance GPU-passthrough Windows VM host setup.
#
# Walks node['overwatch']['instances'] and renders per-VM artifacts (config,
# launcher script invocations, libvirt domain XML, qcow2 disk, setup-guest
# bundle, desktop shortcut). Host-wide assets (the launcher binary, the
# shared monitors library, the systemd template unit, the shared D: disk,
# udev/modprobe/sudoers, GRUB, netplan, libvirt bridge) are rendered once.
#
# @since 2.0.0

unified_mode true

provides :overwatch

property :target_user, String, default: lazy { node['overwatch']['target_user'] }
property :packages, Array, default: lazy { node['overwatch']['packages'] }
property :gpu, String, default: lazy { node['overwatch']['gpu'] }
property :gpu_audio, String, default: lazy { node['overwatch']['gpu_audio'] }
property :bridge_name, String, default: lazy { node['overwatch']['bridge_name'] }
property :physical_interface, String, default: lazy { node['overwatch']['physical_interface'] }

action_class do
  # Merge instance_defaults with the per-VM hash and derive paths.
  # Returns a Hash carrying everything the per-VM templates need.
  def instance_for(vm_name, raw)
    defaults = node['overwatch']['instance_defaults'].to_h
    merged = Chef::Mixin::DeepMerge.deep_merge(raw.to_h, defaults)
    merged['vm_name']         = vm_name
    merged['vm_disk_path']    = "/var/lib/libvirt/images/overwatch/#{vm_name}.qcow2"
    merged['vm_app_disk_path'] = "/var/lib/libvirt/images/overwatch/#{vm_name}-app.qcow2"
    merged['stage_dir']       = "/usr/local/share/overwatch/#{vm_name}"
    merged['log_dir']         = "/var/log/overwatch/#{vm_name}"
    merged['state_dir']       = "/var/lib/overwatch/#{vm_name}"
    merged
  end
end

# ============================================================
# Install
# ============================================================

action :install do
  # ============================================================
  # HOST-WIDE: packages, kernel, network, hooks
  # ============================================================

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
      physical_interface: new_resource.physical_interface
    )
    action :create_if_missing
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

  # --- Udev rules — seat prevention for passthrough GPU ---
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

  # --- amdgpu modprobe + vfio-pci modules-load ---
  file '/etc/modprobe.d/amdgpu.conf' do
    content "options amdgpu runpm=0\n"
    owner 'root'
    group 'root'
    mode '0644'
  end

  file '/etc/modules-load.d/vfio-pci.conf' do
    content "vfio-pci\n"
    owner 'root'
    group 'root'
    mode '0644'
  end

  # --- Libvirt hooks (no-op) ---
  file '/etc/libvirt/hooks/qemu' do
    content "#!/bin/bash\nexit 0\n"
    owner 'root'
    group 'root'
    mode '0755'
  end

  # --- GDM monitors.xml sync ---
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

  # ============================================================
  # SHARED: launcher binary, monitors lib, systemd template unit,
  #         shared application disk, runtime dirs, common assets
  # ============================================================

  # Runtime dirs (used by mutex + locks)
  directory '/run/overwatch' do
    owner 'root'
    group 'root'
    mode '0755'
    action :create
  end

  # Top-level dirs
  %w(
    /usr/local/share/overwatch
    /usr/local/share/overwatch/shared
    /var/lib/libvirt/images/overwatch
    /var/lib/libvirt/qemu/nvram/overwatch
    /var/log/overwatch
    /var/lib/overwatch
  ).each do |d|
    directory d do
      owner 'root'
      group 'root'
      mode '0755'
      recursive true
    end
  end

  # Launcher binary (fully static — no per-VM substitution)
  cookbook_file '/usr/local/bin/overwatch' do
    source 'overwatch.sh'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
  end

  # Monitors library (sourced by the launcher; shared across all instances)
  cookbook_file '/usr/local/share/overwatch/shared/overwatch-monitors.sh' do
    source 'overwatch-monitors.sh'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
  end

  # systemd template unit
  template '/etc/systemd/system/overwatch@.service' do
    source 'overwatch@.service.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    notifies :run, 'execute[systemctl-daemon-reload]', :immediately
  end

  # --- Pass 3.7 migration bridge (drop-in for legacy overwatch.service) ---
  #
  # See attributes/default.rb for the legacy_overwatch_service_bridge
  # toggle. Only deployed when that attribute is true (set by the
  # transitional current-state policyfile during migration iterations 2-3).
  # Lets the pre-Pass-3.7 overwatch.service unit continue managing dva
  # after the launcher has been replaced, by overriding its ExecStart to
  # pass "dva" as the VM_NAME arg that the new launcher requires.
  #
  # REMOVED (both this block and the attribute) from the cookbook after
  # iteration 3 of the migration, when dva is cut over to the new
  # overwatch@dva.service template unit.
  if node['overwatch']['legacy_overwatch_service_bridge']
    directory '/etc/systemd/system/overwatch.service.d' do
      owner 'root'
      group 'root'
      mode '0755'
    end

    cookbook_file '/etc/systemd/system/overwatch.service.d/execstart-dva.conf' do
      source 'execstart-dva.conf'
      owner 'root'
      group 'root'
      mode '0644'
      notifies :run, 'execute[systemctl-daemon-reload]', :immediately
    end
  end

  # --- Pass 3.7 migration cleanup (iteration 3 only) ---
  #
  # See attributes/default.rb for the remove_legacy_overwatch_service
  # toggle. This block runs during iteration 3 of the Pass 3.7 migration
  # only. It stops the pre-Pass-3.7 overwatch.service unit (the running
  # launcher's SIGTERM handler cleanly shuts down the VM + restores host
  # state), deletes the unit file + bridge drop-in + stale flat-path lock,
  # and transitions each declared instance onto the new overwatch@<vm>.service
  # template unit.
  #
  # REMOVED (both the attribute and this block) from the cookbook after
  # iteration 3 converges successfully — this is the very dead code the
  # migration is cleaning up.
  if node['overwatch']['remove_legacy_overwatch_service']
    # Step 1: stop + disable the legacy unit. Blocks up to TimeoutStopSec
    # (120s in the old unit) while the old launcher's _do_stop handler
    # shuts down the VM and restores host state. Idempotent — if the unit
    # is already stopped (e.g., operator pre-stopped it), :stop is a no-op.
    service 'overwatch' do
      action [:stop, :disable]
      only_if 'test -f /etc/systemd/system/overwatch.service'
    end

    # Step 2: delete the bridging drop-in (file first, then dir)
    file '/etc/systemd/system/overwatch.service.d/execstart-dva.conf' do
      action :delete
    end

    directory '/etc/systemd/system/overwatch.service.d' do
      recursive true
      action :delete
    end

    # Step 3: delete the legacy unit file + pick up the change
    file '/etc/systemd/system/overwatch.service' do
      action :delete
      notifies :run, 'execute[systemctl-daemon-reload]', :immediately
    end

    # Step 4: remove the stale flat-path lock file left by the pre-Pass-3.7
    # launcher. Idempotent — clean exit of the old launcher should have
    # removed it already via its EXIT trap; this is a safety net in case
    # systemd had to SIGKILL the old process (TimeoutStopSec exceeded).
    file '/run/overwatch.lock' do
      action :delete
    end

    # Step 5: enable + start the new template unit for each declared
    # instance. Chef's service resource is idempotent — if the unit is
    # already enabled/started, these are no-ops. Runs AFTER the legacy
    # unit is gone so the launcher mutex has no stale state to contend
    # with on ExecStartPre.
    node['overwatch']['instances'].each_key do |vm_name|
      service "overwatch@#{vm_name}" do
        action [:enable, :start]
      end
    end
  end

  execute 'systemctl-daemon-reload' do
    command 'systemctl daemon-reload'
    action :nothing
  end

  # Logrotate config for the rolling pcap ring buffer + snapshot directory pruning.
  # NOTE: pcap_snapshot_keep is currently consulted host-wide (the most-permissive
  # value across instances would be ideal, but a single value covers the common case).
  template '/etc/logrotate.d/overwatch-pcap' do
    source 'logrotate-overwatch-pcap.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    variables(
      pcap_snapshot_keep: 0
    )
  end

  # Per-VM application disk (D:) is now created inside the instance loop
  # alongside the per-VM C: disk. Each instance gets its own
  # <vm_name>-app.qcow2 so instances are fully isolated — no shared D:,
  # no libvirt lock contention, no cross-contamination risk. The launcher
  # mutex still enforces single-instance at the systemd layer (anti-cheat
  # + dGPU passthrough singleton).

  # Static cookbook_files used by ALL VMs (each instance's setup-guest pushes
  # them from /usr/local/share/overwatch/<vm>/, so symlink each per-VM stage
  # below; the actual file lives in shared/).
  shared_assets = %w(
    transition-throttle-tray.ps1
    transition-throttle-launcher.vbs
    transition-throttle-tray-launcher.vbs
    amd-driver-monitor-tray.ps1
    amd-driver-monitor-launcher.vbs
  )
  shared_assets.each do |f|
    cookbook_file "/usr/local/share/overwatch/shared/#{f}" do
      source f
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0644'
    end
  end

  # autounattend.xml — templated so the Windows ComputerName matches the
  # host-wide windows_hostname attribute. Shared (host-wide), since every
  # instance on this host boots into a Windows install that uses the same
  # hostname (part of the shared anti-cheat / registration identity).
  template '/usr/local/share/overwatch/shared/autounattend.xml' do
    source 'autounattend.xml.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    variables(windows_hostname: node['overwatch']['windows_hostname'])
  end

  # Synapse 4 profile bundle (shared content; per-VM stage symlinks below)
  remote_directory '/usr/local/share/overwatch/shared/synapse4-profiles' do
    source 'synapse4-profiles'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
    files_owner 'root'
    files_group 'root'
    files_mode '0644'
    purge true
  end

  # ============================================================
  # PER-INSTANCE
  # ============================================================

  instances = node['overwatch']['instances'].to_h
  if instances.empty?
    log 'no_instances' do
      message "node['overwatch']['instances'] is empty — host setup complete, no VMs defined"
      level :warn
    end
  end

  instances.each do |vm_name, raw|
    inst = instance_for(vm_name, raw)

    # Per-VM dirs (synapse4-profiles is provided by symlink below, not as a real dir)
    [
      inst['stage_dir'],
      inst['log_dir'],
      inst['state_dir'],
    ].each do |d|
      directory d do
        owner 'root'
        group 'root'
        mode '0755'
        recursive true
      end
    end

    # instance.conf — sourced by /usr/local/bin/overwatch at runtime
    template "#{inst['stage_dir']}/instance.conf" do
      source 'instance.conf.erb'
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0644'
      variables(
        vm_name: inst['vm_name'],
        vm_mac: node['overwatch']['vm_mac'],
        vm_ip: node['overwatch']['vm_ip'],
        host_ip: node['overwatch']['host_ip'],
        windows_user: inst['windows_user'],
        target_user: new_resource.target_user,
        gpu_passthrough: inst['gpu_passthrough'],
        tartarus_attach: inst['tartarus_attach'],
        gpu: node['overwatch']['gpu'],
        gpu_audio: node['overwatch']['gpu_audio'],
        igpu: node['overwatch']['igpu'],
        host_cpus: node['overwatch']['host_cpus'],
        shutdown_signal_port: inst['shutdown_signal_port'],
        transition_signal_port: inst['transition_signal_port'],
        pcap_capture: inst['pcap_capture'],
        pcap_snapshots: inst['pcap_snapshots'],
        transition_staleness_detection: inst['transition_throttle']['staleness_detection']
      )
    end

    # Per-VM C: disk
    execute "create-vm-disk-#{vm_name}" do
      command "qemu-img create -f qcow2 #{inst['vm_disk_path']} #{inst['vm_disk_size']}"
      not_if { ::File.exist?(inst['vm_disk_path']) }
    end

    # Per-VM D: application disk. Each instance has its own; no shared D:.
    execute "create-vm-app-disk-#{vm_name}" do
      command "qemu-img create -f qcow2 #{inst['vm_app_disk_path']} #{node['overwatch']['vm_app_disk_size']}"
      not_if { ::File.exist?(inst['vm_app_disk_path']) }
    end

    # Per-VM libvirt domain XML + define
    template "/tmp/#{vm_name}-vm.xml" do
      source 'overwatch-vm.xml.erb'
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0644'
      variables(
        vm_name: inst['vm_name'],
        vm_ram_kib: inst['vm_ram_kib'],
        vm_vcpus: inst['vm_vcpus'],
        vm_mac: node['overwatch']['vm_mac'],
        vm_disk_path: inst['vm_disk_path'],
        vm_app_disk_path: inst['vm_app_disk_path'],
        gpu_passthrough: inst['gpu_passthrough'],
        tartarus_attach: inst['tartarus_attach'],
        gpu: node['overwatch']['gpu'],
        gpu_audio: node['overwatch']['gpu_audio'],
        gpu_rom: node['overwatch']['gpu_rom'],
        vcpu_pins: inst['vcpu_pins'],
        emulator_cpuset: node['overwatch']['emulator_cpuset'],
        smbios: node['overwatch']['smbios'],
        usb_devices: inst['usb_devices'],
        virtio_iso: node['overwatch']['virtio_iso'],
        tartarus: inst['tartarus']
      )
      not_if "virsh dominfo #{vm_name} 2>/dev/null"
      notifies :run, "execute[define-vm-#{vm_name}]", :immediately
    end

    execute "define-vm-#{vm_name}" do
      command "virsh define /tmp/#{vm_name}-vm.xml && rm -f /tmp/#{vm_name}-vm.xml"
      action :nothing
    end

    # Per-VM setup-guest.sh (deployed for manual use)
    template "#{inst['stage_dir']}/setup-guest.sh" do
      source 'setup-guest.sh.erb'
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0755'
      variables(
        vm_name: inst['vm_name'],
        host_ip: node['overwatch']['host_ip'],
        shutdown_signal_port: inst['shutdown_signal_port'],
        transition_signal_port: inst['transition_signal_port'],
        windows_user: inst['windows_user']
      )
    end

    # Per-VM transition-throttle.ps1 (rendered with per-VM host_ip / port / windows_user)
    template "#{inst['stage_dir']}/transition-throttle.ps1" do
      source 'transition-throttle.ps1.erb'
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0644'
      variables(
        host_ip: node['overwatch']['host_ip'],
        transition_signal_port: inst['transition_signal_port'],
        windows_user: inst['windows_user']
      )
    end

    # Per-VM throttle-registry-init.ps1 (per-instance enable/auto_detect)
    template "#{inst['stage_dir']}/throttle-registry-init.ps1" do
      source 'throttle-registry-init.ps1.erb'
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0644'
      variables(
        enabled: inst['transition_throttle']['enabled'],
        auto_detect: inst['transition_throttle']['auto_detect']
      )
    end

    # Symlink shared assets into the per-VM stage dir so setup-guest finds them.
    # Each instance's setup-guest reads from /usr/local/share/overwatch/<vm>/.
    shared_link_targets = shared_assets + %w(autounattend.xml synapse4-profiles)
    shared_link_targets.each do |asset|
      link "#{inst['stage_dir']}/#{asset}" do
        to "/usr/local/share/overwatch/shared/#{asset}"
        owner 'root'
        group 'root'
      end
    end

    # Per-VM desktop shortcut
    desktop_dir = "/home/#{new_resource.target_user}/Desktop"
    template "#{desktop_dir}/overwatch-#{vm_name}.desktop" do
      source 'overwatch.desktop.erb'
      cookbook 'overwatch'
      owner new_resource.target_user
      group new_resource.target_user
      mode '0755'
      variables(vm_name: vm_name)
      only_if { ::File.directory?(desktop_dir) }
    end
  end
end

# ============================================================
# Uninstall
# ============================================================

action :uninstall do
  instances = node['overwatch']['instances'].to_h

  # Stop and disable each instance
  instances.each_key do |vm_name|
    service "overwatch@#{vm_name}.service" do
      action %i(stop disable)
      only_if "systemctl list-unit-files 'overwatch@.service' | grep -q overwatch"
    end
  end

  # Per-VM stage dirs and desktop shortcuts
  instances.each_key do |vm_name|
    file "/home/#{new_resource.target_user}/Desktop/overwatch-#{vm_name}.desktop" do
      action :delete
    end
    directory "/usr/local/share/overwatch/#{vm_name}" do
      action :delete
      recursive true
    end
  end

  # Shared support files
  %w(
    /usr/local/bin/overwatch
    /etc/systemd/system/overwatch@.service
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

  # Shared dir (also drops the shared assets + synapse profiles + monitors lib)
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

  # NOTE: VM definitions, qcow2 disks, GRUB config, netplan bridge, libvirt
  # bridged network, and the shared application disk are intentionally
  # preserved. Use virsh undefine and manual cleanup for destructive teardown.
end
