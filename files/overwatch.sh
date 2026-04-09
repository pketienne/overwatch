#!/bin/bash
# overwatch — multi-instance GPU-passthrough VM lifecycle dispatcher
#
# Single shared launcher; per-VM behavior is loaded from
#   /usr/local/share/overwatch/<vm>/instance.conf
# at runtime. Capability flags (GPU_PASSTHROUGH, TARTARUS_ATTACH) determine
# whether the heavy host-handoff dance runs or whether the VM is started
# as a plain libvirt domain.
#
# Manages the host through: host-mode ↔ vfio ↔ vm-running (when GPU_PASSTHROUGH=true)
#
# Subcommands:
#   start <vm>           Full lifecycle: prepare host → start VM → wait for shutdown → restore host
#   stop <vm>            Inspect current state, do minimum work to reach host-mode (idempotent)
#   status <vm>          Print current system state across all dimensions
#   acquire-mutex <vm>   Atomically claim /run/overwatch/active-vm (used by ExecStartPre)
#   release-mutex <vm>   Release /run/overwatch/active-vm if owned by this VM (used by ExecStopPost)
#
# Runs as a systemd template service: systemctl start overwatch@<vm>.service
# Log: journalctl -u overwatch@<vm>.service
#
# Usage: overwatch [--verbose] <subcommand> <vm>
#
# Managed by Chef (overwatch cookbook). Do not edit directly.
#
# --- Telemetry tags ---
#
# All tags are searchable in journald:
#   journalctl -u overwatch | grep <TAG>
#
# Lifecycle:
#   STATE          GPU/audio driver, VM state at named checkpoints
#   ERROR          Command failures (line number, command, exit code)
#   BOOT_TIMING    guest_agent=Ns, synapse_ready=Ns, tartarus=Ns from VM start
#
# Host monitors (background, continuous):
#   NET_HOST       vnet RX/TX drops, TRAFFIC_ACTIVE/TRAFFIC_IDLE transitions
#   PCAP           Rolling packet capture on br0 (20×50MB ring)
#   LATENCY_HOST   ICMP reachability to 8.8.8.8 (1s poll)
#   PERF_HOST      Per-core CPU, disk I/O, memory (30s poll)
#   TRANSITION     Throttle events relayed from guest transition-throttle.ps1
#
# Guest monitors (background, via guest agent):
#   PERF_GUEST     GPU load/temps/clocks/VRAM via LibreHardwareMonitor (60s poll)
#   NET_GUEST      Windows NetworkProfile connect/disconnect events (10s poll)
#   SHUTDOWN_DIAG  Prior-session shutdown events (IDs 200-203)
#   CRASH_DUMPS    Recent .dmp files from LiveKernelReports + Minidump
#   GPU_DRIVER     AMD GPU PnP status and driver version
#   HD_AUDIO       GPU audio codec PnP status
#   DISPLAY_EVENTS Recent dxgkrnl/Dwm/Display events
#   BOOT_DIAG      Windows boot timing (Event 100)
#   BNET_GUEST     BNPresence errors in current Battle.net log
#   OW2_SETTINGS   Key in-game settings (render scale, frame cap, window mode)
#
# Grep all:
#   journalctl -u overwatch | grep -E \
#     "STATE|ERROR|BOOT_TIMING|NET_HOST|PCAP|LATENCY_HOST|PERF_HOST|TRANSITION|PERF_GUEST|NET_GUEST|SHUTDOWN_DIAG|CRASH_DUMPS|GPU_DRIVER|HD_AUDIO|DISPLAY_EVENTS|BOOT_DIAG|BNET_GUEST|OW2_SETTINGS"

set -uo pipefail

# --- Parse arguments ---

VERBOSE=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --verbose) VERBOSE=true ;;
    esac
    shift
done
CMD="${1:-}"
VM_NAME="${2:-}"

