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
  #
  # The 3-way cmdline split (common + host-mode + vm-mode) is rendered into
  # two custom grub menuentries (overwatch-host-mode, overwatch-vm-mode)
  # via /etc/grub.d/40_overwatch_modes. Mode switching is reboot-based —
  # the launcher takes the boot_mode==vm runtime dispatch path and never
  # rebinds the dGPU in-uptime.

  # GRUB_EARLY_INITRD_LINUX_CUSTOM applies to every boot entry (10_linux +
  # 40_overwatch_modes both). The ivrs-override.img early initrd carries
  # the AMD IOMMU override tables that must load before amdgpu and vfio-pci
  # probe.
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

  # --- Reboot-based host-mode / vm-mode switching ---
  #
  # Render the grub.d drop-in that emits the two custom menuentries.
  cmdline_common    = node['overwatch']['grub_cmdline_common'].join(' ')
  cmdline_host_mode = node['overwatch']['grub_cmdline_host_mode'].join(' ')
  cmdline_vm_mode   = node['overwatch']['grub_cmdline_vm_mode'].join(' ')

  template '/etc/grub.d/40_overwatch_modes' do
    source '40_overwatch_modes.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
    variables(
      cmdline_common: cmdline_common,
      cmdline_host_mode: cmdline_host_mode,
      cmdline_vm_mode: cmdline_vm_mode
    )
    notifies :run, 'execute[update-grub]', :immediately
  end

  # Edit /etc/default/grub to use grubenv saved_entry + visible 10s menu.
  # Explicitly NOT setting GRUB_RECORDFAIL_TIMEOUT so the Ubuntu default
  # behavior (show menu until user intervention on recordfail) is preserved
  # as a troubleshooting escape hatch.
  #
  # GRUB_CMDLINE_LINUX_DEFAULT is pinned to just "quiet splash" so
  # 40_overwatch_modes.erb's distro_cmdline inheritance doesn't drag in
  # legacy params (vfio-pci.ids, hugepages, isolcpus, etc.) that would
  # make host-mode no longer actually host-mode. The per-mode params come
  # exclusively from grub_cmdline_common + grub_cmdline_{host,vm}_mode
  # baked into the menuentries. The plain Ubuntu entry (from 10_linux)
  # becomes a clean "rescue" option.
  grub_settings = {
    'GRUB_DEFAULT'              => 'saved',
    'GRUB_TIMEOUT'              => '10',
    'GRUB_TIMEOUT_STYLE'        => 'menu',
    'GRUB_CMDLINE_LINUX_DEFAULT' => '"quiet splash"',
  }

  ruby_block 'configure_grub_defaults' do
    block do
      grub_file = '/etc/default/grub'
      content = ::File.read(grub_file)
      changed = false
      grub_settings.each do |key, value|
        if content =~ /^#{Regexp.escape(key)}=.*$/
          if Regexp.last_match(0) != "#{key}=#{value}"
            content.sub!(/^#{Regexp.escape(key)}=.*$/, "#{key}=#{value}")
            changed = true
          end
        else
          content << "\n#{key}=#{value}\n"
          changed = true
        end
      end
      ::File.write(grub_file, content) if changed
    end
    not_if do
      content = ::File.read('/etc/default/grub')
      grub_settings.all? { |k, v| content =~ /^#{Regexp.escape(k)}=#{Regexp.escape(v)}$/ }
    end
    notifies :run, 'execute[update-grub]', :immediately
  end

  # Initialize grubenv's saved_entry to host-mode on first deployment. The
  # not_if guard skips re-writing if saved_entry is already set (either by
  # a previous converge or by a runtime `grub-set-default` from the
  # overwatch-mode helper), so user runtime mode changes aren't clobbered.
  execute 'grub-set-default-host-mode-initial' do
    command 'grub-set-default overwatch-host-mode'
    not_if 'grub-editenv list 2>/dev/null | grep -q "^saved_entry="'
  end

  # Install the mode-switching helper binary. Used by:
  #   - overwatch@<vm>.service   ExecStartPre=overwatch-mode require vm %i
  #   - host-mode service drop-in ExecStartPre=overwatch-mode require host
  #   - overwatch-resume.service  ExecStart=overwatch-mode resume
  cookbook_file '/usr/local/bin/overwatch-mode' do
    source 'overwatch-mode'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0755'
  end

  # mode-services.conf: rendered list of host-mode services, sourced by
  # /usr/local/bin/overwatch-mode's resume handler at boot. Decoupled
  # from hardcoded workload names so adding/removing host-mode workloads
  # (ollama, blender, stable-diffusion, etc.) is an attribute edit, not
  # a cookbook code change.
  template '/usr/local/share/overwatch/shared/mode-services.conf' do
    source 'mode-services.conf.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    variables(host_mode_services: node['overwatch']['host_mode_services'])
  end

  # Boot-time auto-start: reads /proc/cmdline + pending files, starts
  # either overwatch@<vm>.service (vm-mode, from pending-vm file) or
  # iterates host_mode_services (host-mode, from mode-services.conf).
  # Single owner of "what runs after boot" — both vm and host target
  # services are disabled so resume is the only boot-time trigger.
  template '/etc/systemd/system/overwatch-resume.service' do
    source 'overwatch-resume.service.erb'
    cookbook 'overwatch'
    owner 'root'
    group 'root'
    mode '0644'
    notifies :run, 'execute[systemctl-daemon-reload]', :immediately
  end

  service 'overwatch-resume' do
    action :enable
    subscribes :restart, 'template[/etc/systemd/system/overwatch-resume.service]', :delayed
  end

  # --- Host-mode services: drop-ins + disable ---
  #
  # Each unit in node['overwatch']['host_mode_services'] gets:
  #
  #   1. /etc/systemd/system/<unit>.d/00-host-mode-require.conf — a generic
  #      ExecStartPre=+overwatch-mode require host drop-in. Starting the
  #      unit in vm-mode triggers a reboot to host-mode instead.
  #   2. `systemctl disable <unit>` so the unit does NOT auto-start via
  #      multi-user.target. overwatch-resume.service explicitly starts
  #      each host-mode service when booted into host-mode (and no other
  #      start path). This is the single-owner-of-boot-time-start
  #      principle — avoids reboot loops from wrong-mode auto-starts.
  #
  # Units listed here that aren't installed on the host are silently
  # skipped (only_if guard on disable; drop-in is harmless if the parent
  # unit doesn't exist, systemd ignores orphan .d dirs).
  node['overwatch']['host_mode_services'].each do |unit|
    unit_d_dir = "/etc/systemd/system/#{unit}.d"

    directory unit_d_dir do
      owner 'root'
      group 'root'
      mode '0755'
    end

    # Drop-in filename is '00-host-mode-require.conf':
    #   - The 00- prefix sorts it alphabetically BEFORE any other drop-ins
    #     the target unit might have. systemd reads drop-ins in alphabetical
    #     order and processes ExecStartPre directives in that order — if
    #     another drop-in's ExecStartPre exits non-zero first, the host-mode
    #     gate never runs and the reboot trigger never fires. Example: on
    #     erasimus, ollama.service has a pre-existing gpu-check.conf drop-in
    #     whose ExecStartPre exits 1 when the dGPU isn't on amdgpu; without
    #     the 00- prefix it would block the gate.
    #   - The name 'host-mode-require' describes the function (this service
    #     requires the host to be booted in host-mode), not the binary that
    #     happens to enforce it. This matches the source file in the cookbook
    #     (files/host-mode-require.conf) and avoids confusion with the
    #     /usr/local/bin/overwatch-mode helper, where 'overwatch-' is the
    #     cookbook namespace, not a mode name.
    cookbook_file "#{unit_d_dir}/00-host-mode-require.conf" do
      source 'host-mode-require.conf'
      cookbook 'overwatch'
      owner 'root'
      group 'root'
      mode '0644'
      notifies :run, 'execute[systemctl-daemon-reload]', :immediately
    end

    # Strip .service suffix for Chef's service resource name (it adds it
    # back automatically; passing "ollama.service" would become "ollama.service.service").
    svc_name = unit.sub(/\.service$/, '')
    service svc_name do
      action :disable
      only_if "systemctl list-unit-files #{unit} 2>/dev/null | grep -q #{unit}"
    end
  end

  # --- Per-VM template-unit instance disable ---
  #
  # overwatch@<vm>.service instances must also be disabled so systemd
  # doesn't auto-start them via multi-user.target. overwatch-resume.service
  # is the single boot-time owner; it reads /var/lib/overwatch/pending-vm
  # to know which instance to start. Without this disable, a stale enabled
  # instance would auto-start on every boot regardless of mode or intent,
  # causing races (USB enumeration, vfio readiness) and fighting resume
  # for the mutex.
  node['overwatch']['instances'].each_key do |vm_name|
    svc = "overwatch@#{vm_name}"
    service svc do
      action :disable
      only_if "systemctl is-enabled #{svc}.service 2>/dev/null | grep -q enabled"
    end
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
        qemu_binary: node['overwatch']['qemu_binary'],
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
