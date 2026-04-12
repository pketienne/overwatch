# Overwatch

Chef/Cinc cookbook for GPU-passthrough Windows gaming VM management on erasimus.

## Project layout

```
overwatch/master/
  attributes/      — VM configuration (VFIO, GPU, network)
  recipes/         — Chef recipe (single default recipe)
  resources/       — Custom Chef resource (overwatch.rb)
  templates/       — ERB templates (VM XML, systemd units, scripts)
  files/           — Static files deployed to host and guest
  compliance/      — InSpec compliance profile
  reference.md     — Detailed operational reference
```

## Architecture

Single cookbook managing the full lifecycle of a QEMU/KVM Windows VM
with GPU passthrough (VFIO). Handles host setup (IOMMU, VFIO drivers,
systemd services, network bridge) and guest provisioning (unattended
install, driver injection, Overwatch 2 automation scripts).

## Dependencies

- Symmetra (parent cookbook collection, provides base resources)
- Semantha (OW2 UI ontology queries for settings automation)
