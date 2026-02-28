#!/bin/bash
# setup-host — One-time host infrastructure setup for GPU passthrough VM
# Automates Phases 2-8 from tasks/gpu-passthrough/recipe/setup.md
# Phase 1 (BIOS) remains manual.
#
# Subcommands:
#   all        Run all setup steps in order
#   prereqs    Verify IOMMU, kernel modules, IOMMU groups
#   virt-stack Install virtualization packages, add user to groups
#   grub       Configure GRUB for IOMMU
#   network    Configure netplan bridge and libvirt bridged network
#   gpu-rom    Verify GPU ROM file exists
#   support    Install overwatch script, service, udev, modprobe, modules-load, monitors, hook
#   sudoers    Create passwordless sudo for overwatch service control
#   desktop    Install desktop shortcut
#
# Usage: setup-host [--dry-run] [--verbose] <subcommand>

set -uo pipefail

# --- Constants ---

GPU="0000:03:00.0"
BRIDGE_IF="br0"
PHYS_IF="enp9s0"
GPU_ROM="/usr/share/qemu/gpu-rom.bin"
TARGET_USER="myuser"

VIRT_PACKAGES=(
    qemu-kvm libvirt-daemon-system libvirt-clients
    virtinst virt-manager ovmf swtpm swtpm-tools
    bridge-utils irqbalance
)

# Repo paths (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse arguments ---

DRY_RUN=false
VERBOSE=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
    esac
    shift
done
CMD="${1:-}"

# --- Logging ---

log() { echo "$(date '+%H:%M:%S') $*"; }

on_error() {
    local lineno=$1 cmd=$2 rc=$3
    log "ERROR: command failed at line $lineno: '$cmd' (exit code $rc)"
}
trap 'on_error $LINENO "$BASH_COMMAND" $?' ERR

if [ "$VERBOSE" = true ]; then
    export PS4='+${BASH_SOURCE}:${LINENO}: '
    set -x
    log "Verbose mode enabled"
fi

# --- Usage ---

if [ -z "$CMD" ]; then
    echo "Usage: setup-host [--dry-run] [--verbose] <subcommand>"
    echo ""
    echo "  all        Run all setup steps in order"
    echo "  prereqs    Verify IOMMU, kernel modules, IOMMU groups"
    echo "  virt-stack Install virtualization packages, add user to groups"
    echo "  grub       Configure GRUB for IOMMU"
    echo "  network    Configure netplan bridge and libvirt bridged network"
    echo "  gpu-rom    Verify GPU ROM file exists"
    echo "  support    Install overwatch script, service, udev, modprobe, etc."
    echo "  sudoers    Create passwordless sudo for overwatch service control"
    echo "  desktop    Install desktop shortcut"
    exit 1
fi

# --- Root check ---

if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    log "ERROR: Must run as root (or use --dry-run to preview)"
    exit 1
fi

# --- Helpers ---

# Install file from repo to system path, only if content differs.
# Usage: install_file <src> <dst> <mode>
install_file() {
    local src="$1" dst="$2" mode="$3"
    if [ ! -f "$src" ]; then
        log "ERROR: Source file not found: $src"
        return 1
    fi
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        log "  $dst already up to date"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] Would install $src -> $dst (mode $mode)"
        return 0
    fi
    cp "$src" "$dst"
    chmod "$mode" "$dst"
    log "  Installed $dst"
}

# Install content string to system path, only if content differs.
# Usage: install_content <dst> <mode> <<'EOF' ... EOF
install_content() {
    local dst="$1" mode="$2"
    local content
    content=$(cat)
    if [ -f "$dst" ] && [ "$(cat "$dst")" = "$content" ]; then
        log "  $dst already up to date"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] Would write $dst (mode $mode)"
        return 0
    fi
    local dst_dir
    dst_dir=$(dirname "$dst")
    [ -d "$dst_dir" ] || mkdir -p "$dst_dir"
    echo "$content" > "$dst"
    chmod "$mode" "$dst"
    log "  Installed $dst"
}

# ============================================================
# Phase 2: Prerequisites — verify IOMMU, kernel modules
# ============================================================

