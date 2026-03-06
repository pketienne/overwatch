# frozen_string_literal: true

# Overwatch VM Compliance Controls
#
# @chef.verification Validates GPU-passthrough VM host setup

expected_software = input('expected_software', value: [])

control 'overwatch-1.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 1.0
  title 'Overwatch lifecycle script is installed'
  desc 'Verify /usr/local/bin/overwatch exists and is executable'

  describe file('/usr/local/bin/overwatch') do
    it { should exist }
    it { should be_executable }
  end
end

control 'overwatch-2.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 1.0
  title 'Overwatch systemd service is installed'

  describe file('/etc/systemd/system/overwatch.service') do
    it { should exist }
    its('content') { should match(/ExecStart=\/usr\/local\/bin\/overwatch start/) }
  end
end

control 'overwatch-3.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 1.0
  title 'IOMMU and passthrough kernel parameters are configured'

  describe file('/etc/default/grub') do
    its('content') { should match(/amd_iommu=on/) }
    its('content') { should match(/iommu=pt/) }
  end
end

control 'overwatch-3.1' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 1.0
  title 'Hugepages are configured in GRUB'

  describe file('/etc/default/grub') do
    its('content') { should match(/hugepages=24576/) }
  end

  describe file('/proc/meminfo') do
    its('content') { should match(/HugePages_Total:\s+24576/) }
  end
end

control 'overwatch-3.2' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.7
  title 'CPU isolation is configured for VCPU pinning'

  describe file('/etc/default/grub') do
    its('content') { should match(/isolcpus=domain,managed_irq,2-7/) }
    its('content') { should match(/nohz_full=2-7/) }
    its('content') { should match(/rcu_nocbs=2-7/) }
  end
end

control 'overwatch-3.3' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.7
  title 'IVRS ACPI override is configured'

  describe file('/etc/default/grub') do
    its('content') { should match(/GRUB_EARLY_INITRD_LINUX_CUSTOM.*ivrs-override/) }
  end

  describe file('/boot/ivrs-override.img') do
    it { should exist }
  end
end

control 'overwatch-4.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.7
  title 'VFIO-PCI module is configured to load at boot'

  describe file('/etc/modules-load.d/vfio-pci.conf') do
    it { should exist }
    its('content') { should match(/vfio-pci/) }
  end
end

control 'overwatch-5.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.7
  title 'GPU seat prevention udev rule is installed'

  describe file('/etc/udev/rules.d/99-gpu-passthrough.rules') do
    it { should exist }
  end
end

control 'overwatch-6.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 1.0
  title 'Overwatch VM is defined in libvirt'

  describe command('virsh dominfo overwatch') do
    its('exit_status') { should eq 0 }
  end
end

control 'overwatch-7.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.5
  title 'Sudoers file for overwatch service control'

  describe file('/etc/sudoers.d/overwatch') do
    it { should exist }
    its('mode') { should cmp '0440' }
  end
end

control 'overwatch-8.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.5
  title 'Guest setup script is deployed'

  describe file('/usr/local/share/overwatch/setup-guest.sh') do
    it { should exist }
    it { should be_executable }
  end
end

control 'overwatch-9.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.7
  title 'amdgpu runtime PM is disabled'

  describe file('/etc/modprobe.d/amdgpu.conf') do
    it { should exist }
    its('content') { should match(/options amdgpu runpm=0/) }
  end
end

control 'overwatch-10.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 0.5
  title 'Transition throttle script is deployed'

  describe file('/usr/local/share/overwatch/transition-throttle.ps1') do
    it { should exist }
  end
end

control 'overwatch-11.0' do
  tag privilege: 'system'
  only_if { expected_software.include?('overwatch') }
  impact 1.0
  title 'GPU ROM file exists for VFIO passthrough'

  describe file('/usr/share/qemu/gpu-rom.bin') do
    it { should exist }
    its('size') { should be > 0 }
  end
end
