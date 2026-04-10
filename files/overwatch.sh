#!/bin/bash
# overwatch — multi-instance GPU-passthrough VM lifecycle dispatcher
#
# Single shared launcher; per-VM behavior is loaded from
#   /usr/local/share/overwatch/<vm>/instance.conf
# at runtime.
#
# Mode switching is reboot-based: the kernel must be booted with
# overwatch.mode=vm (vfio-pci.ids claims the dGPU + audio at boot, hugepages
# reserved, host CPUs isolated). The mode-gate ExecStartPre in
# overwatch@.service triggers a reboot via /usr/local/bin/overwatch-mode if
# the host is in host-mode when a VM start is requested.
#
# Subcommands:
#   start <vm>           Verify vm-mode preconditions, start VM, wait for shutdown
#   stop <vm>            Stop the VM and restore host CPU tunables (no GPU rebind)
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

# Defense-in-depth precondition check for the vm-mode start path. Verifies
# the kernel really was booted with overwatch.mode=vm AND that the dGPU +
# audio function are already on vfio-pci (which they should be, since
# vfio-pci.ids in the vm-mode cmdline claims them at boot). If either check
# fails, something rebound the GPU since boot, or the cmdline marker is
# missing — refuse to start and let the user diagnose.
ensure_vm_mode_ready() {
    local mode gpu_drv audio_drv
    mode=unknown
    local tok
    for tok in $(cat /proc/cmdline 2>/dev/null); do
        case "$tok" in
            overwatch.mode=host) mode=host; break ;;
            overwatch.mode=vm)   mode=vm;   break ;;
        esac
    done
    if [ "$mode" != "vm" ]; then
        log "ERROR: host boot mode is '${mode}', not 'vm'"
        log "       use 'systemctl start overwatch@${VM_NAME}.service' (which triggers"
        log "       'overwatch-mode require vm') or run 'overwatch-mode require vm ${VM_NAME}'"
        log "       to one-shot reboot into vm-mode."
        return 1
    fi
    gpu_drv=$(gpu_driver "$GPU")
    audio_drv=$(gpu_driver "$GPU_AUDIO")
    if [ "$gpu_drv" != "vfio-pci" ] || [ "$audio_drv" != "vfio-pci" ]; then
        log "ERROR: vm-mode boot but GPU not on vfio-pci (gpu=$gpu_drv, audio=$audio_drv)"
        log "       this should not happen — vfio-pci.ids in the cmdline should claim"
        log "       both devices at boot. Check dmesg for vfio-pci probe failures."
        return 1
    fi
    log "vm-mode preconditions OK (gpu=$gpu_drv, audio=$audio_drv)"
    return 0
}

# ============================================================
# status — print current system state (no side effects)
# ============================================================

do_status() {
    local gpu_drv audio_drv vm_state gpu_power
    local boot_mode
    local gov irqbalance_state
    local state

    gpu_drv=$(gpu_driver "$GPU")
    audio_drv=$(gpu_driver "$GPU_AUDIO")
    gpu_power=$(cat "/sys/bus/pci/devices/$GPU/power_state" 2>/dev/null) || true
    gpu_power=${gpu_power:-unknown}

    vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null) || true
    vm_state=$(echo "$vm_state" | xargs)
    vm_state=${vm_state:-unknown}

    boot_mode=unknown
    local tok
    for tok in $(cat /proc/cmdline 2>/dev/null); do
        case "$tok" in
            overwatch.mode=host) boot_mode=host; break ;;
            overwatch.mode=vm)   boot_mode=vm;   break ;;
        esac
    done

    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) || true
    gov=${gov:-unknown}
    irqbalance_state=$(systemctl is-active irqbalance 2>/dev/null) || true
    irqbalance_state=${irqbalance_state:-unknown}

    # Determine overall state from boot-mode + VM state
    if [ "$boot_mode" = "vm" ] && [ "$vm_state" = "running" ]; then
        state="vm-running"
    elif [ "$boot_mode" = "vm" ] && [ "$vm_state" = "shut off" ]; then
        state="vm-mode (idle)"
    elif [ "$boot_mode" = "host" ]; then
        state="host-mode"
    else
        state="unknown (boot_mode=$boot_mode vm=$vm_state)"
    fi

    echo "Boot mode: $boot_mode"
    echo "GPU:       $gpu_drv ($gpu_power)"
    echo "Audio:     $audio_drv"
    echo "VM:        $vm_state"
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
    vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
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

