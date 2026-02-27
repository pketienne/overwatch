#!/bin/bash
# setup-vm — Create and define the GPU passthrough VM
# Automates Phase 7 from tasks/gpu-passthrough/recipe/setup.md
# Requires: libvirt installed (setup-host.sh virt-stack)
#
# Subcommands:
#   all      Create disk and define VM
#   disk     Create the qcow2 disk image
#   define   Define the VM in libvirt (embeds full XML)
#   verify   Print VM configuration summary
#
# Usage: setup-vm [--dry-run] [--verbose] <subcommand>

set -uo pipefail

# --- Constants ---

VM_NAME="overwatch"
VM_DISK="/var/lib/libvirt/images/overwatch.qcow2"
VM_DISK_SIZE="200G"
VM_RAM_KIB="16777216"       # 16 GB
VM_VCPUS="7"
VM_MAC="52:54:00:67:c7:3e"

GPU="0000:03:00.0"
GPU_AUDIO="0000:03:00.1"
GPU_ROM="/usr/share/qemu/gpu-rom.bin"
VIRTIO_ISO="/home/myuser/Downloads/virtio-win.iso"

# USB devices: VID:PID:Name
USB_DEVICES=(
    "0x29ea:0x0102:Kinesis Advantage2"
    "0x1532:0x00a7:Razer Naga V2 Pro"
    "0x1532:0x022b:Razer Tartarus V2"
    "0x1532:0x0c05:Razer Strider Chroma"
    "0x1038:0x1290:SteelSeries Arctis Pro Wireless (1)"
    "0x1038:0x1294:SteelSeries Arctis Pro Wireless (2)"
)

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
    echo "Usage: setup-vm [--dry-run] [--verbose] <subcommand>"
    echo ""
    echo "  all      Create disk and define VM"
    echo "  disk     Create the qcow2 disk image"
    echo "  define   Define the VM in libvirt"
    echo "  verify   Print VM configuration summary"
    exit 1
fi

# --- Root check (not needed for verify) ---

if [ "$CMD" != "verify" ] && [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    log "ERROR: Must run as root (or use --dry-run to preview)"
    exit 1
fi

# --- Helpers ---

# Parse PCI address "0000:03:00.0" into hex components for XML
pci_domain() { echo "0x${1%%:*}"; }
pci_bus()    { local tmp="${1#*:}"; echo "0x${tmp%%:*}"; }
pci_slot()   { local tmp="${1#*:}"; tmp="${tmp#*:}"; echo "0x${tmp%%.*}"; }
pci_func()   { echo "0x${1##*.}"; }

# Generate USB hostdev XML fragments from USB_DEVICES array
generate_usb_hostdevs() {
    local entry vid pid name
    for entry in "${USB_DEVICES[@]}"; do
        vid="${entry%%:*}"
        local rest="${entry#*:}"
        pid="${rest%%:*}"
        name="${rest#*:}"
        cat <<EOF
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='$vid'/>
        <product id='$pid'/>
      </source>
    </hostdev>
EOF
    done
}

# ============================================================
# Phase 7.1: Create disk
# ============================================================

ensure_disk() {
    log "=== Phase 7.1: VM disk ==="

    if [ -f "$VM_DISK" ]; then
        local disk_size
        disk_size=$(qemu-img info --output=json "$VM_DISK" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('virtual-size',0))" 2>/dev/null) || true
        local disk_gb=$(( ${disk_size:-0} / 1073741824 ))
        log "  $VM_DISK already exists (${disk_gb}G virtual)"
        return 0
    fi

    local disk_dir
    disk_dir=$(dirname "$VM_DISK")
    if [ ! -d "$disk_dir" ]; then
        log "  ERROR: Directory $disk_dir does not exist"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] Would create $VM_DISK ($VM_DISK_SIZE)"
        return 0
    fi

    log "  Creating $VM_DISK ($VM_DISK_SIZE)..."
    qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"
    log "  Disk created"
}

# ============================================================
# Phase 7.2: Define VM
# ============================================================

