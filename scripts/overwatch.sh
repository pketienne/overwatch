#!/bin/bash
# overwatch — GPU passthrough VM lifecycle manager (v2)
#
# Manages myhost through: host-mode ↔ vfio ↔ vm-running
#
# Subcommands:
#   start   Full lifecycle: prepare host → start VM → wait for shutdown → restore host
#   stop    Inspect current state, do minimum work to reach host-mode (idempotent)
#   status  Print current system state across all dimensions
#
# Runs as a systemd service: systemctl start overwatch
# Log: journalctl -u overwatch
#
# Usage: overwatch [--verbose] start|stop|status

set -uo pipefail

GPU="0000:03:00.0"
GPU_AUDIO="0000:03:00.1"
IGPU="0000:74:00.0"
HOST_CPUS="0-1"     # CPUs reserved for host tasks + QEMU emulator/IO
SHUTDOWN_SIGNAL_PORT=9147   # UDP port for Windows shutdown signal
LOCK_FILE="/run/overwatch.lock"

# --- Parse arguments ---

VERBOSE=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --verbose) VERBOSE=true ;;
    esac
    shift
done
CMD="${1:-}"

# --- Helpers (needed by status, defined before logging) ---

gpu_driver() {
    local link
    link=$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null) || true
    if [ -n "$link" ]; then
        basename "$link"
    else
        echo "unbound"
    fi
}

# PCIe Secondary Bus Reset + readiness poll via setpci.
# RX 7900 XTX only supports SBR (no FLR); resets both 03:00.0 and 03:00.1.
gpu_bus_reset() {
    local label="${1:-PCIe bus reset}"
    log "Resetting GPU ($label)..."
    echo 1 > "/sys/bus/pci/devices/$GPU/reset" 2>/dev/null || true
    local i vendor
    for i in $(seq 1 20); do
        vendor=$(setpci -s "$GPU" VENDOR_ID 2>/dev/null) || true
        if [ "$vendor" = "1002" ]; then
            log "Bus reset complete (device ready after ${i}00ms)"
            return 0
        fi
        sleep 0.1
    done
    log "WARNING: GPU not responding after bus reset"
    return 1
}

# PCI remove + rescan: gives amdgpu a completely fresh device, avoiding stale
# SR-IOV VF mailbox state that causes probe() to block for ~4 minutes.
# Drivers auto-bind via modalias since driver_override was already cleared.
gpu_pci_remove_rescan() {
    log "Removing GPU from PCI bus and rescanning..."
    echo 1 > "/sys/bus/pci/devices/$GPU/remove" 2>/dev/null || true
    echo 1 > "/sys/bus/pci/devices/$GPU_AUDIO/remove" 2>/dev/null || true
    sleep 1
    echo 1 > /sys/bus/pci/rescan
    local i drv
    for i in $(seq 1 15); do
        drv=$(gpu_driver "$GPU")
        if [ "$drv" = "amdgpu" ]; then
            log "PCI rescan: amdgpu auto-bound after ${i}s"
            return 0
        fi
        sleep 1
    done
    log "PCI rescan: amdgpu did not auto-bind within 15s (driver=$(gpu_driver "$GPU"))"
    return 1
}

# Bind GPU to amdgpu with a timeout. The bind call can block in kernel space
# (SR-IOV VF mailbox loop) for ~4 minutes; this wrapper kills it after $1 seconds.
gpu_bind_with_timeout() {
    local timeout=${1:-30}
    log "Binding to amdgpu (timeout=${timeout}s)..."
    ( echo "$GPU" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null ) &
    local bind_pid=$!
    local i
    for i in $(seq 1 "$timeout"); do
        if ! kill -0 "$bind_pid" 2>/dev/null; then
            wait "$bind_pid" 2>/dev/null
            log "amdgpu bind completed in ${i}s"
            return 0
        fi
        sleep 1
    done
    log "WARNING: amdgpu bind still blocked after ${timeout}s — killing"
    kill "$bind_pid" 2>/dev/null || true
    wait "$bind_pid" 2>/dev/null || true
    return 1
}

