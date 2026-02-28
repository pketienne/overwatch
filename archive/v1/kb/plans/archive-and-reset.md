# Plan: Archive v1 and Reset Myhost

## Context

Rebuilding the overwatch VM from scratch after NVRAM destruction. The existing project (scripts, docs, troubleshooting) is valuable reference material but should be archived so we can start clean. Myhost needs a full reset to validate the setup scripts end-to-end.

## Part 1: Archive repo contents

Move all existing project files into `archive/v1/`:

```
archive/v1/
  CLAUDE.md
  README.md
  backup/
  kb/
  scripts/
  tasks/
```

Keep at top level (unchanged):
- `.git/`, `.gitignore`, `.vscode/`

Create a minimal new top-level:
- `README.md` — one-liner pointing to `archive/v1/` for reference
- `CLAUDE.md` — copy from archive (lifecycle rules still apply)

## Part 2: Reset myhost (full cleanup)

Remove all overwatch-deployed files:

```bash
# Support files
sudo rm /usr/local/bin/overwatch
sudo rm /etc/systemd/system/overwatch.service
sudo systemctl daemon-reload
sudo rm /etc/udev/rules.d/99-gpu-passthrough.rules
sudo rm /etc/modprobe.d/amdgpu.conf
sudo rm /etc/modules-load.d/vfio-pci.conf
sudo rm /etc/libvirt/hooks/qemu

# GPU ROM and VM disks
sudo rm /usr/share/qemu/gpu-rom.bin
sudo rm /var/lib/libvirt/images/overwatch.qcow2
sudo rm /var/lib/libvirt/images/overwatch-backup.qcow2
sudo rm /var/lib/libvirt/images/win11-lconnect.qcow2
mv ~/overwatch-backup.qcow2 ~/overwatch-app.qcow2

# GRUB — remove amd_iommu=on, clear empty IVRS line
sudo sed -i 's/ amd_iommu=on//' /etc/default/grub
sudo sed -i '/^GRUB_EARLY_INITRD_LINUX_CUSTOM=""/d' /etc/default/grub
sudo update-grub

# Bridge — remove netplan bridge config, restore direct DHCP
# (must be done carefully to avoid dropping SSH)
# Restore simple config: enp9s0 with dhcp4
sudo netplan apply

# Libvirt bridged network (already not defined, but check)
sudo virsh net-destroy bridged 2>/dev/null
sudo virsh net-undefine bridged 2>/dev/null

# Remove virt packages
sudo apt remove --purge qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst virt-manager ovmf swtpm swtpm-tools bridge-utils
sudo apt autoremove
```

**Risk: SSH drop** — removing the bridge and changing netplan while connected over SSH will briefly drop the connection. The `netplan apply` should bring enp9s0 back up with DHCP, reconnecting within seconds. If it doesn't, physical access to myhost is needed.

## Part 3: Sync repo to myhost

After archival commit, pull on myhost so both machines have the archived structure.

## Verification

- `ssh myhost` — still reachable after bridge removal
- No overwatch files remain: check all paths above return "not found"
- `dmesg | grep iommu` — should show no IOMMU (removed from GRUB)
- Repo on both machines shows `archive/v1/` with all old files
