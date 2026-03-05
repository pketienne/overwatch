# Overwatch VM

GPU-passthrough Windows gaming VM on a Linux host (myhost). AMD RX 7900 XTX passed through to a Windows 11 guest for Overwatch 2 with Ricochet anti-cheat.

## Deployment

All deployable artifacts (scripts, VM XML, systemd units, guest configs) live in the
[overwatch cookbook](../symmetra/master/cookbooks/overwatch/) and are deployed via Chef converge.
This repo contains only documentation and knowledge base.

Key cookbook files:

| Cookbook path | Deploys to | Purpose |
|---|---|---|
| `templates/overwatch.sh.erb` | `/usr/local/bin/overwatch` | Lifecycle manager (GPU bind/unbind, start/stop) |
| `templates/overwatch.service.erb` | `/etc/systemd/system/overwatch.service` | systemd unit |
| `templates/overwatch-vm.xml.erb` | libvirt VM definition | Anti-cheat, GPU passthrough, SMBIOS |
| `templates/setup-guest.sh.erb` | `/usr/local/share/overwatch/setup-guest.sh` | Guest registry/config (run manually post-install) |
| `files/transition-throttle.ps1` | VM `C:\Scripts\` (via setup-guest.sh) | OW2 transition freeze mitigation |
| `files/autounattend.xml` | `/usr/local/share/overwatch/` | Unattended Windows install |

## Documentation

- `kb/troubleshooting.md` — Problem/cause/solution matrix, debugging checklists, stress tests