# Find the iGPU framebuffer by PCI device path (not hardcoded fb number)
igpu_fb() {
    for fb in /sys/class/graphics/fb*/; do
        if [ "$(readlink -f "$fb/device" 2>/dev/null)" = "/sys/devices/pci0000:00/$IGPU" ] || \
           readlink -f "$fb/device" 2>/dev/null | grep -q "$IGPU"; then
            echo "$fb"
            return 0
        fi
    done
    return 1
}

# ============================================================
# status — print current system state (no side effects)
# ============================================================

do_status() {
    local gpu_drv audio_drv vm_state gpu_power
    local fb blank_val igpu_state
    local gdm_state ollama_state openrgb_state
    local gov irqbalance_state
    local state

    gpu_drv=$(gpu_driver "$GPU")
    audio_drv=$(gpu_driver "$GPU_AUDIO")
    gpu_power=$(cat "/sys/bus/pci/devices/$GPU/power_state" 2>/dev/null) || true
    gpu_power=${gpu_power:-unknown}

    vm_state=$(virsh domstate overwatch 2>/dev/null) || true
    vm_state=$(echo "$vm_state" | xargs)
    vm_state=${vm_state:-unknown}

    fb=$(igpu_fb 2>/dev/null) && blank_val=$(cat "${fb}blank" 2>/dev/null) || true
    blank_val=${blank_val:-?}
    if [ "$blank_val" = "0" ]; then
        igpu_state="unblanked"
    elif [ "$blank_val" = "4" ]; then
        igpu_state="blanked"
    else
        igpu_state="unknown ($blank_val)"
    fi

    gdm_state=$(systemctl is-active gdm 2>/dev/null) || true
    gdm_state=${gdm_state:-unknown}
    ollama_state=$(systemctl is-active ollama 2>/dev/null) || true
    ollama_state=${ollama_state:-unknown}
    openrgb_state=$(systemctl is-active openrgb 2>/dev/null) || true
    openrgb_state=${openrgb_state:-unknown}

    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) || true
    gov=${gov:-unknown}
    irqbalance_state=$(systemctl is-active irqbalance 2>/dev/null) || true
    irqbalance_state=${irqbalance_state:-unknown}

    # Determine overall state
    if [ "$vm_state" = "running" ] && [ "$gpu_drv" = "vfio-pci" ]; then
        state="vm-running"
    elif [ "$vm_state" = "shut off" ] && [ "$gpu_drv" = "amdgpu" ] && [ "$gdm_state" = "active" ]; then
        state="host-ready"
    elif [ "$vm_state" = "shut off" ] && [ "$gpu_drv" = "amdgpu" ]; then
        state="host-ready (services pending)"
    else
        state="transitioning"
    fi

    echo "GPU:       $gpu_drv ($gpu_power)"
    echo "Audio:     $audio_drv"
    echo "VM:        $vm_state"
    echo "iGPU:      $igpu_state"
    echo "Services:  GDM=$gdm_state ollama=$ollama_state openrgb=$openrgb_state"
    echo "CPU:       $gov, irqbalance=$irqbalance_state"
    echo "State:     $state"
}

if [ "$CMD" = "status" ]; then
    do_status
    exit 0
fi

# --- Usage ---

if [ "$CMD" != "start" ] && [ "$CMD" != "stop" ]; then
    echo "Usage: overwatch [--verbose] start|stop|status"
    echo ""
    echo "  start   Prepare host, start VM, wait for shutdown, restore host"
    echo "  stop    Inspect state and restore host-mode (idempotent, safe to re-run)"
    echo "  status  Print current system state"
    exit 1
fi

# --- Logging setup (start/stop only) ---

log() { echo "$(date '+%H:%M:%S') $*"; }

