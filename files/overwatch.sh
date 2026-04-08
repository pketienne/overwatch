#!/bin/bash
# overwatch — multi-instance GPU-passthrough VM lifecycle dispatcher
#
# Single shared launcher; per-VM behavior is loaded from
#   /usr/local/share/overwatch/<vm>/instance.conf
# at runtime. Capability flags (GPU_PASSTHROUGH, TARTARUS_ATTACH) determine
# whether the launcher enforces vm-mode boot state or starts the VM as a
# plain libvirt domain.
#
# Boot-mode model
# ---------------
# Mode switching is reboot-based, not in-uptime. The host boots into one
# of two modes selected by custom GRUB menuentries:
#
#   host-mode (default): dGPU on amdgpu, ollama runs, full host CPU/RAM,
#                        no hugepages, no core isolation. Mode marker:
#                        overwatch.mode=host on the kernel cmdline.
#   vm-mode:             dGPU on vfio-pci at boot (via vfio-pci.ids=...),
#                        hugepages reserved, host CPUs 2-7 isolated, ready
#                        for QEMU. Mode marker: overwatch.mode=vm.
#
# This launcher operates ONLY in vm-mode for passthrough instances. The
# overwatch@<vm>.service unit's ExecStartPre calls `overwatch-mode require
# vm %i`, which one-shot reboots the host into vm-mode if it isn't already
# there. By the time `overwatch start` runs, the dGPU is already on vfio-pci
# from boot — the launcher does not unbind/rebind the GPU, does not stop
# host services (ollama isn't running in vm-mode), and does not try to
# restore host-mode on shutdown. To return to ollama, the user reboots
# (manually or via `systemctl start ollama`, which triggers the same
# mode-check + grub-reboot dance via the ollama drop-in).
#
# Subcommands:
#   start <vm>           Verify vm-mode preconditions, start VM, run monitors,
#                        wait for shutdown
#   stop <vm>            Stop VM and restore host CPU defaults (idempotent)
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

# Read /proc/cmdline for the boot-mode marker set by the GRUB menuentry.
# Returns: "host", "vm", or "unknown".
boot_mode() {
    local tok
    for tok in $(cat /proc/cmdline 2>/dev/null); do
        case "$tok" in
            overwatch.mode=host) echo host; return 0 ;;
            overwatch.mode=vm)   echo vm;   return 0 ;;
        esac
    done
    echo unknown
}

# ============================================================
# status — print current system state (no side effects)
# ============================================================

do_status() {
    local gpu_drv audio_drv vm_state gpu_power
    local mode
    local gov irqbalance_state
    local state

    mode=$(boot_mode)
    gpu_drv=$(gpu_driver "$GPU")
    audio_drv=$(gpu_driver "$GPU_AUDIO")
    gpu_power=$(cat "/sys/bus/pci/devices/$GPU/power_state" 2>/dev/null) || true
    gpu_power=${gpu_power:-unknown}

    vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null) || true
    vm_state=$(echo "$vm_state" | xargs)
    vm_state=${vm_state:-unknown}

    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) || true
    gov=${gov:-unknown}
    irqbalance_state=$(systemctl is-active irqbalance 2>/dev/null) || true
    irqbalance_state=${irqbalance_state:-unknown}

    # Overall state. For passthrough instances, this is a function of boot mode
    # AND VM state; non-passthrough instances care only about VM state.
    if [ "$GPU_PASSTHROUGH" = "true" ]; then
        if [ "$mode" = "host" ]; then
            state="host-mode (cannot start VM — reboot to vm-mode required)"
        elif [ "$mode" = "vm" ] && [ "$vm_state" = "running" ] && [ "$gpu_drv" = "vfio-pci" ]; then
            state="vm-running"
        elif [ "$mode" = "vm" ] && [ "$vm_state" = "shut off" ]; then
            state="vm-mode idle (VM stopped, dGPU on vfio-pci)"
        elif [ "$mode" = "vm" ]; then
            state="vm-mode transitioning"
        else
            state="unknown boot mode"
        fi
    else
        case "$vm_state" in
            running)  state="vm-running (no passthrough)" ;;
            "shut off") state="vm-stopped" ;;
            *)        state="$vm_state" ;;
        esac
    fi

    local active_owner
    active_owner=$(cat "$ACTIVE_VM_FILE" 2>/dev/null) || true
    active_owner=${active_owner:-<none>}

    echo "Instance:  $VM_NAME (gpu_passthrough=$GPU_PASSTHROUGH)"
    echo "Boot mode: $mode"
    echo "Active:    $active_owner"
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
    usage
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
    mkdir -p /run/overwatch 2>/dev/null || true
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: Another overwatch[$VM_NAME] instance is already running (lock: $LOCK_FILE)"
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
#
# vm-mode boots arrive with the dGPU already on vfio-pci (via vfio-pci.ids
# in the kernel cmdline), no ollama running, hugepages reserved, and host
# CPUs 2-7 isolated. The launcher's "preparation" is therefore reduced to
# verifying those preconditions and starting the VM. There is no GPU driver
# unbind/rebind, no GDM cycling, no VT console manipulation, no framebuffer
# blanking, no PCI bus reset.

