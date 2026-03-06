# frozen_string_literal: true

#
# Cookbook:: overwatch
# Recipe:: uninstall
#
# Removes overwatch VM host support files and packages.
# VM definition, disk image, GRUB config, and netplan bridge are preserved.
#
# @since 1.0.0

overwatch 'default' do
  action :uninstall
end
