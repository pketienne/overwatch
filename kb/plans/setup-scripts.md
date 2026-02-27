# Plan: Setup Scripts for GPU Passthrough VM

## Context

All initial host/VM/guest setup is currently manual, documented across `tasks/gpu-passthrough/recipe/`. The runtime lifecycle is handled by `overwatch.sh`, but there's no automation for the one-time setup steps (Phases 2-14). Phase 1 (BIOS) and Phase 9 (Windows/driver/game install) remain manual — they require physical interaction or GUI installers.

## New Files

```
scripts/
  setup-host.sh     # Host infrastructure (Phases 2-8)
  setup-vm.sh       # VM creation (Phase 7)
  setup-guest.sh    # Guest configuration via QGA (Phases 10-14)
```

All three scripts follow `overwatch.sh` conventions: `set -uo pipefail`, `log()`, ERR trap, idempotent `ensure_*()` functions, Python heredocs for guest agent, no colors.

## Design Decisions

- **No shared config file** — constants duplicated per script (matches `overwatch.sh` pattern, avoids dependency)
- **VM XML embedded as heredoc** in `setup-vm.sh` (from `vm-xml-reference.md`, variables for PCI addresses/disk path)
- **Each guest phase independently runnable** — for re-running after driver/Windows updates
- **No interactive prompts** — idempotency makes re-running safe; `--dry-run` flag shows what would change
- **One Python heredoc per phase** in `setup-guest.sh` — batches `run_ps()` calls within a single process to avoid reconnecting guest agent per command

## Script 1: `setup-host.sh` (~350 lines)

Subcommands: `all | prereqs | virt-stack | ivrs | network | gpu-rom | support | sudoers | desktop`

| Function | What it does |
|----------|-------------|
| `ensure_prereqs()` | Verify IOMMU enabled, kernel modules, IOMMU groups |
| `ensure_virt_stack()` | `apt install` missing packages, add user to groups, `virt-host-validate` |
| `ensure_ivrs()` | Python heredoc: read IVRS table, patch exclusion flags, create CPIO initrd |
| `ensure_grub_config()` | Add `amd_iommu=on` + IVRS initrd to GRUB, `update-grub` |
| `ensure_network()` | Write netplan bridge config, create libvirt bridged network |
| `ensure_gpu_rom()` | Verify `/usr/share/qemu/gpu-rom.bin` exists (can't auto-download) |
| `ensure_support_files()` | Install `overwatch` to `/usr/local/bin`, `.service`, udev rules, modprobe, modules-load, monitors.xml, no-op libvirt hook |
| `ensure_sudoers()` | Create `/etc/sudoers.d/overwatch`, validate with `visudo -cf` |
| `ensure_desktop_shortcut()` | Copy `overwatch.desktop` to `~/Desktop/` |

Helper: `install_file(src, dst, mode)` and `install_content(dst, mode, content)` for idempotent file operations.

## Script 2: `setup-vm.sh` (~300 lines)

Subcommands: `all | disk | define | verify`

| Function | What it does |
|----------|-------------|
| `ensure_disk()` | `qemu-img create` the qcow2 if it doesn't exist |
| `ensure_vm_defined()` | Write full XML heredoc to temp file, `virsh define` |
| `verify_vm()` | `virsh dominfo`, print summary |

XML from `vm-xml-reference.md` embedded with bash variable substitution for PCI addresses, disk path, MAC, USB devices. USB hostdevs generated from an array.

## Script 3: `setup-guest.sh` (~450 lines)

Subcommands: `all | power | hda-audio | defender | display | shutdown | verify`

Prerequisite: VM running with guest agent active (`ensure_guest_agent()` checks first).

| Function | Phase | PowerShell commands |
|----------|-------|-------------------|
| `ensure_power_settings()` | 10 | 8 `powercfg` commands + 3 AMD registry values |
| `ensure_hda_audio()` | 11 | Query driver store for correct OEM inf, `pnputil` remove |
| `ensure_defender_exclusions()` | 12 | 6 path + 9 process exclusions via `Add-MpPreference` |
| `ensure_telemetry_disabled()` | 12 | Disable AUEPLauncher service + StartAUEP task |
| `ensure_display_config()` | 13 | Registry: Auto HDR off, Game Bar off, toast off |
| `ensure_shutdown_signal()` | 14 | Write `overwatch.ps1` via `guest-file-*` API, create scheduled task |

Each function is a self-contained Python heredoc with `qga()`/`run_ps()` (same pattern as `overwatch.sh`). Idempotency via querying current state before applying changes.

## Known Pitfalls

- **IVRS byte offsets** (`0xC9`, `0xE9`, `0x109`) are motherboard-specific — script should verify expected values before patching
- **HDA audio OEM inf** (`oem39.inf`) varies per install — query `pnputil /enum-drivers` to find the right one
- **AMD registry index** (`\0001`) assumes Basic Display at `\0000` — verify by querying `DriverDesc`
- **Netplan filename** may differ — detect existing config rather than hardcode

## Implementation Order

1. `setup-host.sh` — no dependencies on other new scripts
2. `setup-vm.sh` — needs libvirt from step 1
3. `setup-guest.sh` — needs running VM from step 2

## Verification

- `setup-host.sh all` then `setup-host.sh all` again — second run should log all skips
- `setup-vm.sh verify` — confirms domain defined with correct resources
- `setup-guest.sh verify` — queries all settings and reports current vs expected
