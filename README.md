# Overwatch VM

GPU-passthrough Windows 11 gaming VM on myhost. AMD RX 7900 XTX passed through to a Windows guest for Overwatch 2 with Ricochet anti-cheat.

The `cookbook/` directory contains the Cinc (Chef) cookbook that configures the host and deploys all scripts. See [`cookbook/README.md`](cookbook/README.md) for cookbook internals (templates, anti-cheat design, GRUB parameters, post-converge workflow).

## Install Cinc

[Cinc](https://cinc.sh) is an open-source distribution of Chef. Install it on the target host:

```bash
curl -L https://omnitruck.cinc.sh/install.sh | sudo bash
```

Verify:

```bash
cinc-client --version
cinc-solo --version
```

## Run the cookbook

The cookbook depends on `symmetra_core` and `libvirt` cookbooks from the [symmetra](https://github.com/pketienne/symmetra) repo. To converge:

```bash
# From the symmetra repo (has all dependency cookbooks)
cd ~/Projects/symmetra/master

# Run just the overwatch cookbook
sudo cinc-client -z -o 'recipe[overwatch::default]'
```

To uninstall:

```bash
sudo cinc-client -z -o 'recipe[overwatch::uninstall]'
```

To run compliance checks:

```bash
cinc-auditor exec cookbooks/overwatch/compliance/profiles/default
```

## VM lifecycle

**Always use systemd:**

```bash
sudo systemctl start overwatch
sudo systemctl stop overwatch
```

**Never use these directly:**

- `virsh destroy` — yanks GPU mid-operation, corrupts GPU state
- `virsh reboot` — causes grey screen / TDR with GPU passthrough
- `virsh shutdown` — bypasses cleanup sequence
- `sudo overwatch start` — must go through systemd
- `virsh undefine --nvram` — destroys UEFI NVRAM. To update XML, use `virsh define <file>`.

**Before modifying VM XML or NVRAM:**

```bash
sudo cp /var/lib/libvirt/qemu/nvram/overwatch_VARS.fd{,.bak}
```

**Before risky guest operations** (no qcow2 snapshots exist by default):

```bash
sudo virsh snapshot-create-as overwatch --name <label> --disk-only
```

Host and guest configs must stay in sync. A change that prevents the VM from booting risks a host kernel panic — a failed boot leaves the GPU held via vfio with no guest to release it.

## Frozen guest recovery

1. Wait 30-60s — AMD GPU driver init can take this long. It often recovers.
2. Check guest agent: `sudo virsh qemu-agent-command overwatch '{"execute":"guest-ping"}'`
3. If the agent responds, Windows is running — wait longer for the display.
4. Only if unrecoverable: `sudo systemctl stop overwatch`
5. Host reboot only needed on kernel panic (green screen).
6. After forced stop, check `sudo dmesg | grep -i amdgpu` before restarting.

## Guest agent

The agent runs as SYSTEM. Commands via `guest-exec` run in the SYSTEM session, not the interactive user session:

- GUI apps are invisible to the logged-in user
- `HKCU:` maps to SYSTEM's hive, not the user's
- Use `HKU\<SID>` for per-user registry access

Windows Defender and Tamper Protection must always remain on.

## Reference

- [`reference.md`](reference.md) — Known problems, debugging checklists, stress tests
- [`cookbook/README.md`](cookbook/README.md) — Cookbook design, templates, GRUB parameters