# Verify vm-mode preconditions for a passthrough VM start. Returns non-zero
# if the host isn't ready (caller should fail loudly — the user should be
# rebooting via overwatch-mode require vm, not running this directly).
ensure_vm_mode_ready() {
    local mode gpu_drv audio_drv
    mode=$(boot_mode)
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
    qemu_pid=$(pgrep -f "qemu-system.*guest=$VM_NAME" 2>/dev/null | head -1) || true
    if [ -z "$qemu_pid" ]; then
        log "SCHED_FIFO: QEMU PID not found, skipping"
        return
    fi
    for tid in $(ls /proc/$qemu_pid/task/ 2>/dev/null); do
        chrt -f -p 1 $tid 2>/dev/null && count=$((count + 1)) || true
    done
    log "SCHED_FIFO: applied to $count QEMU threads (PID $qemu_pid)"
}

# Source background monitors and deferred boot tasks (shared across all VMs)
source /usr/local/share/overwatch/shared/overwatch-monitors.sh


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

# --- Host restoration on VM shutdown ---
#
# Returning to host-mode (ollama, full host CPU/RAM, dGPU on amdgpu) is now
# a reboot, not a runtime operation. After the VM stops in vm-mode, the
# launcher only restores per-runtime CPU tunables (governor, IRQ affinity,
# autogroup, AllowedCPUs) so that whatever the user does in the leftover
# vm-mode session uses normal host scheduling. The dGPU stays on vfio-pci
# until the next reboot.

# ============================================================
# Top-level operations
# ============================================================

_do_stop() {
    log "=== Stopping overwatch[$VM_NAME] ==="

    ensure_vm_stopped

    if [ "$GPU_PASSTHROUGH" = "true" ]; then
        # Restore per-runtime CPU tunables (governor, AllowedCPUs, autogroup,
        # C-states, IRQ affinity) so post-VM host work uses normal scheduling.
        # The dGPU stays on vfio-pci — returning to host-mode (amdgpu, ollama)
        # is a reboot, not a runtime op. See header.
        ensure_cpu_defaults
    else
        log "Non-passthrough VM — no host CPU tunables to restore"
    fi

    log "=== Stop complete ($VM_NAME) ==="
}