ensure_vm_defined() {
    log "=== Phase 7.2: VM definition ==="

    # Check if already defined
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        log "  VM '$VM_NAME' already defined in libvirt"
        log "  To redefine, run: virsh undefine $VM_NAME"
        return 0
    fi

    # Parse GPU PCI addresses
    local gpu_domain gpu_bus gpu_slot gpu_func
    gpu_domain=$(pci_domain "$GPU")
    gpu_bus=$(pci_bus "$GPU")
    gpu_slot=$(pci_slot "$GPU")
    gpu_func=$(pci_func "$GPU")

    local audio_domain audio_bus audio_slot audio_func
    audio_domain=$(pci_domain "$GPU_AUDIO")
    audio_bus=$(pci_bus "$GPU_AUDIO")
    audio_slot=$(pci_slot "$GPU_AUDIO")
    audio_func=$(pci_func "$GPU_AUDIO")

    # Generate USB hostdev fragments
    local usb_xml
    usb_xml=$(generate_usb_hostdevs)

    # Optional: virtio-win CDROM
    local cdrom_xml=""
    if [ -f "$VIRTIO_ISO" ]; then
        cdrom_xml="    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$VIRTIO_ISO'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>"
        log "  Including VirtIO driver ISO: $VIRTIO_ISO"
    else
        log "  VirtIO ISO not found at $VIRTIO_ISO — skipping CDROM"
    fi

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] Would define VM '$VM_NAME' with:"
        log "    vCPUs: $VM_VCPUS (pinned 1-7, emulator on 0)"
        log "    RAM: $((VM_RAM_KIB / 1024))M"
        log "    Disk: $VM_DISK (VirtIO)"
        log "    GPU: $GPU (VFIO, ROM: $GPU_ROM)"
        log "    GPU audio: $GPU_AUDIO (VFIO)"
        log "    Network: bridged (MAC $VM_MAC)"
        log "    USB devices: ${#USB_DEVICES[@]}"
        return 0
    fi

    log "  Writing VM XML..."
    local xml_file
    xml_file=$(mktemp)

    cat > "$xml_file" <<EOF
<domain type='kvm'>
  <name>$VM_NAME</name>
  <memory unit='KiB'>$VM_RAM_KIB</memory>
  <currentMemory unit='KiB'>$VM_RAM_KIB</currentMemory>
  <vcpu placement='static'>$VM_VCPUS</vcpu>
  <iothreads>1</iothreads>
  <cputune>
    <vcpupin vcpu='0' cpuset='1'/>
    <vcpupin vcpu='1' cpuset='2'/>
    <vcpupin vcpu='2' cpuset='3'/>
    <vcpupin vcpu='3' cpuset='4'/>
    <vcpupin vcpu='4' cpuset='5'/>
    <vcpupin vcpu='5' cpuset='6'/>
    <vcpupin vcpu='6' cpuset='7'/>
    <emulatorpin cpuset='0'/>
    <iothreadpin iothread='1' cpuset='0'/>
  </cputune>
  <os firmware='efi'>
    <type arch='x86_64' machine='pc-q35-noble'>hvm</type>
    <firmware>
      <feature enabled='yes' name='enrolled-keys'/>
      <feature enabled='yes' name='secure-boot'/>
    </firmware>
    <loader readonly='yes' secure='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.ms.fd</loader>
    <nvram template='/usr/share/OVMF/OVMF_VARS_4M.ms.fd'>/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vendor_id state='on' value='AuthenticAMD'/>
    </hyperv>
    <kvm>
      <hidden state='on'/>
    </kvm>
    <vmport state='off'/>
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='off'>
    <topology sockets='1' dies='1' cores='$VM_VCPUS' threads='1'/>
    <cache mode='passthrough'/>
  </cpu>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$VM_DISK'/>
      <backingStore/>
      <target dev='vda' bus='virtio'/>
    </disk>
$cdrom_xml
    <controller type='usb' index='0' model='qemu-xhci' ports='15'/>
    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='sata' index='0'/>
    <controller type='virtio-serial' index='0'/>
    <interface type='network'>
      <mac address='$VM_MAC'/>
      <source network='bridged'/>
      <model type='virtio'/>
    </interface>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <input type='tablet' bus='usb'/>
    <input type='keyboard' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
    <audio id='1' type='none'/>
    <hostdev mode='subsystem' type='pci' managed='no'>
      <driver name='vfio'/>
      <source>
        <address domain='$gpu_domain' bus='$gpu_bus' slot='$gpu_slot' function='$gpu_func'/>
      </source>
      <rom bar='off' file='$GPU_ROM'/>
    </hostdev>
    <hostdev mode='subsystem' type='pci' managed='no'>
      <driver name='vfio'/>
      <source>
        <address domain='$audio_domain' bus='$audio_bus' slot='$audio_slot' function='$audio_func'/>
      </source>
    </hostdev>