# ERR trap — log exact line number and command on any failure
on_error() {
    local lineno=$1 cmd=$2 rc=$3
    log "ERROR: command failed at line $lineno: '$cmd' (exit code $rc)"
    log_state "on_error"
}
trap 'on_error $LINENO "$BASH_COMMAND" $?' ERR

if [ "$VERBOSE" = true ]; then
    export PS4='+${BASH_SOURCE}:${LINENO}: '
    set -x
    log "Verbose mode enabled"
fi

# --- State snapshot ---

log_state() {
    local checkpoint="${1:-unknown}"
    local gpu_drv gpu_audio_drv vm_state
    gpu_drv=$(gpu_driver "$GPU")
    gpu_audio_drv=$(gpu_driver "$GPU_AUDIO")
    vm_state=$(virsh domstate overwatch 2>/dev/null || echo "unknown")
    log "STATE [$checkpoint] gpu=$gpu_drv audio=$gpu_audio_drv vm=$vm_state"
}

# --- Lock ---

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: Another overwatch instance is already running (lock: $LOCK_FILE)"
        exit 1
    fi
    trap 'on_error $LINENO "$BASH_COMMAND" $?; flock -u 9; rm -f "$LOCK_FILE"' ERR
    trap 'flock -u 9; rm -f "$LOCK_FILE"' EXIT
}

# ============================================================
# Idempotent ensure_* functions
# Each checks current state and only acts if transition needed
# ============================================================

# --- Host preparation (used by start) ---

ensure_services_stopped() {
    local svc changed=false
    for svc in ollama openrgb; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "Stopping $svc..."
            systemctl stop "$svc" 2>/dev/null || true
            changed=true
        else
            log "$svc already stopped"
        fi
    done
    [ "$changed" = true ] && sleep 1

    if systemctl is-active --quiet gdm 2>/dev/null; then
        log "Stopping GDM..."
        systemctl stop gdm 2>/dev/null || true
        sleep 3
    else
        log "GDM already stopped"
    fi
}

ensure_device_fds_released() {
    log "Releasing device holders..."
    fuser -k /dev/dri/card1 /dev/dri/renderD128 2>/dev/null || true
    fuser -k /dev/i2c-4 /dev/i2c-5 /dev/i2c-6 /dev/i2c-7 /dev/i2c-8 /dev/i2c-9 /dev/i2c-10 2>/dev/null || true
    sleep 2
}

ensure_vt_unbound() {
    log "Unbinding VT consoles..."
    for vtcon in /sys/class/vtconsole/vtcon*/bind; do
        echo 0 > "$vtcon" 2>/dev/null || true
    done
    sleep 1
}

ensure_gpu_unbound_from_host() {
    local gpu_drv audio_drv
    gpu_drv=$(gpu_driver "$GPU")
    audio_drv=$(gpu_driver "$GPU_AUDIO")

    if [ "$gpu_drv" != "amdgpu" ] && [ "$audio_drv" != "snd_hda_intel" ]; then
        log "GPU not bound to host drivers (gpu=$gpu_drv, audio=$audio_drv) — skipping unbind"
        return 0
    fi

    if [ "$audio_drv" = "snd_hda_intel" ]; then
        log "Unbinding GPU audio..."
        echo "$GPU_AUDIO" > /sys/bus/pci/drivers/snd_hda_intel/unbind 2>/dev/null || true
        sleep 1
    fi

    if [ "$gpu_drv" = "amdgpu" ]; then
        # Suspend the dGPU framebuffer before unbinding. drm_fb_helper has a
        # damage_work worker that blits shadow→VRAM; if it's in-flight during
        # teardown, cancel_work_sync in drm_fb_helper_fini deadlocks because
        # the GPU hardware is being removed. Setting state=1 (FBINFO_STATE_SUSPENDED)
        # causes damage_work to bail out immediately. ~1.5% hit rate without this.
        for fb in /sys/class/graphics/fb*/; do
            if readlink -f "${fb}device" 2>/dev/null | grep -q "$GPU"; then
                echo 1 > "${fb}state" 2>/dev/null || true
                log "Suspended framebuffer $(basename "$fb")"
                break
            fi
        done
        log "Unbinding GPU from amdgpu..."
        echo "$GPU" > /sys/bus/pci/drivers/amdgpu/unbind
        sleep 2
        log "Unbind completed. GPU driver: $(gpu_driver "$GPU")"
    fi

    log_state "post_unbind"
}

