# Overwatch VM Project

GPU-passthrough Windows gaming VM on a Linux host (myhost).

## VM Lifecycle Rules

**ALWAYS use systemd for VM lifecycle management:**
- Start: `sudo systemctl start overwatch`
- Stop: `sudo systemctl stop overwatch`

**NEVER use these commands directly:**
- `virsh destroy overwatch` — yanks GPU mid-operation, corrupts GPU state
- `virsh reboot overwatch` — causes grey screen / TDR with GPU passthrough
- `virsh shutdown overwatch` — bypasses the overwatch.sh cleanup sequence
- `sudo overwatch start` — must go through systemd for proper lifecycle
- `virsh undefine --nvram overwatch` — destroys UEFI NVRAM (Secure Boot keys, boot entries). Only appropriate when intentionally rebuilding the VM from scratch (fresh Windows install). To update VM XML, use `virsh define <file>` which overwrites in place preserving NVRAM.

**Before modifying VM XML or NVRAM, back up the NVRAM file:**
`sudo cp /var/lib/libvirt/qemu/nvram/overwatch_VARS.fd /var/lib/libvirt/qemu/nvram/overwatch_VARS.fd.bak`

**There are no qcow2 disk snapshots or backups.** Destructive changes to the guest (driver removal, registry corruption, failed installs) cannot be rolled back. Take a qcow2 snapshot before risky guest operations:
`sudo virsh snapshot-create-as overwatch --name <label> --disk-only`

**Host and guest configurations must stay in sync.** Any change that could prevent the VM from booting normally (NVRAM, VM XML, boot-critical guest config) risks a host kernel panic — a failed boot leaves the GPU held via vfio with no functioning guest to release it. Before making changes that affect VM boot or runtime, verify both sides will remain compatible.

**When the guest appears frozen (black/grey screen, unresponsive peripherals):**
1. Wait 30-60 seconds — the AMD GPU driver initialization can take this long, especially after a previous forced stop. It often recovers on its own.
2. Check if the guest agent responds: `sudo virsh qemu-agent-command overwatch '{"execute":"guest-ping"}'`
3. If the agent responds, Windows is running — the display may just be slow to initialize. Wait longer.
4. Only if truly unrecoverable, use `sudo systemctl stop overwatch` — it handles destroy + GPU cleanup.
5. A host reboot is only needed if the host kernel panics (green screen). Do not preemptively reboot the host.

**After a forced stop**, the PCI remove+rescan in `_do_stop()` cleans GPU state. Check `sudo dmesg | grep -i amdgpu` for errors before starting the VM again.

## Guest Agent Commands

The guest agent runs as SYSTEM. Commands launched via `guest-exec` run in the SYSTEM session, NOT the interactive user session. This means:
- GUI applications launched via guest agent are invisible to the logged-in user
- Registry paths like `HKCU:` map to SYSTEM's hive, not the user's
- Use full SID paths for per-user registry: `HKU\S-1-5-21-XXXXXXXXXX-XXXXXXXXXX-XXXXXXXXXX-1000`

## Anti-Cheat (Ricochet)

Five detection vectors must remain addressed (see `overwatch.xml` and `steps.md` for details):
1. KVM hidden (`<kvm><hidden state='on'/>`)
2. Hyper-V vendor ID spoofed
3. CPU host-passthrough
4. SMBIOS strings (real motherboard)
5. GPU passthrough (real hardware)

**Windows Defender and Tamper Protection must ALWAYS remain ON.**

## Key Files

- `overwatch.xml` — VM definition (anti-cheat mitigations, GPU passthrough, SMBIOS)
- `scripts/overwatch.sh` — VM lifecycle (start/stop/GPU bind/unbind)
- `scripts/overwatch.service` — systemd unit for lifecycle management
- `steps.md` — Full setup procedure with verification commands
- `kb/troubleshooting.md` — Problem/cause/solution reference matrix
- `kb/debugging/` — Debugging methodology, case studies, checklists