usage() {
    cat >&2 <<'EOF'
Usage: overwatch [--verbose] <subcommand> <vm>

Subcommands:
  start <vm>            Prepare host, start VM, wait for shutdown, restore host
  stop <vm>             Inspect state and restore host-mode (idempotent, safe to re-run)
  status <vm>           Print current system state for the named VM
  acquire-mutex <vm>    Atomically claim /run/overwatch/active-vm
  release-mutex <vm>    Release /run/overwatch/active-vm if owned by this VM
EOF
}

if [ -z "$CMD" ] || [ -z "$VM_NAME" ]; then
    usage
    exit 1
fi

# --- Mutex subcommands (handled before sourcing instance.conf) ---
#
# active-vm holds the name of the currently-running instance. ExecStartPre
# in the systemd template unit calls acquire-mutex; ExecStopPost calls
# release-mutex. Atomicity is provided by O_EXCL via `set -C`.

ACTIVE_VM_FILE="/run/overwatch/active-vm"

acquire_mutex() {
    local vm="$1"
    mkdir -p /run/overwatch 2>/dev/null || true
    if (set -C; echo "$vm" > "$ACTIVE_VM_FILE") 2>/dev/null; then
        return 0
    fi
    local owner
    owner=$(cat "$ACTIVE_VM_FILE" 2>/dev/null) || true
    if [ "$owner" = "$vm" ]; then
        return 0
    fi
    echo "ERROR: another overwatch VM is active: ${owner:-<unknown>} (cannot start $vm)" >&2
    return 1
}

release_mutex() {
    local vm="$1"
    local owner
    owner=$(cat "$ACTIVE_VM_FILE" 2>/dev/null) || true
    if [ "$owner" = "$vm" ]; then
        rm -f "$ACTIVE_VM_FILE"
    fi
    return 0
}

case "$CMD" in
    acquire-mutex) acquire_mutex "$VM_NAME"; exit $? ;;
    release-mutex) release_mutex "$VM_NAME"; exit $? ;;
esac

# --- Load per-VM config ---

INSTANCE_CONF="/usr/local/share/overwatch/${VM_NAME}/instance.conf"
if [ ! -f "$INSTANCE_CONF" ]; then
    echo "ERROR: instance config not found: $INSTANCE_CONF" >&2
    echo "       (is '$VM_NAME' a valid overwatch instance on this host?)" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$INSTANCE_CONF"

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
# Logs: reset completion time and vendor ID readiness.
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