ensure_gpu_on_vfio() {
    modprobe vfio-pci 2>/dev/null || true

    if [ "$(gpu_driver "$GPU")" = "vfio-pci" ] && [ "$(gpu_driver "$GPU_AUDIO")" = "vfio-pci" ]; then
        log "GPU already on vfio-pci — skipping bind"
        return 0
    fi

    log "Binding GPU to vfio-pci..."
    if [ "$(gpu_driver "$GPU")" != "vfio-pci" ]; then
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU/driver_override
        echo "$GPU" > /sys/bus/pci/drivers/vfio-pci/bind
    fi
    if [ "$(gpu_driver "$GPU_AUDIO")" != "vfio-pci" ]; then
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU_AUDIO/driver_override
        echo "$GPU_AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind
    fi
    sleep 1

    log "GPU driver: $(gpu_driver "$GPU")"
    if [ "$(gpu_driver "$GPU")" != "vfio-pci" ]; then
        log "ERROR: GPU not on vfio-pci after bind attempt"
        log_state "vfio_bind_failed"
        return 1
    fi

    # Bus reset after vfio-pci bind — gives the Windows AMD driver a clean
    # GPU state (closer to power-on) which may reduce boot-time TDR timeouts.
    gpu_bus_reset "clean guest handoff" || true
}

ensure_vm_running() {
    if virsh domstate overwatch 2>/dev/null | grep -q "running"; then
        log "ERROR: VM already running"
        return 1
    fi
    log "Starting VM..."
    if ! virsh start overwatch; then
        log "ERROR: virsh start failed"
        return 1
    fi
    log "VM started successfully."
}

set_igpu_blank() {
    local target=$1 label=$2
    local fb blank_val
    fb=$(igpu_fb) || { log "WARNING: iGPU framebuffer not found — cannot $label"; return 1; }
    blank_val=$(cat "${fb}blank" 2>/dev/null || echo "?")
    # Always write — kernel may report stale blank state after reboot
    log "${label^}ing iGPU output (${fb}blank: $blank_val → $target)..."
    echo "$target" > "${fb}blank" 2>/dev/null || { log "WARNING: Failed to $label iGPU"; return 1; }
    log "iGPU ${label}ed"
}

