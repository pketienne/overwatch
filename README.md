# overwatch

GPU passthrough orchestrator for running a Windows 11 VM with dedicated graphics on a Linux host. Dynamically switches a discrete GPU between host and guest without rebooting, enabling one-click gaming (Overwatch 2) while preserving full host functionality.

## Hardware

| Component | Details |
|-----------|---------|
| CPU | AMD Ryzen 7 9800X3D (8C, SMT off) |
| dGPU | Sapphire NITRO+ RX 7900 XTX (`03:00.0`) |
| iGPU | AMD Radeon (`74:00.0`) |
| RAM | 96 GB DDR5 (16 GB allocated to VM) |
| Monitor | LG ULTRAGEAR+ 45" OLED 3440x1440 — HDMI to iGPU, DisplayPort to dGPU |
| Host OS | Ubuntu 24.04, kernel 6.17 |
| Guest OS | Windows 11 (UEFI, TPM 2.0) |

## How It Works

The orchestrator manages a three-state lifecycle:

1. **host-mode** — dGPU on `amdgpu`, host services running (GDM, ollama, openrgb), full CPU available
2. **vfio** — dGPU on `vfio-pci`, host services stopped, CPU cores isolated, iGPU disabled
3. **vm-running** — Windows VM active with exclusive GPU access, performance tuning applied

Transitions are handled by idempotent `ensure_*` functions that check current state before acting — safe to re-run after partial failures.

### Start sequence (~15s to Windows desktop)

1. Stop GDM, ollama, openrgb
2. Release `/dev/dri/*` and `/dev/i2c-*` file descriptors
3. Suspend framebuffer, unbind `amdgpu` and `snd_hda_intel`
4. Bind GPU + audio to `vfio-pci`, PCIe bus reset
5. Start libvirt domain, blank iGPU (monitor auto-switches to DP)
6. Isolate CPU cores 2-7 for VM, set governor to performance, pin IRQs

### Stop sequence (~60s to host desktop)

1. Windows scheduled task sends UDP shutdown signal to host (port 9147)
2. Wait for VM to stop, track QEMU process state (S -> D -> exited)
3. Unbind `vfio-pci`, bus reset, rebind `amdgpu`
4. Restore CPU defaults, unblank iGPU (monitor switches to HDMI)
5. Restart GDM, ollama, openrgb

## Usage

```bash
# Start the VM (or use the desktop shortcut)
sudo systemctl start overwatch

# Stop and restore host
sudo systemctl stop overwatch

# Check current state
sudo overwatch status

# Watch live logs
journalctl -u overwatch -f
```

## Runtime Monitoring

Host and guest metrics are sampled during VM runtime and tagged in journalctl:

| Tag | Interval | Metrics |
|-----|----------|---------|
| `PERF_HOST` | 30s | Per-core CPU %, qcow2 disk I/O latency, memory pressure |
| `PERF_GUEST` | 60s | GPU load, temperature, clocks, power draw, VRAM (via LibreHardwareMonitor WMI) |

Post-boot guest diagnostics query Windows Event Log for previous shutdown duration, crash dumps (TDR livedumps, BSODs), GPU driver status, and display events.

## Project Structure

```
scripts/
  overwatch.sh            # Main orchestrator (~950 lines bash + embedded Python)
  overwatch.service        # systemd unit
  overwatch.desktop            # Desktop shortcut
  overwatch.ps1    # Windows guest shutdown notifier (UDP)

tasks/
  gpu-passthrough-plan.md     # Project goals and hardware summary
  gpu-passthrough/
    how-to.md                 # User guide
    recipe.md                 # Build recipe index
    action-items.md           # Changelog (9 completed fixes)
    instrumentation.md        # Monitoring and diagnostics inventory
    troubleshooting.md        # 31-item problem/cause/solution reference
    recipe/
      setup.md                # Phases 1-8: BIOS, IVRS, VM creation
      install.md              # Phase 9: Windows 11, drivers, Overwatch
      configure.md            # Phases 10-14: power, HDA, display, shutdown signal
      vm-xml-reference.md     # Full libvirt domain XML
      reinstall-notes.md      # OS reinstall notes
  troubleshooting-methodology/
    principles.md             # 10 debugging methods + 7 anti-patterns
    case-studies.md           # Investigation narratives
    checklists.md             # Debugging reference
```

## Key System Files

| File | Purpose |
|------|---------|
| `/usr/local/bin/overwatch` | Installed orchestrator script |
| `/etc/systemd/system/overwatch.service` | Service unit |
| `/etc/default/grub` | `amd_iommu=on`, IVRS override initrd |
| `/boot/acpi-ivrs-override.img` | Patched IVRS ACPI table |
| `/usr/share/qemu/gpu-rom.bin` | RX 7900 XTX VBIOS |
| `/etc/modprobe.d/amdgpu.conf` | `options amdgpu runpm=0` |
| `/etc/udev/rules.d/99-gpu-passthrough.rules` | Prevents dGPU logind seat assignment |
| `/etc/modules-load.d/vfio-pci.conf` | Loads vfio-pci at boot |

## Notable Fixes

| Problem | Solution |
|---------|----------|
| `drm_fb_helper_fini` deadlock on amdgpu unbind (~1.5% hit rate) | Suspend framebuffer via sysfs before unbinding |
| SMU/MES/VCN hangs after passthrough cycles | PCIe Secondary Bus Reset before each driver bind (no FLR on RX 7900 XTX) |
| USB headset audio static during gameplay | Expand host CPU reservation from 1 core to 2 (core 0 was saturating) |
| WATCHDOG TDR crash dumps (~60% baseline) | `TdrDelay=60`, `TdrDdiDelay=60` in Windows registry |

## Dependencies

- libvirt, QEMU/KVM with guest agent
- vfio-pci kernel module, IOMMU enabled
- Python 3 (embedded guest agent communication)
- LibreHardwareMonitor (Windows guest, for GPU sensor telemetry)

## License

Personal project. Not packaged for general distribution.
