# Plan: V2 Lifecycle Script

## Context

The VM currently requires a host reboot after every shutdown because the GPU is statically bound to vfio-pci at boot and enters a bad PCI state (header type '127') after VM shutdown. The v1 project solved this with a lifecycle script that dynamically swaps the GPU between amdgpu (host) and vfio-pci (VM). We need to port the proven patterns from v1 into a clean v2 script and switch myhost from static to dynamic GPU binding.

## Files to Create

| File | Install Location | Purpose |
|------|-----------------|---------|
| `scripts/overwatch.sh` | `/usr/local/bin/overwatch` | Lifecycle script (~340 lines) |
| `scripts/overwatch.service` | `/etc/systemd/system/overwatch.service` | Systemd unit |

## Script Design

### Constants
```
GPU=0000:03:00.0, GPU_AUDIO=0000:03:00.1, IGPU=0000:74:00.0
HOST_CPUS=0-1 (2 cores), VM gets cores 2-7 (6 cores, matches XML)
SHUTDOWN_SIGNAL_PORT=9147, LOCK_FILE=/run/overwatch.lock
```

### Start sequence (`systemctl start overwatch`)
1. Acquire lock (flock)
2. Stop services: GDM, ollama, openrgb (docker stays)
3. Release device FDs: `fuser -k /dev/dri/*, /dev/i2c-*`
4. Unbind VT consoles
5. **Suspend framebuffer** then unbind amdgpu + snd_hda_intel
6. Set driver_override=vfio-pci, bind, **SBR** (clean handoff)
7. `virsh start overwatch` (abort → _do_stop on failure)
8. Blank iGPU (monitor switches to dGPU)
9. CPU isolation: confine host to cores 0-1, performance governor, pin IRQs
10. Start UDP shutdown listener (background)
11. Poll `virsh domstate` every 2s until VM stops
12. Call _do_stop

### Stop sequence (`systemctl stop overwatch` or after VM shutdown)
1. Graceful `virsh shutdown` (60s timeout, then `virsh destroy`)
2. Restore CPU defaults (powersave, all cores, irqbalance)
3. Unbind vfio-pci, clear driver_override
4. **Unblank iGPU** (user gets display back FIRST)
5. **Restart services** (GDM on iGPU — user has desktop)
6. GPU rebind LAST (non-fatal):
   - Primary: PCI remove+rescan, wait 15s for amdgpu auto-bind
   - Fallback: SBR + bind with 30s timeout kill
7. Disable GPU runtime PM (`power/control=on`)

### Key patterns from v1 (proven, copy directly)
- **Framebuffer suspend** before amdgpu unbind — prevents drm_fb_helper deadlock (~1.5%)
- **PCI remove+rescan** as primary rebind — avoids 4-min SR-IOV VF mailbox block
- **gpu_bind_with_timeout** — background bind with kill after 30s for stuck kernel calls
- **SBR + setpci poll** — only reset method for RDNA3 (no FLR)
- **Non-fatal GPU rebind** — iGPU + services restored before attempting rebind
- **Lock file** with flock, SIGTERM trap, ERR trap, idempotent ensure_* functions

### Dropped from v1 (add later if needed)
- Host/guest perf monitoring, boot timing, guest diagnostics
- Deferred Tartarus USB attach (now in XML)
- QEMU PID tracking in wait loop
- Shutdown timestamp tracking

## Systemd Service

```ini
[Unit]
Description=Overwatch VM lifecycle (GPU passthrough)
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/overwatch start
TimeoutStartSec=infinity
TimeoutStopSec=120
KillMode=mixed
Restart=no

[Install]
WantedBy=multi-user.target
```

## Migration: Static → Dynamic Binding

### Phase A: Install script (while still on static vfio-pci)
1. Write `scripts/overwatch.sh` and `scripts/overwatch.service`
2. Install to myhost, `systemctl daemon-reload`
3. Test start/stop cycle (GPU already on vfio-pci, script skips driver swap)

### Phase B: Switch to dynamic binding
4. Remove static binding files:
   - `sudo rm /etc/modprobe.d/vfio.conf`
   - `sudo rm /etc/modules-load.d/vfio-pci.conf`
5. Create `echo "options amdgpu runpm=0" | sudo tee /etc/modprobe.d/amdgpu.conf`
6. Install udev seat rule (prevent GDM on dGPU):
   - `/etc/udev/rules.d/99-gpu-passthrough.rules`
   - `ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}=="pci-0000:03:00.0", ENV{ID_SEAT}=""`
7. `sudo update-initramfs -u && sudo reboot`

### Phase C: Verify
8. Confirm dGPU boots on amdgpu: `lspci -nnk -s 03:00.0`
9. Test full lifecycle: `sudo systemctl start overwatch` → use VM → `sudo systemctl stop overwatch`
10. Confirm GPU returns to amdgpu after stop

## Verification

```bash
# After start
lspci -nnk -s 03:00.0 | grep "driver in use"  # vfio-pci
sudo virsh domstate overwatch                    # running

# After stop
lspci -nnk -s 03:00.0 | grep "driver in use"  # amdgpu
sudo virsh domstate overwatch                    # shut off
systemctl is-active gdm ollama openrgb           # active
journalctl -u overwatch --no-pager -n 50         # check for errors
```

## Reference Files
- `archive/v1/scripts/overwatch.sh` — source of all proven patterns
- `archive/v1/scripts/overwatch.service` — systemd unit template
- `archive/v1/kb/plans/fix-gpu-rebind.md` — PCI remove+rescan discovery