ensure_performance_tuning() {
    log "Applying VM performance tuning..."
    # Confine all host processes to HOST_CPUS — VM cores get zero host interference
    systemctl set-property --runtime -- system.slice AllowedCPUs=$HOST_CPUS 2>/dev/null || true
    systemctl set-property --runtime -- user.slice AllowedCPUs=$HOST_CPUS 2>/dev/null || true
    systemctl set-property --runtime -- init.scope AllowedCPUs=$HOST_CPUS 2>/dev/null || true
    # Set CPU governor to performance on all cores
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null || true
    done
    # Pin all IRQs to host CPUs so VM cores get no interrupt overhead
    systemctl stop irqbalance 2>/dev/null || true
    for irq_dir in /proc/irq/*/; do
        echo $HOST_CPUS > "${irq_dir}smp_affinity_list" 2>/dev/null || true
    done
    # Move RCU callbacks and writeback to host CPUs
    echo 3 > /sys/bus/workqueue/devices/writeback/cpumask 2>/dev/null || true
}

# --- Deferred Tartarus attach ---
# The Tartarus is NOT in the VM XML. It's hot-plugged after Synapse is running
# so that Synapse detects the USB arrival and applies keybind/lighting profiles.
# If attached at boot, Synapse hasn't started yet and profiles don't apply.

TARTARUS_USB_XML="<hostdev mode='subsystem' type='usb' managed='yes'><source><vendor id='0x1532'/><product id='0x022b'/></source></hostdev>"

attach_tartarus_deferred() {
    local start_epoch=$1

    # Wait for guest agent (up to 120s)
    local i
    for i in $(seq 1 60); do
        if virsh qemu-agent-command overwatch '{"execute":"guest-ping"}' &>/dev/null; then
            break
        fi
        sleep 2
    done

    # Poll for RazerAppEngine process (up to 120s)
    for i in $(seq 1 60); do
        local ps_out pid status_out
        ps_out=$(virsh qemu-agent-command overwatch \
            '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe","arg":["-Command","if(Get-Process RazerAppEngine -EA SilentlyContinue){\"RUNNING\"}else{\"WAITING\"}"],"capture-output":true}}' 2>/dev/null) || true
        if [ -n "$ps_out" ]; then
            pid=$(echo "$ps_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['return']['pid'])" 2>/dev/null) || true
            if [ -n "$pid" ]; then
                sleep 3
                status_out=$(virsh qemu-agent-command overwatch \
                    "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null) || true
                if echo "$status_out" | python3 -c "
import sys,json,base64
r=json.load(sys.stdin)['return']
if r.get('out-data'):
    print(base64.b64decode(r['out-data']).decode().strip())
" 2>/dev/null | grep -q "RUNNING"; then
                    break
                fi
            fi
        fi
        sleep 2
    done

    # Give Synapse a moment to finish initializing
    sleep 5

    # Attach Tartarus via virsh
    local elapsed
    if virsh attach-device overwatch /dev/stdin --live <<< "$TARTARUS_USB_XML" 2>/dev/null; then
        elapsed=$(( $(date +%s) - start_epoch ))
        log "Tartarus attached after ${elapsed}s (Synapse ready)"
    else
        elapsed=$(( $(date +%s) - start_epoch ))
        log "WARNING: Tartarus attach failed after ${elapsed}s"
    fi
}

# --- Host restoration (used by stop) ---

ensure_vm_stopped() {
    local vm_check
    vm_check=$(virsh domstate overwatch 2>/dev/null) || true
    if [ -z "$vm_check" ] || ! echo "$vm_check" | grep -q "running"; then
        log "VM not running"
        return 0
    fi
    log "Shutting down VM (graceful)..."
    virsh shutdown overwatch 2>/dev/null || true
    local waited=0
    while true; do
        local vm_poll
        vm_poll=$(virsh domstate overwatch 2>/dev/null) || true
        if [ -n "$vm_poll" ] && ! echo "$vm_poll" | grep -q "running"; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge 60 ]; then
            log "WARNING: VM still running after ${waited}s — forcing destroy"
            virsh destroy overwatch 2>/dev/null || true
            sleep 2
            break
        fi
    done
    log "VM stopped"
}

ensure_cpu_defaults() {
    log "Restoring CPU defaults..."
    # Restore host access to all cores
    systemctl set-property --runtime -- system.slice AllowedCPUs=0-7 2>/dev/null || true
    systemctl set-property --runtime -- user.slice AllowedCPUs=0-7 2>/dev/null || true
    systemctl set-property --runtime -- init.scope AllowedCPUs=0-7 2>/dev/null || true
    # Governor back to powersave
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo powersave > "$g" 2>/dev/null || true
    done
    # Restart irqbalance to redistribute IRQs
    systemctl start irqbalance 2>/dev/null || true
}

ensure_gpu_unbound_from_vfio() {
    local gpu_drv audio_drv
    gpu_drv=$(gpu_driver "$GPU")
    audio_drv=$(gpu_driver "$GPU_AUDIO")

    if [ "$gpu_drv" != "vfio-pci" ] && [ "$audio_drv" != "vfio-pci" ]; then
        log "GPU not on vfio-pci (gpu=$gpu_drv, audio=$audio_drv) — skipping unbind"
        # Clear driver_override even if not on vfio (may be stale)
        echo "" > /sys/bus/pci/devices/$GPU/driver_override 2>/dev/null || true
        echo "" > /sys/bus/pci/devices/$GPU_AUDIO/driver_override 2>/dev/null || true
        return 0
    fi

    log "Unbinding vfio-pci..."
    echo "$GPU" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "$GPU_AUDIO" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "" > /sys/bus/pci/devices/$GPU/driver_override 2>/dev/null || true
    echo "" > /sys/bus/pci/devices/$GPU_AUDIO/driver_override 2>/dev/null || true
    sleep 1
    log_state "post_vfio_unbind"
}

# Disable runtime PM on GPU and audio, bind audio to snd_hda_intel if needed.
# Called after any successful GPU bind method.
disable_gpu_runtime_pm() {
    # Disable runtime PM on GPU — amdgpu sets power/control to "auto" during
    # probe, and the GPU crashes on D3 resume.
    echo on > "/sys/bus/pci/devices/$GPU/power/control" 2>/dev/null || true

    # GPU audio: bind to snd_hda_intel if not already bound
    if [ -e "/sys/bus/pci/devices/$GPU_AUDIO" ]; then
        echo on > "/sys/bus/pci/devices/$GPU_AUDIO/power/control" 2>/dev/null || true
        if [ "$(gpu_driver "$GPU_AUDIO")" = "snd_hda_intel" ]; then
            log "GPU audio already bound to snd_hda_intel"
        else
            log "Binding GPU audio to snd_hda_intel..."
            echo "$GPU_AUDIO" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null || \
                log "WARNING: snd_hda_intel bind failed — HDMI/DP audio unavailable"
            echo on > "/sys/bus/pci/devices/$GPU_AUDIO/power/control" 2>/dev/null || true
        fi
    else
        log "WARNING: GPU audio device not found after rescan"
    fi

    log "Runtime PM disabled for GPU and audio"
}

ensure_gpu_on_host() {
    # Always rebind VT consoles (safe even if already bound)
    log "Rebinding VT consoles..."
    for vtcon in /sys/class/vtconsole/vtcon*/bind; do
        echo 1 > "$vtcon" 2>/dev/null || true
    done

    local gpu_drv
    gpu_drv=$(gpu_driver "$GPU")

    if [ "$gpu_drv" = "amdgpu" ]; then
        log "GPU already on amdgpu — skipping bind"
        disable_gpu_runtime_pm
        return 0
    fi

    # Primary: PCI remove+rescan gives amdgpu a completely fresh device,
    # avoiding the stale SR-IOV VF mailbox state that blocks probe() for ~4min.
    log "Attempting PCI remove+rescan (primary)..."
    if gpu_pci_remove_rescan && [ "$(gpu_driver "$GPU")" = "amdgpu" ]; then
        disable_gpu_runtime_pm
        return 0
    fi

    # Fallback: bus reset + direct bind with timeout
    log "PCI rescan did not bind — falling back to bus reset + timed bind..."
    gpu_bus_reset "post-VFIO host rebind" || true
    if gpu_bind_with_timeout 30 && [ "$(gpu_driver "$GPU")" = "amdgpu" ]; then
        disable_gpu_runtime_pm
        return 0
    fi

    log "WARNING: All GPU bind methods failed (driver=$(gpu_driver "$GPU"))"
    return 1
}

