# frozen_string_literal: true

#
# Cookbook:: overwatch
# Recipe:: default
#
# GPU-passthrough Windows gaming VM: host setup + VM definition on myhost.
#
# @chef.scope System: /usr/local/bin/overwatch, /etc/systemd/system/overwatch.service,
#   VM definition, GRUB, netplan, udev, modprobe, sudoers
# @chef.scope User: Desktop shortcut
#
# @note Guest configuration requires a running VM with guest agent.
#   After Windows install + VirtIO drivers, run:
#   sudo /usr/local/share/overwatch/setup-guest.sh all
#
# @since 1.0.0

# =============================================================================
# SYSTEM-LEVEL: Host setup + VM definition
# =============================================================================

overwatch 'default' do
  action :install
end
