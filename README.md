# Overwatch VM

GPU-passthrough Windows gaming VM on a Linux host (myhost). AMD RX 7900 XTX passed through to a Windows 11 guest for Overwatch 2 with Ricochet anti-cheat.

## Deployment Artifacts

| File | Deploys to | Purpose |
|---|---|---|
| `overwatch.xml` | myhost via `virsh define` | VM definition (anti-cheat, GPU passthrough, SMBIOS) |
| `scripts/host/overwatch.sh` | myhost `/usr/local/bin/overwatch` | Lifecycle manager (GPU bind/unbind, start/stop) |
| `scripts/host/overwatch.service` | myhost `/etc/systemd/system/` | systemd unit |
| `scripts/guest/overwatch.ps1` | VM `C:\Scripts\` | Shutdown signal (UDP to host) |
| `scripts/guest/transition-throttle.ps1` | VM `C:\Scripts\` | OW2 transition freeze mitigation |

## Documentation

- `kb/steps.md` — Full setup procedure (steps 0–12, execute once to build the VM)
- `kb/troubleshooting.md` — Quick-lookup problem/cause/solution table
- `kb/decisions.md` — Completed work items with rationale
- `kb/vcpu-optimizations.md` — CPU isolation plan (implemented)
- `kb/debugging/` — Debugging methodology (read in order):
  1. `principles.md` — 10 methods + 7 anti-patterns
  2. `case-studies.md` — Detailed investigations illustrating each method
  3. `checklists.md` — Quick-reference debugging checklists
  4. `stress-testing.md` — Synthetic load procedures for reproducing failures