$usb_xml
    <watchdog model='itco' action='reset'/>
    <memballoon model='none'/>
  </devices>
</domain>
EOF

    log "  Defining VM..."
    virsh define "$xml_file"
    rm -f "$xml_file"
    log "  VM '$VM_NAME' defined"
}

# ============================================================
# Verify VM definition
# ============================================================

verify_vm() {
    log "=== Verify: VM '$VM_NAME' ==="

    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        log "  ERROR: VM '$VM_NAME' not defined"
        return 1
    fi

    # dominfo
    log "  Domain info:"
    virsh dominfo "$VM_NAME" 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] && log "    $line"
    done

    # Key XML checks
    local xml
    xml=$(virsh dumpxml "$VM_NAME" 2>/dev/null) || { log "  ERROR: Could not dump XML"; return 1; }

    # vCPU pinning
    local vcpu_count
    vcpu_count=$(echo "$xml" | grep -c "vcpupin" 2>/dev/null) || true
    log "  vCPU pins: $vcpu_count"

    # Emulator pin
    if echo "$xml" | grep -q "emulatorpin"; then
        local emu_cpuset
        emu_cpuset=$(echo "$xml" | grep "emulatorpin" | sed "s/.*cpuset='\([^']*\)'.*/\1/")
        log "  Emulator pin: CPU $emu_cpuset"
    else
        log "  WARNING: No emulator pin configured"
    fi

    # IO thread pin
    if echo "$xml" | grep -q "iothreadpin"; then
        log "  IO thread: pinned"
    else
        log "  WARNING: No IO thread pin configured"
    fi

    # Disk
    local disk_file
    disk_file=$(echo "$xml" | grep "source file=.*qcow2" | sed "s/.*file='\([^']*\)'.*/\1/") || true
    if [ -n "$disk_file" ]; then
        if [ -f "$disk_file" ]; then
            log "  Disk: $disk_file (exists)"
        else
            log "  Disk: $disk_file (MISSING)"
        fi
    fi

    # GPU passthrough
    local pci_hostdevs
    pci_hostdevs=$(echo "$xml" | grep -c "type='pci' managed='no'" 2>/dev/null) || true
    log "  PCI hostdevs: $pci_hostdevs"

    # GPU ROM
    if echo "$xml" | grep -q "rom bar="; then
        local rom_file
        rom_file=$(echo "$xml" | grep "rom bar=" | sed "s/.*file='\([^']*\)'.*/\1/") || true
        if [ -n "$rom_file" ] && [ -f "$rom_file" ]; then
            log "  GPU ROM: $rom_file (exists)"
        elif [ -n "$rom_file" ]; then
            log "  GPU ROM: $rom_file (MISSING)"
        fi
    fi

    # USB devices
    local usb_hostdevs
    usb_hostdevs=$(echo "$xml" | grep -c "type='usb' managed='yes'" 2>/dev/null) || true
    log "  USB hostdevs: $usb_hostdevs"

    # Network
    local net
    net=$(echo "$xml" | grep "source network=" | sed "s/.*network='\([^']*\)'.*/\1/") || true
    log "  Network: ${net:-none}"

    # Guest agent channel
    if echo "$xml" | grep -q "org.qemu.guest_agent"; then
        log "  Guest agent: configured"
    else
        log "  WARNING: Guest agent channel not configured"
    fi

    # TPM
    if echo "$xml" | grep -q "tpm-crb"; then
        log "  TPM: tpm-crb (emulator)"
    else
        log "  WARNING: TPM not configured"
    fi

    # Anti-cheat features
    if echo "$xml" | grep -q "hidden state='on'"; then
        log "  KVM hidden: yes"
    else
        log "  WARNING: KVM hidden not set (anti-cheat may detect VM)"
    fi
    if echo "$xml" | grep -q "vendor_id"; then
        log "  Hyper-V vendor_id: spoofed"
    else
        log "  WARNING: Hyper-V vendor_id not set"
    fi

    log "  Verification complete"
}

# ============================================================
# Main dispatch
# ============================================================

do_all() {
    ensure_disk
    ensure_vm_defined
    verify_vm
    log "=== VM setup complete ==="
}

case "$CMD" in
    all)    do_all ;;
    disk)   ensure_disk ;;
    define) ensure_vm_defined ;;
    verify) verify_vm ;;
    *)
        log "ERROR: Unknown subcommand '$CMD'"
        exit 1
        ;;
esac