_do_start() {
    log "=== Starting overwatch[$VM_NAME] ==="

    # Refuse if VM already running
    if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
        log "ERROR: VM is already running. Use 'systemctl stop overwatch@${VM_NAME}.service' to stop it."
        exit 1
    fi

    if [ "$GPU_PASSTHROUGH" = "true" ]; then
        # vm-mode boot precondition check. The host should already be in
        # vm-mode (verified by `overwatch-mode require vm` in ExecStartPre)
        # with the dGPU on vfio-pci from boot. This is a defense-in-depth
        # check: if it fails, something rebound the GPU since boot, or the
        # cmdline marker is missing — refuse to start.
        ensure_vm_mode_ready || { log "ERROR: vm-mode preconditions not met"; exit 1; }
        ensure_vm_running   || { log "ERROR: VM start failed"; _do_stop; exit 1; }
    else
        # Non-passthrough path — no mode check, no host disruption.
        log "Non-passthrough VM — starting without mode gating"
        ensure_vm_running || { log "ERROR: VM start failed"; _do_stop; exit 1; }
    fi

    # Install SIGTERM handler for the wait loop. There is no critical-section
    # GPU handoff anymore, so SIGTERM is always safe to act on immediately.
    _on_sigterm() {
        log "Received SIGTERM (systemctl stop) — shutting down..."
        _do_stop
        exit 0
    }
    trap '_on_sigterm' TERM

    if [ "$GPU_PASSTHROUGH" = "true" ]; then
        # Post-VM-start performance tuning (non-critical, continue on failure)
        ensure_performance_tuning
        apply_sched_fifo
    fi

    log_state "vm_running"
    log "VM running. Waiting for shutdown..."

    local cpu_iso_pid=""
    if [ "$GPU_PASSTHROUGH" = "true" ]; then
        # CPU isolation — deferred until guest agent responds (Windows finished booting).
        # See apply_cpu_isolation() for rationale on why this is not applied immediately.
        apply_cpu_isolation &
        cpu_iso_pid=$!
    fi

    # Tartarus attach + reboot watcher — initial deferred attach + persistent
    # loop that re-fires the attach after every guest reboot (not just at
    # overwatch start). The loop runs for the lifetime of the VM and is
    # killed by the existing cleanup section on real shutdown.
    local VM_START_EPOCH tartarus_pid=""
    VM_START_EPOCH=$(date +%s)
    if [ "$TARTARUS_ATTACH" = "true" ]; then
        tartarus_attach_loop "$VM_START_EPOCH" &
        tartarus_pid=$!
    fi

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

    # Transition throttle event listener -- receives TRANSITION messages from guest script.
    # Only meaningful for passthrough VMs (the throttle script is OW2-specific).
    local transition_pid=""
    if [ "$GPU_PASSTHROUGH" = "true" ]; then
        monitor_transition_events &
        transition_pid=$!
    fi

    # Listen for shutdown signal from guest; record timestamp on receipt.
    # Per-VM ts file so multiple instances don't collide on /tmp.
    local SHUTDOWN_TS_FILE="/tmp/.overwatch-${VM_NAME}-shutdown-ts"
    rm -f "$SHUTDOWN_TS_FILE"
    {
        SHUTDOWN_TS_FILE="$SHUTDOWN_TS_FILE" SHUTDOWN_SIGNAL_PORT="$SHUTDOWN_SIGNAL_PORT" \
        python3 -c "
import os, socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', int(os.environ['SHUTDOWN_SIGNAL_PORT'])))
s.recvfrom(64)
s.close()
open(os.environ['SHUTDOWN_TS_FILE'],'w').write(str(int(time.time())))" \
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
    if [ -f "$SHUTDOWN_TS_FILE" ]; then
        local sig_ts dur
        sig_ts=$(cat "$SHUTDOWN_TS_FILE" 2>/dev/null) || true
        if [ -n "$sig_ts" ]; then
            dur=$(( $(date +%s) - sig_ts ))
            if [ "$dur" -le 300 ]; then
                log "Shutdown duration: ${dur}s (signal to domain-stop)"
            else
                log "WARNING: Shutdown duration ${dur}s exceeds 300s limit"
            fi
        fi
        rm -f "$SHUTDOWN_TS_FILE"
    fi

    # Clean up background jobs (cpu_iso/tartarus/transition may be empty for
    # non-passthrough VMs; _kw skips empty pids cleanly).
    _kw() { [ -n "$1" ] && { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }; }
    _kw "$cpu_iso_pid"
    _kw "$tartarus_pid"
    _kw "$listener_pid"
    _kw "$netmon_pid"
    _kw "$perf_host_pid"
    _kw "$diag_pid"
    _kw "$guest_perf_pid"
    _kw "$pcap_pid"
    _kw "$latency_host_pid"
    _kw "$guest_netmon_pid"
    _kw "$transition_pid"

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