ensure_vm_running() {
    if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
        log "ERROR: VM already running"
        return 1
    fi
    log "Starting VM..."
    if ! virsh start "$VM_NAME"; then
        log "ERROR: virsh start failed"
        return 1
    fi
    log "VM started successfully."
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
    # Pin non-vfio IRQs to host CPUs; let vfio (GPU) IRQs float across
    # all cores so burst interrupt loads are distributed. managed_irq was
    # removed from isolcpus to allow this — the kernel can deliver GPU
    # interrupts on any core including vCPU cores, reducing injection
    # latency during burst workloads (loading screens).
    systemctl stop irqbalance 2>/dev/null || true
    for irq_dir in /proc/irq/*/; do
        if ! grep -q 'vfio' "${irq_dir}actions" 2>/dev/null && \
           ! grep -q "$(basename "$irq_dir"):" /proc/interrupts 2>/dev/null | grep -q 'vfio-msi' 2>/dev/null; then
            echo $HOST_CPUS > "${irq_dir}smp_affinity_list" 2>/dev/null || true
        fi
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
        if virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' &>/dev/null; then
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
    qemu_pid=$(pgrep -f "qemu-system.*$VM_NAME" 2>/dev/null | head -1) || true
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

    ps_out=$(virsh qemu-agent-command "$VM_NAME" "$req" 2>/dev/null) || return 1
    pid=$(echo "$ps_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['return']['pid'])" 2>/dev/null) || return 1
    [ -z "$pid" ] && return 1

    for i in $(seq 1 "$max_wait"); do
        status_out=$(virsh qemu-agent-command "$VM_NAME" \
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
    vm_check=$(virsh domstate "$VM_NAME" 2>/dev/null) || true
    if [ -z "$vm_check" ] || ! echo "$vm_check" | grep -q "running"; then
        log "VM not running"
        return 0
    fi
    log "Shutting down VM (graceful)..."
    virsh shutdown "$VM_NAME" 2>/dev/null || true
    local waited=0
    while true; do
        local vm_poll
        vm_poll=$(virsh domstate "$VM_NAME" 2>/dev/null) || true
        if [ -n "$vm_poll" ] && ! echo "$vm_poll" | grep -q "running"; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge 60 ]; then
            log "WARNING: VM still running after ${waited}s — forcing destroy"
            virsh destroy "$VM_NAME" 2>/dev/null || true
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

# ============================================================
# Top-level operations
# ============================================================

_do_stop() {
    log "=== Restoring host state ==="

    # Stop the VM and restore host CPU tunables. The dGPU stays on vfio-pci —
    # returning to host-mode (amdgpu, ollama on dGPU) is a reboot, not a
    # runtime op. The kernel command line pins everything at boot.
    ensure_vm_stopped
    ensure_cpu_defaults

    log "=== Host restored (dGPU stays on vfio-pci; host-mode is a reboot away) ==="
}

_do_start() {
    log "=== Starting Overwatch VM ==="

    # Refuse if VM already running
    if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
        log "ERROR: VM is already running. Use 'systemctl stop overwatch@${VM_NAME}.service' to stop it."
        exit 1
    fi

    # Defense-in-depth: verify the kernel was booted in vm-mode AND that
    # the dGPU + audio are already on vfio-pci. The mode-gate ExecStartPre
    # in overwatch@.service should make this unreachable from the wrong
    # mode, but check anyway in case the launcher was invoked directly.
    ensure_vm_mode_ready || { log "ERROR: vm-mode preconditions not met"; exit 1; }

    # Start the VM. libvirt domain XML references the already-bound
    # vfio-pci GPU via hostdev PCI address.
    ensure_vm_running || { log "ERROR: VM start failed"; exit 1; }

    # Install SIGTERM handler for the monitor loop
    _on_sigterm() {
        log "Received SIGTERM (systemctl stop) — shutting down..."
        _do_stop
        exit 0
    }
    trap '_on_sigterm' TERM

    # Post-VM-start performance tuning (non-critical, continue on failure)
    ensure_performance_tuning
    apply_sched_fifo

    # Increase halt_poll_ns to reduce KVM interrupt injection latency
    # during GPU burst workloads (loading screens). Default 200µs is
    # too short — GPU interrupt bursts arrive at ~280µs intervals
    # (3600 IRQs/sec), causing KVM to sleep the vCPU just before
    # each interrupt, adding wake-up latency. 800µs covers the burst
    # interval with margin.
    echo 800000 > /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null || true
    log "KVM halt_poll_ns set to 800000"

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
    qemu_pid=$(pgrep -f "guest=$VM_NAME" 2>/dev/null) || true
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
        vm_poll=$(virsh domstate "$VM_NAME" 2>&1) || true

        if echo "$vm_poll" | grep -q "failed to get domain"; then
            domain_missing=$((domain_missing + 1))
            if [ $domain_missing -ge 3 ]; then
                log "WARNING: Domain not found in libvirt — treating as shutdown"
                local orphan_pid
                orphan_pid=$(pgrep -f "guest=$VM_NAME" 2>/dev/null) || true
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
