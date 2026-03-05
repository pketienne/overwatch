# Overwatch VM

GPU-passthrough Windows gaming VM on a Linux host (myhost). AMD RX 7900 XTX passed through to a Windows 11 guest for Overwatch 2 with Ricochet anti-cheat.

## VM Lifecycle

**ALWAYS use systemd:**
- Start: `sudo systemctl start overwatch`
- Stop: `sudo systemctl stop overwatch`

**NEVER use these commands directly:**
- `virsh destroy overwatch` — yanks GPU mid-operation, corrupts GPU state
- `virsh reboot overwatch` — causes grey screen / TDR with GPU passthrough
- `virsh shutdown overwatch` — bypasses the overwatch.sh cleanup sequence
- `sudo overwatch start` — must go through systemd for proper lifecycle
- `virsh undefine --nvram overwatch` — destroys UEFI NVRAM (Secure Boot keys, boot entries). To update VM XML, use `virsh define <file>` which overwrites in place preserving NVRAM.

**Before modifying VM XML or NVRAM, back up the NVRAM file:**
`sudo cp /var/lib/libvirt/qemu/nvram/overwatch_VARS.fd /var/lib/libvirt/qemu/nvram/overwatch_VARS.fd.bak`

**There are no qcow2 disk snapshots or backups.** Take a snapshot before risky guest operations:
`sudo virsh snapshot-create-as overwatch --name <label> --disk-only`

**Host and guest configurations must stay in sync.** A change that prevents the VM from booting normally risks a host kernel panic — a failed boot leaves the GPU held via vfio with no functioning guest to release it.

**When the guest appears frozen (black/grey screen, unresponsive peripherals):**
1. Wait 30-60 seconds — AMD GPU driver initialization can take this long. It often recovers on its own.
2. Check if the guest agent responds: `sudo virsh qemu-agent-command overwatch '{"execute":"guest-ping"}'`
3. If the agent responds, Windows is running — the display may just be slow to initialize. Wait longer.
4. Only if truly unrecoverable, use `sudo systemctl stop overwatch` — it handles destroy + GPU cleanup.
5. A host reboot is only needed if the host kernel panics (green screen). Do not preemptively reboot the host.

**After a forced stop**, check `sudo dmesg | grep -i amdgpu` for errors before starting the VM again.

## Guest Agent

The guest agent runs as SYSTEM. Commands launched via `guest-exec` run in the SYSTEM session, NOT the interactive user session:
- GUI applications launched via guest agent are invisible to the logged-in user
- Registry paths like `HKCU:` map to SYSTEM's hive, not the user's
- Use full SID paths for per-user registry: `HKU\S-1-5-21-XXXXXXXXXX-XXXXXXXXXX-XXXXXXXXXX-1000`

## Anti-Cheat (Ricochet)

Five detection vectors must remain addressed (see cookbook VM XML template for details):
1. KVM hidden (`<kvm><hidden state='on'/>`)
2. Hyper-V vendor ID spoofed
3. CPU host-passthrough
4. SMBIOS strings (real motherboard)
5. GPU passthrough (real hardware)

**Windows Defender and Tamper Protection must ALWAYS remain ON.**

## Deployment

All deployable artifacts (scripts, VM XML, systemd units, guest configs) live in the
[overwatch cookbook](../symmetra/master/cookbooks/overwatch/) and are deployed via Chef converge.
This repo contains only documentation.

| Cookbook path | Deploys to | Purpose |
| --- | --- | --- |
| `templates/overwatch.sh.erb` | `/usr/local/bin/overwatch` | Lifecycle manager (GPU bind/unbind, start/stop) |
| `templates/overwatch.service.erb` | `/etc/systemd/system/overwatch.service` | systemd unit |
| `templates/overwatch-vm.xml.erb` | libvirt VM definition | Anti-cheat, GPU passthrough, SMBIOS |
| `templates/setup-guest.sh.erb` | `/usr/local/share/overwatch/setup-guest.sh` | Guest registry/config (run manually post-install) |
| `files/transition-throttle.ps1` | VM `C:\Scripts\` (via setup-guest.sh) | OW2 transition freeze mitigation |
| `files/autounattend.xml` | `/usr/local/share/overwatch/` | Unattended Windows install |

## Reference

- `reference.md` — Known problems, debugging checklists, stress tests