# ERR trap — log exact line number and command on any failure.
# Tag: ERROR
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
# Tag: STATE
# Logs GPU driver, audio driver, and VM domain state at named transition points
# (post_unbind, vfio_bind_failed, vm_running, vm_shutdown, on_error).
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
        # HypE 2026-04-08: bus reset DISABLED to test if unconditional reset is the TDR cause
        # # Bus reset even when already on vfio-pci
        # gpu_bus_reset "clean guest handoff" || true
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

    # HypE 2026-04-08: bus reset DISABLED to test if unconditional reset is the TDR cause
    # # Bus reset after vfio-pci bind — gives the Windows AMD driver a clean
    # # GPU state (closer to power-on) which may reduce boot-time TDR timeouts.
    # gpu_bus_reset "clean guest handoff" || true
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
    log "Applying performance tuning (governor, IRQs, writeback)..."
    # Set CPU governor to performance on all cores
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null || true
    done
    # Cap vCPU cores at C1 — prevent deep C-state entry to reduce wakeup latency
    # state0=POLL, state1=C1 kept; state2+ (C2, C6, etc.) disabled
    for cpu in $(seq 2 7); do
        for state in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state[2-9]/; do
            [ -f "${state}disable" ] && echo 1 > "${state}disable" 2>/dev/null || true
        done
    done
    # Pin all IRQs to host CPUs so VM cores get no interrupt overhead
    systemctl stop irqbalance 2>/dev/null || true
    for irq_dir in /proc/irq/*/; do
        echo $HOST_CPUS > "${irq_dir}smp_affinity_list" 2>/dev/null || true
    done
    # Move RCU callbacks and writeback to host CPUs
    echo 3 > /sys/bus/workqueue/devices/writeback/cpumask 2>/dev/null || true
    # Disable scheduler autogroup — prevents TTY-based throughput grouping for QEMU
    echo 0 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
}

# Confine host processes to HOST_CPUS, run as a background job after VM start.
#
# AllowedCPUs is applied AFTER Windows finishes booting (guest agent responds),
# not immediately at VM start. Reason: AllowedCPUs restricts the QEMU emulator
# thread to HOST_CPUS, which limits bandwidth for interrupt injection during
# Windows boot (driver init, service startup). Applied too early, this noticeably
# slows boot. During gameplay it's the opposite — vCPU cores need to be
# interference-free for consistent GPU command delivery (frame pacing).
#
# Falls back to applying immediately if guest agent doesn't respond within 120s.
apply_cpu_isolation() {
    local deadline=$(($(date +%s) + 120))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if virsh qemu-agent-command overwatch '{"execute":"guest-ping"}' &>/dev/null; then
            log "Guest agent up — applying CPU isolation (AllowedCPUs=$HOST_CPUS)"
            systemctl set-property --runtime -- system.slice AllowedCPUs=$HOST_CPUS 2>/dev/null || true
            systemctl set-property --runtime -- user.slice AllowedCPUs=$HOST_CPUS 2>/dev/null || true
            systemctl set-property --runtime -- init.scope AllowedCPUs=$HOST_CPUS 2>/dev/null || true
            return
        fi
        sleep 2
    done
    log "Guest agent timeout — applying CPU isolation anyway (AllowedCPUs=$HOST_CPUS)"
    systemctl set-property --runtime -- system.slice AllowedCPUs=$HOST_CPUS 2>/dev/null || true
    systemctl set-property --runtime -- user.slice AllowedCPUs=$HOST_CPUS 2>/dev/null || true
    systemctl set-property --runtime -- init.scope AllowedCPUs=$HOST_CPUS 2>/dev/null || true
}

apply_sched_fifo() {
    local qemu_pid count=0
    qemu_pid=$(pgrep -f "qemu-system.*overwatch" 2>/dev/null | head -1) || true
    if [ -z "$qemu_pid" ]; then
        log "SCHED_FIFO: QEMU PID not found, skipping"
        return
    fi
    for tid in $(ls /proc/$qemu_pid/task/ 2>/dev/null); do
        chrt -f -p 1 $tid 2>/dev/null && count=$((count + 1)) || true
    done
    log "SCHED_FIFO: applied to $count QEMU threads (PID $qemu_pid)"
}

# Source background monitors and deferred boot tasks
# Source background monitors and deferred boot tasks (shared across all VMs)
source "${SHARED_DIR}/overwatch-monitors.sh"


# --- Guest agent helpers ---

# Run a PowerShell command on the guest via guest agent and return decoded stdout.
# Uses guest-exec + guest-exec-status; polls for completion up to max_wait seconds.
# Usage: guest_run_ps <cmd> [max_wait_s]
guest_run_ps() {
    local cmd="$1"
    local max_wait="${2:-30}"
    local req ps_out pid i status_out exited

    req=$(python3 -c "
import json, sys
print(json.dumps({
    'execute': 'guest-exec',
    'arguments': {
        'path': 'C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe',
        'arg': ['-NonInteractive', '-Command', sys.argv[1]],
        'capture-output': True
    }
}))" "$cmd" 2>/dev/null) || return 1

    ps_out=$(virsh qemu-agent-command overwatch "$req" 2>/dev/null) || return 1
    pid=$(echo "$ps_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['return']['pid'])" 2>/dev/null) || return 1
    [ -z "$pid" ] && return 1

    for i in $(seq 1 "$max_wait"); do
        status_out=$(virsh qemu-agent-command overwatch \
            "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null) || return 1
        exited=$(echo "$status_out" | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['return'].get('exited',False))" 2>/dev/null) || break
        if [ "$exited" = "True" ]; then
            echo "$status_out" | python3 -c "
import sys,json,base64
r=json.load(sys.stdin)['return']
if r.get('out-data'):
    print(base64.b64decode(r['out-data']).decode('utf-8','replace').strip())" 2>/dev/null
            return 0
        fi
        sleep 1
    done
    return 1
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
    # Re-enable deep C-states on vCPU cores
    for cpu in $(seq 2 7); do
        for state in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state[2-9]/; do
            [ -f "${state}disable" ] && echo 0 > "${state}disable" 2>/dev/null || true
        done
    done
    # Governor back to powersave
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo powersave > "$g" 2>/dev/null || true
    done
    # Restart irqbalance to redistribute IRQs
    systemctl start irqbalance 2>/dev/null || true
    echo 1 > /proc/sys/kernel/sched_autogroup_enabled 2>/dev/null || true
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
    if [ -f "/home/${TARGET_USER}/.config/monitors.xml" ]; then
        cp "/home/${TARGET_USER}/.config/monitors.xml" /var/lib/gdm3/.config/monitors.xml
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

    # --- SIGTERM deferral during GPU handoff ---
    # The GPU handoff (host → vfio → VM) puts the system in a transitional state.
    # If SIGTERM (from systemctl stop) arrives mid-handoff and we immediately try
    # to reverse the GPU operations, the half-unbound GPU causes a kernel panic.
    # Solution: defer SIGTERM during the critical section, then handle it once
    # the system is in a stable state (VM running, or fully rolled back).
    local SIGTERM_DEFERRED=false
    trap 'SIGTERM_DEFERRED=true; log "SIGTERM deferred — GPU handoff in progress"' TERM

    # Refuse if VM already running
    if virsh domstate overwatch 2>/dev/null | grep -q "running"; then
        log "ERROR: VM is already running. Use 'systemctl stop overwatch' to stop it."
        exit 1
    fi

    # === CRITICAL SECTION: GPU handoff (SIGTERM deferred) ===
    ensure_services_stopped
    ensure_device_fds_released
    ensure_vt_unbound
    ensure_gpu_unbound_from_host
    ensure_gpu_on_vfio || { log "ERROR: VFIO bind failed"; _do_stop; exit 1; }
    ensure_vm_running || { log "ERROR: VM start failed"; _do_stop; exit 1; }
    # === END CRITICAL SECTION ===

    # Stable state reached: VM running, GPU on vfio-pci.
    # If SIGTERM arrived during handoff, do a clean shutdown now.
    if [ "$SIGTERM_DEFERRED" = true ]; then
        log "Processing deferred SIGTERM — stopping VM..."
        _do_stop
        exit 0
    fi

    # Install interruptible SIGTERM handler for the wait loop
    _on_sigterm() {
        log "Received SIGTERM (systemctl stop) — shutting down..."
        _do_stop
        exit 0
    }
    trap '_on_sigterm' TERM

    # Post-VM-start setup (non-critical, continue on failure)
    set_igpu_blank 4 blank || true
    ensure_performance_tuning
    apply_sched_fifo

    log_state "vm_running"
    log "VM running. Waiting for shutdown..."

    # CPU isolation — deferred until guest agent responds (Windows finished booting).
    # See apply_cpu_isolation() for rationale on why this is not applied immediately.
    apply_cpu_isolation &
    local cpu_iso_pid=$!

    # Deferred Tartarus attach — waits for Synapse then hot-plugs
    local VM_START_EPOCH
    VM_START_EPOCH=$(date +%s)
    attach_tartarus_deferred "$VM_START_EPOCH" &
    local tartarus_pid=$!

    # Network monitor — polls vnet interface for drop events
    monitor_network &
    local netmon_pid=$!

    # Host performance monitor — 30s PERF_HOST loop
    monitor_host_perf &
    local perf_host_pid=$!

    # Guest boot diagnostics — one-shot after boot (120s delay to avoid contention)
    log_guest_diagnostics &
    local diag_pid=$!

    # Guest GPU performance monitor — 60s PERF_GUEST loop via LHM WMI
    monitor_guest_perf &
    local guest_perf_pid=$!

    # Packet capture -- rolling ring buffer on br0 for post-incident Wireshark analysis
    monitor_pcap &
    local pcap_pid=$!

    # Host latency monitor -- 1s ping to 8.8.8.8; distinguishes host vs OW2-specific drops
    monitor_latency_host &
    local latency_host_pid=$!

    # Guest network monitor -- polls Windows NetworkProfile events 10000/10001 via guest agent
    monitor_guest_network &
    local guest_netmon_pid=$!

    # Transition throttle event listener -- receives TRANSITION messages from guest script
    monitor_transition_events &
    local transition_pid=$!

    # Listen for shutdown signal from guest; record timestamp on receipt
    rm -f /tmp/.overwatch-shutdown-ts
    {
        python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', ${SHUTDOWN_SIGNAL_PORT}))
s.recvfrom(64)
s.close()
open('/tmp/.overwatch-shutdown-ts','w').write(str(int(time.time())))" \
        && log "Shutdown signal received from guest"
    } &
    local listener_pid=$!

    # Wait for VM to shut down.
    # Accept definitive non-running state OR domain-not-found (libvirtd lost track).
    # Transient empty output (libvirtd hiccup) is treated as "keep waiting".
    local qemu_pid prev_qemu_state=""
    qemu_pid=$(pgrep -f "guest=overwatch" 2>/dev/null) || true
    local domain_missing=0
    while true; do
        # Track QEMU process state transitions (S=sleeping, D=uninterruptible, exited)
        if [ -n "$qemu_pid" ]; then
            local qemu_state
            qemu_state=$(awk '/^State:/{print $2}' "/proc/$qemu_pid/status" 2>/dev/null) || true
            if [ -n "$qemu_state" ] && [ "$qemu_state" != "$prev_qemu_state" ]; then
                log "QEMU state: ${prev_qemu_state:-(started)} → $qemu_state (pid $qemu_pid)"
                prev_qemu_state=$qemu_state
            fi
        fi

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

    # Shutdown duration: signal-to-domain-stop delta
    if [ -f /tmp/.overwatch-shutdown-ts ]; then
        local sig_ts dur
        sig_ts=$(cat /tmp/.overwatch-shutdown-ts 2>/dev/null) || true
        if [ -n "$sig_ts" ]; then
            dur=$(( $(date +%s) - sig_ts ))
            if [ "$dur" -le 300 ]; then
                log "Shutdown duration: ${dur}s (signal to domain-stop)"
            else
                log "WARNING: Shutdown duration ${dur}s exceeds 300s limit"
            fi
        fi
        rm -f /tmp/.overwatch-shutdown-ts
    fi

    # Clean up background jobs
    kill "$cpu_iso_pid" 2>/dev/null || true
    kill "$tartarus_pid" 2>/dev/null || true
    kill "$listener_pid" 2>/dev/null || true
    kill "$netmon_pid" 2>/dev/null || true
    kill "$perf_host_pid" 2>/dev/null || true
    kill "$diag_pid" 2>/dev/null || true
    kill "$guest_perf_pid" 2>/dev/null || true
    kill "$pcap_pid" 2>/dev/null || true
    kill "$latency_host_pid" 2>/dev/null || true
    kill "$guest_netmon_pid" 2>/dev/null || true
    kill "$transition_pid" 2>/dev/null || true
    wait "$cpu_iso_pid" 2>/dev/null || true
    wait "$tartarus_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    wait "$netmon_pid" 2>/dev/null || true
    wait "$perf_host_pid" 2>/dev/null || true
    wait "$diag_pid" 2>/dev/null || true
    wait "$guest_perf_pid" 2>/dev/null || true
    wait "$pcap_pid" 2>/dev/null || true
    wait "$latency_host_pid" 2>/dev/null || true
    wait "$guest_netmon_pid" 2>/dev/null || true
    wait "$transition_pid" 2>/dev/null || true

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