ensure_prereqs() {
    log "=== Phase 2: Checking prerequisites ==="
    local ok=true

    # IOMMU enabled in kernel
    if dmesg | grep -qi "AMD-Vi: AMD IOMMUv2"; then
        log "  IOMMU: enabled (AMD-Vi detected)"
    elif [ -d /sys/class/iommu ]; then
        log "  IOMMU: enabled (sysfs present)"
    else
        log "  ERROR: IOMMU not detected — enable in BIOS (Phase 1)"
        ok=false
    fi

    # Required kernel modules
    local mod
    for mod in vfio vfio_pci vfio_iommu_type1 kvm kvm_amd; do
        if modprobe -n "$mod" 2>/dev/null; then
            log "  Module $mod: available"
        else
            log "  ERROR: Module $mod not available"
            ok=false
        fi
    done

    # IOMMU groups — GPU should be in its own group
    local gpu_group_dir="/sys/bus/pci/devices/$GPU/iommu_group/devices"
    if [ -d "$gpu_group_dir" ]; then
        local group_devs
        group_devs=$(ls "$gpu_group_dir" 2>/dev/null | wc -l)
        log "  GPU IOMMU group: $group_devs device(s)"
        if [ "$group_devs" -gt 2 ]; then
            log "  WARNING: GPU IOMMU group has $group_devs devices (expected 2: GPU + audio)"
        fi
    else
        log "  WARNING: GPU IOMMU group not found (reboot after enabling IOMMU?)"
    fi

    if [ "$ok" = false ]; then
        log "Prerequisites check failed — fix errors above before continuing"
        return 1
    fi
    log "Prerequisites OK"
}

# ============================================================
# Phase 2: Virtualization stack
# ============================================================

ensure_virt_stack() {
    log "=== Phase 2: Virtualization stack ==="

    # Check which packages are missing
    local missing=()
    local pkg
    for pkg in "${VIRT_PACKAGES[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log "  All virtualization packages already installed"
    else
        log "  Missing packages: ${missing[*]}"
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would install: ${missing[*]}"
        else
            apt-get install -y "${missing[@]}"
            log "  Packages installed"
        fi
    fi

    # Add user to groups
    local grp
    for grp in libvirt kvm; do
        if id -nG "$TARGET_USER" 2>/dev/null | grep -qw "$grp"; then
            log "  $TARGET_USER already in group $grp"
        else
            if [ "$DRY_RUN" = true ]; then
                log "  [dry-run] Would add $TARGET_USER to group $grp"
            else
                usermod -aG "$grp" "$TARGET_USER"
                log "  Added $TARGET_USER to group $grp"
            fi
        fi
    done

    # Validate
    if [ "$DRY_RUN" = false ]; then
        log "  Running virt-host-validate..."
        virt-host-validate qemu 2>&1 | while IFS= read -r line; do
            log "    $line"
        done || true
    fi
}

# ============================================================
# Phase 3: GRUB configuration
# ============================================================

ensure_grub_config() {
    log "=== Phase 3: GRUB configuration ==="
    local grub_file="/etc/default/grub"
    local changed=false

    if [ ! -f "$grub_file" ]; then
        log "  ERROR: $grub_file not found"
        return 1
    fi

    # Check GRUB_CMDLINE_LINUX_DEFAULT for amd_iommu=on
    local current_cmdline
    current_cmdline=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_file" 2>/dev/null | head -1) || true
    if echo "$current_cmdline" | grep -q "amd_iommu=on"; then
        log "  GRUB_CMDLINE_LINUX_DEFAULT already contains amd_iommu=on"
    else
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would add amd_iommu=on to GRUB_CMDLINE_LINUX_DEFAULT"
        else
            # Add amd_iommu=on to existing value
            if [ -n "$current_cmdline" ]; then
                local new_val
                new_val=$(echo "$current_cmdline" | sed 's/"$/ amd_iommu=on"/')
                sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$new_val|" "$grub_file"
            else
                echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on"' >> "$grub_file"
            fi
            log "  Added amd_iommu=on to GRUB_CMDLINE_LINUX_DEFAULT"
            changed=true
        fi
    fi

    if [ "$changed" = true ]; then
        log "  Running update-grub..."
        update-grub 2>&1 | while IFS= read -r line; do
            log "    $line"
        done
        log "  GRUB updated (reboot required for changes to take effect)"
    else
        log "  GRUB already configured"
    fi
}

