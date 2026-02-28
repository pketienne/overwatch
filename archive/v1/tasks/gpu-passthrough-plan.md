# GPU Passthrough: Overwatch on Linux via Windows VM

## Goal

One-click GPU passthrough for Overwatch 2 on myhost. The RX 7900 XTX is switchable between host use (ollama, DaVinci Resolve, OBS) and VM use (gaming) without rebooting.


## Hardware Summary

- **CPU**: AMD Ryzen 7 9800X3D (8 cores, SMT disabled)
- **Discrete GPU**: Sapphire NITRO+ RX 7900 XTX Vapor-X (PCI `03:00.0`, IOMMU group 15, device ID `1002:744c`, subsystem `1DA2:E471`)
- **GPU Audio**: Navi 31 HDMI/DP Audio (PCI `03:00.1`, device ID `1002:ab30`)
- **Integrated GPU**: AMD `1002:13c0` (PCI `74:00.0`, IOMMU group 30)
- **Motherboard**: MSI MPG X870E CARBON WIFI (MS-7E49), BIOS 1.A80 (Jan 8, 2026)
- **RAM**: 96GB DDR5 (16GB allocated to VM)
- **Monitor**: LG ULTRAGEAR+ 45" OLED (3440x1440 native, HDMI to iGPU, DP to 7900 XTX)
- **Input**: Kinesis Advantage2 (29ea:0102), Razer Naga V2 Pro (1532:00a7), Razer Tartarus V2 (1532:022b), Razer Strider Chroma (1532:0c05), SteelSeries Arctis Pro Wireless (1038:1290 + 1038:1294)
- **Bootloader**: GRUB (Ubuntu, kernel 6.17.0-14-generic)
- **Host**: myhost (192.168.0.100), accessed via SSH from devbox (192.168.0.102)


## Current State

- Full GPU passthrough lifecycle without rebooting — unlimited VM cycles via driver bind/unbind (amdgpu <-> vfio-pci)
- Overwatch runs at 3440x1440 fullscreen with no anti-cheat issues
- iGPU display on Wayland at 3440x1440@85Hz on HDMI
- Automatic display switching — iGPU blanked when VM starts (monitor auto-detects to DP), unblanked on restore
- All USB devices passed through (keyboard, mouse, keypad, mousepad, headset)
- Windows 11 VM with UEFI, TPM 2.0, anti-cheat tweaks
- Bridged networking (VM gets own IP on LAN)
- One-click desktop shortcut: click -> play -> shut down Windows -> back to desktop
- Lock file prevents concurrent overwatch instances
- Host-side CPU isolation: vCPU cores (2-7) get zero host interference; emulator/IO pinned to cores 0-1
- Auto HDR disabled (native HDR on), Game Bar disabled, AMD telemetry disabled
- TDR timeout set to 60s (`TdrDelay`, `TdrDdiDelay`) — eliminates boot-time WATCHDOG dumps caused by DxgKrnl WDDM init under contention (0/4 dumps in testing)

### Kernel Parameters

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on"
```

### Key Files on myhost

| File | Purpose |
|---|---|
| `/usr/share/qemu/gpu-rom.bin` | Sapphire NITRO+ RX 7900 XTX Vapor-X VBIOS (2MB, from TechPowerUp) |
| `/usr/local/bin/overwatch` | VM lifecycle script — stops services, switches GPU drivers, starts VM, waits for shutdown, restores host. Logs to journald |
| `/etc/systemd/system/overwatch.service` | Systemd service unit for overwatch (`Type=simple`, `ExecStart=/usr/local/bin/overwatch start`). Start with `systemctl start overwatch`, stop with `systemctl stop overwatch` |
| `/etc/modprobe.d/amdgpu.conf` | `options amdgpu runpm=0` — disables runtime PM to prevent GPU crashes during D3 resume |
| `/etc/udev/rules.d/99-gpu-passthrough.rules` | Prevents discrete GPU DRM device from getting a logind seat (stops GDM greeter on dGPU) |
| `/etc/modules-load.d/vfio-pci.conf` | Ensures vfio-pci module loads at boot |
| `/var/lib/gdm3/.config/monitors.xml` | GDM display config (3440x1440@85Hz on iGPU HDMI, dGPU DP disabled) |
| `/etc/libvirt/hooks/qemu` | No-op (`exit 0`) — prevents hook deadlocks with systemctl/virsh |
| `C:\ProgramData\overwatch\overwatch.ps1` | Sends UDP shutdown signal to overwatch; triggered by `NotifyHostShutdown` scheduled task on Event ID 1074 |

## Sections

- [How To](gpu-passthrough/how-to.md) — Start, stop, and monitor the VM
- [Build Recipe](gpu-passthrough/recipe.md) — From-scratch host and guest setup
- [Troubleshooting](gpu-passthrough/troubleshooting.md) — Problem/cause/solution reference
- [Action Items](gpu-passthrough/action-items.md) — Completed fixes and changelog
- [Instrumentation](gpu-passthrough/instrumentation.md) — Monitoring and diagnostics inventory
- [Troubleshooting Methodology](troubleshooting-methodology.md) — Generalizable debugging lessons
  - [Principles](troubleshooting-methodology/principles.md) — 10 methods + 7 anti-patterns
  - [Case Studies](troubleshooting-methodology/case-studies.md) — Project timeline and detailed investigations
  - [Checklists](troubleshooting-methodology/checklists.md) — Debugging reference for future hardware passthrough
