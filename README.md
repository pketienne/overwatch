# Overwatch VM

GPU-passthrough Windows gaming VM on a Linux host (myhost). AMD RX 7900 XTX passed through to a Windows 11 guest for Overwatch 2 with Ricochet anti-cheat.

## Key Files

- `overwatch.xml` — VM definition
- `scripts/overwatch.sh` — Lifecycle script (GPU bind/unbind, start/stop)
- `scripts/overwatch.service` — systemd unit
- `steps.md` — Full setup procedure
- `kb/troubleshooting.md` — Problem/cause/solution reference
- `kb/debugging/` — Debugging methodology and case studies