# ============================================================
# Phase 4: Network bridge
# ============================================================

ensure_network() {
    log "=== Phase 4: Network bridge ==="

    # Detect existing netplan config file
    local netplan_file=""
    local f
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        if [ -f "$f" ]; then
            netplan_file="$f"
            break
        fi
    done

    if [ -z "$netplan_file" ]; then
        netplan_file="/etc/netplan/01-bridge.yaml"
        log "  No existing netplan config found, will create $netplan_file"
    else
        log "  Found existing netplan config: $netplan_file"
    fi

    # Check if bridge already configured
    if grep -q "$BRIDGE_IF" "$netplan_file" 2>/dev/null; then
        log "  Bridge $BRIDGE_IF already in netplan config"
    else
        local bridge_config
        bridge_config=$(cat <<'NETPLAN'
network:
  version: 2
  ethernets:
    enp9s0:
      dhcp4: false
  bridges:
    br0:
      interfaces: [enp9s0]
      dhcp4: true
NETPLAN
)
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would write bridge config to $netplan_file"
        else
            echo "$bridge_config" > "$netplan_file"
            chmod 600 "$netplan_file"
            log "  Wrote bridge config to $netplan_file"
            log "  WARNING: Run 'netplan apply' manually — applying now could drop your SSH session"
        fi
    fi

    # Libvirt bridged network
    if virsh net-info bridged &>/dev/null; then
        log "  Libvirt network 'bridged' already exists"
    else
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would define libvirt network 'bridged'"
        else
            local net_xml
            net_xml=$(mktemp)
            cat > "$net_xml" <<'EOF'
<network>
  <name>bridged</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF
            virsh net-define "$net_xml"
            rm -f "$net_xml"
            log "  Defined libvirt network 'bridged'"
        fi
    fi

    # Autostart
    if virsh net-info bridged 2>/dev/null | grep -q "Autostart:.*yes"; then
        log "  Libvirt network 'bridged' autostart already enabled"
    else
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would enable autostart for libvirt network 'bridged'"
        else
            virsh net-autostart bridged 2>/dev/null || true
            log "  Enabled autostart for libvirt network 'bridged'"
        fi
    fi

    # Start if not active
    if virsh net-info bridged 2>/dev/null | grep -q "Active:.*yes"; then
        log "  Libvirt network 'bridged' already active"
    else
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would start libvirt network 'bridged'"
        else
            virsh net-start bridged 2>/dev/null || true
            log "  Started libvirt network 'bridged'"
        fi
    fi
}

# ============================================================
# Phase 5: GPU ROM verification
# ============================================================

ensure_gpu_rom() {
    log "=== Phase 5: GPU ROM ==="

    if [ -f "$GPU_ROM" ]; then
        local rom_size
        rom_size=$(stat -c%s "$GPU_ROM" 2>/dev/null) || true
        log "  $GPU_ROM exists (${rom_size} bytes)"
        if [ "${rom_size:-0}" -lt 100000 ]; then
            log "  WARNING: ROM file seems too small — verify it's a valid VBIOS"
        fi
    else
        log "  ERROR: $GPU_ROM not found"
        log "  Download the VBIOS from TechPowerUp VGA BIOS Collection:"
        log "    Search for Sapphire NITRO+ RX 7900 XTX Vapor-X (subsystem 1DA2:E471)"
        log "    Then: sudo cp <downloaded>.rom $GPU_ROM"
        return 1
    fi
}

# ============================================================
# Phase 6: Support files
# ============================================================

