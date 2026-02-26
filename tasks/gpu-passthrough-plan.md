# GPU Passthrough: Overwatch on Linux via Windows VM

Runbook for GPU passthrough on myhost — hardware inventory, from-scratch
rebuild, VM configuration, Windows tuning, troubleshooting, and changelog.

## Sections

- [Overview](gpu-passthrough/overview.md) — Goal, hardware summary, current state
- [Rebuild Guide](gpu-passthrough/rebuild-guide.md) — Phases 1-9: BIOS through Windows install
- [Daily Usage](gpu-passthrough/daily-usage.md) — Start, stop, and monitor the VM
- [VM XML Reference](gpu-passthrough/vm-xml-reference.md) — Full libvirt domain XML
- [Windows Configuration](gpu-passthrough/windows-configuration.md) — Power settings, Defender, AMD driver, CPU isolation
- [Troubleshooting](gpu-passthrough/troubleshooting.md) — Problem/cause/solution reference
- [Action Items](gpu-passthrough/action-items.md) — Completed and in-progress fixes
- [Reinstall Notes](gpu-passthrough/reinstall-notes.md) — Things that may change after OS reinstall
