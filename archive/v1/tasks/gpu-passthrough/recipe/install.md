# Install — Phase 9: Windows 11 + Overwatch

## Phase 9: Install Windows 11 + Overwatch

1. Download the [virtio-win ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) to `/home/myuser/Downloads/virtio-win.iso` (referenced by VM XML)
2. Attach a Windows 11 ISO to the VM
3. Install Windows with UEFI + TPM 2.0
4. Install AMD GPU drivers (Adrenalin) inside Windows
5. Install VirtIO drivers (attach virtio-win.iso, install via Device Manager)
6. Install QEMU Guest Agent (`qemu-ga-x86_64.msi` from virtio-win ISO)
7. Install Battle.net (~738 MB) and Overwatch (~66 GB)
8. Set Overwatch aspect ratio to **21:9** in game settings (for 3440x1440)
9. Apply power settings and AMD driver tuning — see [Phase 10](configure.md#phase-10-power-settings--amd-driver-tuning)
10. Uninstall AMD HD Audio driver — see [Phase 11](configure.md#phase-11-gpu-hda-audio)
11. Set up Defender exclusions — see [Phase 12](configure.md#phase-12-defender--telemetry)
12. Disable AMD telemetry — see [Phase 12](configure.md#phase-12-defender--telemetry)
13. Configure display settings — see [Phase 13](configure.md#phase-13-display-configuration)
14. Set up shutdown signal — see [Phase 14](configure.md#phase-14-shutdown-signal)
