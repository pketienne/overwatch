# Plan: Deferred Tartarus attach (eliminate Synapse kill/restart)

## Context
We confirmed that Synapse applies Tartarus profiles immediately on USB hot-plug. This means we can remove the Tartarus from the VM XML (so it's not present at boot), and attach it at runtime after Synapse is already running. This eliminates the 30s+5s kill/restart cycle from start-synapse.ps1 — saving ~35s off the boot-to-usable timeline.

Only the Tartarus needs this treatment. All other devices work fine attached at boot.

## Changes

### 1. Remove Tartarus from VM XML (`scripts/setup-vm.sh`)

Remove the Tartarus line from the `USB_DEVICES` array (line 47):
```
- "0x1532:0x022b:Razer Tartarus V2"
```

After this change, `setup-vm.sh` must be re-run to regenerate the VM XML.

### 2. Add deferred Tartarus attach (`scripts/overwatch.sh`)

Add `attach_tartarus_deferred()` function near the other background job functions (~line 429). This function:
- Polls for guest agent (reuse pattern from `log_boot_timing`)
- Polls for `RazerAppEngine` process via guest agent (up to 120s)
- Once Synapse is detected, waits 5s for it to finish initializing
- Runs `virsh attach-device` with the Tartarus USB XML
- Logs `BOOT_TIMING tartarus attached after Xs`

In `_do_start()`:
- Launch `attach_tartarus_deferred "$VM_START_EPOCH" &` alongside other background jobs
- Add kill/wait cleanup for its PID

### 3. Simplify start-synapse.ps1 (`scripts/setup-guest.sh`)

Update `synapse_script` in `ensure_synapse_delayed()` — remove the kill/restart cycle. The script becomes:
- `Write-Timing "script-start"`
- Wait for explorer shell (keep existing poll)
- `Write-Timing "shell-ready"`
- Launch Synapse once
- `Write-Timing "complete"`

No more `Start-Sleep -Seconds 30`, no more `Stop-Process`, no more relaunch.

Update the section comment from "prevents windows + ensures Tartarus detection" to reflect that Tartarus is now handled by host-side deferred attach.

## Files to modify
- `scripts/setup-vm.sh` — remove Tartarus from USB_DEVICES array
- `scripts/overwatch.sh` — add `attach_tartarus_deferred()`, wire into `_do_start()` background jobs + cleanup
- `scripts/setup-guest.sh` — simplify `synapse_script` (remove kill/restart cycle)

## Verification
1. `bash -n` syntax check on all three scripts
2. Re-run `setup-vm.sh` to regenerate VM XML without Tartarus
3. Deploy `overwatch.sh` via `setup-host.sh support`
4. Push updated synapse script via `setup-guest.sh synapse`
5. Cycle the VM (`systemctl stop/start overwatch`)
6. Check `journalctl -u overwatch -b | grep BOOT_TIMING` — should show tartarus attach timing
7. Check `setup-guest.sh boot-timing` — should show simplified synapse phases (no kill/relaunch)
8. Verify Tartarus profile is applied (keybindings/lighting work)