ensure_services_running() {
    local svc
    for svc in openrgb ollama; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "$svc already running"
        else
            log "Starting $svc..."
            systemctl start "$svc" 2>/dev/null || true
        fi
    done

    if systemctl is-active --quiet gdm 2>/dev/null; then
        log "GDM already running"
    else
        log "Starting GDM..."
        systemctl start gdm
        sleep 2
    fi

    # Ensure GDM monitors.xml is correct
    if [ -f /home/myuser/.config/monitors.xml ]; then
        cp /home/myuser/.config/monitors.xml /var/lib/gdm3/.config/monitors.xml
        chown gdm:gdm /var/lib/gdm3/.config/monitors.xml
    fi
}

# ============================================================
# Top-level operations
# ============================================================

_do_stop() {
    log "=== Restoring host state ==="

    ensure_vm_stopped
    ensure_cpu_defaults
    ensure_gpu_unbound_from_vfio
    set_igpu_blank 0 unblank || true
    ensure_services_running
    # GPU rebind last — user already has desktop on iGPU via GDM.
    # If this hangs or fails, the session is still usable.
    ensure_gpu_on_host || log "WARNING: Could not restore GPU to host — iGPU only"

    log "=== Host restored ==="
}

_do_start() {
    log "=== Starting Overwatch VM ==="

    # Handle SIGTERM from systemctl stop: shut down VM, restore host, exit
    trap '_on_sigterm' TERM
    _on_sigterm() {
        log "Received SIGTERM (systemctl stop) — shutting down..."
        _do_stop
        exit 0
    }

    # Refuse if VM already running
    if virsh domstate overwatch 2>/dev/null | grep -q "running"; then
        log "ERROR: VM is already running. Use 'systemctl stop overwatch' to stop it."
        exit 1
    fi

    # Pre-VM preparation (critical failures abort with cleanup)
    ensure_services_stopped
    ensure_device_fds_released
    ensure_vt_unbound
    ensure_gpu_unbound_from_host
    ensure_gpu_on_vfio || { log "ERROR: VFIO bind failed"; _do_stop; exit 1; }
    ensure_vm_running || { log "ERROR: VM start failed"; _do_stop; exit 1; }

    # Post-VM-start setup (non-critical, continue on failure)
    set_igpu_blank 4 blank || true
    ensure_performance_tuning

    log_state "vm_running"
    log "VM running. Waiting for shutdown..."

    # Deferred Tartarus attach — waits for Synapse then hot-plugs
    local VM_START_EPOCH
    VM_START_EPOCH=$(date +%s)
    attach_tartarus_deferred "$VM_START_EPOCH" &
    local tartarus_pid=$!

    # Listen for shutdown signal from guest (user clicks "Shutdown VM" shortcut)
    python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', ${SHUTDOWN_SIGNAL_PORT}))
s.recvfrom(64)
s.close()
" &>/dev/null &
    local listener_pid=$!

    # Wait for VM to shut down.
    # Accept definitive non-running state OR domain-not-found (libvirtd lost track).
    # Transient empty output (libvirtd hiccup) is treated as "keep waiting".
    local domain_missing=0
    while true; do
        local vm_poll
        vm_poll=$(virsh domstate overwatch 2>&1) || true

        if echo "$vm_poll" | grep -q "failed to get domain"; then
            domain_missing=$((domain_missing + 1))
            if [ $domain_missing -ge 3 ]; then
                log "WARNING: Domain not found in libvirt — treating as shutdown"
                local orphan_pid
                orphan_pid=$(pgrep -f "guest=overwatch" 2>/dev/null) || true
                if [ -n "$orphan_pid" ]; then
                    log "Killing orphaned QEMU (pid $orphan_pid)"
                    kill "$orphan_pid" 2>/dev/null || true
                    sleep 2
                fi
                break
            fi
        elif [ -n "$vm_poll" ] && ! echo "$vm_poll" | grep -q "running"; then
            break
        else
            domain_missing=0
        fi
        sleep 2
    done

    # Clean up background jobs
    kill "$tartarus_pid" 2>/dev/null || true
    kill "$listener_pid" 2>/dev/null || true
    wait "$tartarus_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true

    log "VM shut down detected."
    log_state "vm_shutdown"

    # Restore host
    _do_stop
}

# --- Main dispatch ---

case "$CMD" in
    start)
        acquire_lock
        _do_start
        ;;
    stop)
        acquire_lock
        _do_stop
        ;;
esac
