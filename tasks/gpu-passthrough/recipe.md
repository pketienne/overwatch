# Build Recipe

From-scratch rebuild of GPU passthrough on myhost. Phases are ordered by
dependency — complete each file top-to-bottom before moving to the next.

## Procedure

1. [Setup](recipe/setup.md) — Phases 1-8: BIOS, virtualization stack, IVRS,
   networking, GPU ROM, overwatch, VM creation, desktop shortcut
2. [Install](recipe/install.md) — Phase 9: Windows 11, drivers, Overwatch
3. [Configure](recipe/configure.md) — Phases 10-14: power tuning, HDA audio,
   Defender, display settings, shutdown signal

## Reference

- [VM XML Reference](recipe/vm-xml-reference.md) — Full libvirt domain XML
- [Reinstall Notes](recipe/reinstall-notes.md) — Things that may change after
  OS reinstall