ensure_support_files() {
    log "=== Phase 6: Support files ==="

    # 6.1 overwatch lifecycle script
    log "  Installing overwatch script..."
    install_file "$SCRIPT_DIR/overwatch.sh" /usr/local/bin/overwatch 755

    # 6.2 systemd service
    log "  Installing systemd service..."
    install_file "$SCRIPT_DIR/overwatch.service" /etc/systemd/system/overwatch.service 644
    if [ "$DRY_RUN" = false ]; then
        systemctl daemon-reload
    fi

    # 6.3 udev rules — seat prevention
    log "  Installing udev rules..."
    install_content /etc/udev/rules.d/99-gpu-passthrough.rules 644 <<'EOF'
# Prevent the 7900 XTX from being assigned to any seat.
# This stops GDM from spawning a greeter on it.
# The render node remains available for compute (ollama).
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{ID_PATH}=="pci-0000:03:00.0", ENV{ID_SEAT}=""
EOF

    # 6.4 amdgpu modprobe config
    log "  Installing amdgpu modprobe config..."
    install_content /etc/modprobe.d/amdgpu.conf 644 <<'EOF'
options amdgpu runpm=0
EOF

    # 6.5 modules-load for vfio-pci
    log "  Installing vfio-pci modules-load..."
    install_content /etc/modules-load.d/vfio-pci.conf 644 <<'EOF'
vfio-pci
EOF

    # 6.6 GDM monitors.xml
    log "  Installing GDM monitors.xml..."
    local user_monitors="/home/$TARGET_USER/.config/monitors.xml"
    local gdm_monitors="/var/lib/gdm3/.config/monitors.xml"
    if [ -f "$user_monitors" ]; then
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] Would copy $user_monitors -> $gdm_monitors"
        else
            mkdir -p "$(dirname "$gdm_monitors")"
            cp "$user_monitors" "$gdm_monitors"
            chown gdm:gdm "$gdm_monitors"
            log "  Copied monitors.xml to GDM config"
        fi
    else
        log "  WARNING: $user_monitors not found — configure displays first, then re-run"
    fi

    # 6.7 libvirt hooks (no-op)
    log "  Installing libvirt hook..."
    install_content /etc/libvirt/hooks/qemu 755 <<'EOF'
#!/bin/bash
exit 0
EOF
}

# ============================================================
# Phase 6.8: Sudoers
# ============================================================

ensure_sudoers() {
    log "=== Phase 6.8: Sudoers ==="
    local sudoers_file="/etc/sudoers.d/overwatch"
    local expected="$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start overwatch, /usr/bin/systemctl stop overwatch"

    if [ -f "$sudoers_file" ] && grep -qF "$expected" "$sudoers_file"; then
        log "  $sudoers_file already configured"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] Would create $sudoers_file"
        return 0
    fi

    echo "$expected" > "$sudoers_file"
    chmod 440 "$sudoers_file"

    # Validate
    if visudo -cf "$sudoers_file" &>/dev/null; then
        log "  Installed $sudoers_file (validated)"
    else
        log "  ERROR: sudoers validation failed — removing broken file"
        rm -f "$sudoers_file"
        return 1
    fi
}

# ============================================================
# Phase 8: Desktop shortcut
# ============================================================

ensure_desktop_shortcut() {
    log "=== Phase 8: Desktop shortcut ==="
    local desktop_dir="/home/$TARGET_USER/Desktop"
    local dst="$desktop_dir/overwatch.desktop"

    if [ ! -d "$desktop_dir" ]; then
        log "  WARNING: $desktop_dir does not exist — skipping"
        return 0
    fi

    install_file "$SCRIPT_DIR/overwatch.desktop" "$dst" 755
    if [ "$DRY_RUN" = false ] && [ -f "$dst" ]; then
        chown "$TARGET_USER:$TARGET_USER" "$dst"
    fi
}

# ============================================================
# Main dispatch
# ============================================================

do_all() {
    ensure_prereqs
    ensure_virt_stack
    ensure_grub_config
    ensure_network
    ensure_gpu_rom
    ensure_support_files
    ensure_sudoers
    ensure_desktop_shortcut
    log "=== Host setup complete ==="
}

case "$CMD" in
    all)        do_all ;;
    prereqs)    ensure_prereqs ;;
    virt-stack) ensure_virt_stack ;;
    grub)       ensure_grub_config ;;
    network)    ensure_network ;;
    gpu-rom)    ensure_gpu_rom ;;
    support)    ensure_support_files ;;
    sudoers)    ensure_sudoers ;;
    desktop)    ensure_desktop_shortcut ;;
    *)
        log "ERROR: Unknown subcommand '$CMD'"
        exit 1
        ;;
esac
