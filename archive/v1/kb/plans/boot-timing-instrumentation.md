# Plan: Boot Timing Instrumentation

## Context
The "Windows boot → usable desktop" duration is the slowest part of the VM lifecycle (~50s+). We need instrumentation to measure each phase and identify optimization targets. Four measurement points cover the full timeline from `virsh start` to Synapse settings applied.

## Changes

### 1. Host-side guest-agent polling (`scripts/overwatch.sh`)

Add `log_boot_timing()` function near line 430 (alongside other diagnostics functions):
- Takes `$1` = epoch seconds when VM started
- Polls `guest-ping` every 2s up to 120s
- Logs `BOOT_TIMING guest agent responsive after Xs`

In `_do_start()`:
- Capture `VM_START_EPOCH=$(date +%s)` after `ensure_vm_running` succeeds (after line 880)
- Launch `log_boot_timing "$VM_START_EPOCH" &` alongside other background jobs (~line 889)
- Add `kill`/`wait` cleanup for the new PID in the cleanup block (lines 982-989)

### 2. Windows boot diagnostics in `log_guest_diagnostics()` (`scripts/overwatch.sh`)

Add section 6 before `PYEOF` at line 564 — query Event ID 100 from `Microsoft-Windows-Diagnostics-Performance/Operational`:
- `MainPathBootTime` (ms) — total kernel-measured boot duration
- `BootPostBootTime` (ms) — post-logon initialization time
- `BootDriverInitTime` (ms) — driver init time (AMD GPU bottleneck indicator)
- `BootIsDegradation` — Windows regression flag

Add `BOOT_DIAG` case to the section parser in `_do_start()` (~line 909) tagged with `BOOT_TIMING` prefix.

### 3. Timestamp log in start-synapse.ps1 (`scripts/setup-guest.sh`)

Update `synapse_script` string in `ensure_synapse_delayed()` (~line 662) to add:
- `Write-Timing` helper function: appends `yyyy-MM-dd HH:mm:ss.fff SYNAPSE <phase>` to `C:\ProgramData\overwatch\boot-timing.log`
- Explorer shell detection: poll `Get-Process explorer` with `MainWindowHandle -ne 0` up to 30s, log `shell-ready` timestamp
- Timestamp calls at each milestone: `script-start`, `first-launch`, `kill`, `relaunch`, `complete`

### 4. `boot-timing` subcommand (`scripts/setup-guest.sh`)

Add `show_boot_timing()` function that reads last 20 lines of guest `boot-timing.log` via `run_ps`. Add to header comments, usage text, dispatch case, and guest-agent-check pattern.

## Files to modify
- `scripts/overwatch.sh` — `log_boot_timing()` function, Event ID 100 query in `log_guest_diagnostics()`, `BOOT_DIAG` parser case, `VM_START_EPOCH` capture, background job launch + cleanup
- `scripts/setup-guest.sh` — updated `synapse_script` content with timing + shell detection, `show_boot_timing()` function, `boot-timing` subcommand wiring

## Verification
1. `bash -n` syntax check on both scripts
2. Deploy `overwatch.sh` via `setup-host.sh support`
3. Run `setup-guest.sh synapse` to push updated start-synapse.ps1 to guest
4. Stop and start the VM via systemd
5. Host-side: `sudo journalctl -u overwatch -b | grep BOOT_TIMING`
6. Guest-side: `sudo scripts/setup-guest.sh boot-timing`
7. Confirm boot-timing.log shows shell-ready and all SYNAPSE phase timestamps
