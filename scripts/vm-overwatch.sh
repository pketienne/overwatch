#!/bin/bash
# vm-overwatch — Declarative state reconciler for GPU passthrough VM lifecycle
# Manages myhost through: host-mode ↔ vfio ↔ vm-running
#
# Subcommands:
#   start   Full lifecycle: prepare host → start VM → wait for shutdown → restore host
#   stop    Inspect current state, do minimum work to reach host-mode (idempotent)
#   status  Print current system state across all dimensions
#
# Runs as a systemd transient service (systemd-run) to survive GDM stop/restart
# Log: journalctl -u vm-overwatch
#
# Usage: vm-overwatch [--verbose] start|stop|status

set -uo pipefail

GPU="0000:03:00.0"
GPU_AUDIO="0000:03:00.1"
IGPU="0000:74:00.0"
HOST_CPU=0          # CPU reserved for host tasks
SHUTDOWN_SIGNAL_PORT=9147   # UDP port for Windows shutdown signal
LOCK_FILE="/run/vm-overwatch.lock"

# USB devices that need detach/reattach after VM start to clear ghost entries
USB_DEVICES=(
    "0x29ea:0x0102:Kinesis Keyboard"
    "0x1532:0x022b:Tartarus V2"
)

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
    echo "Usage: vm-overwatch [--verbose] start|stop|status"
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

# Dump GPU driver and VM state at a named checkpoint
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
        log "ERROR: Another vm-overwatch instance is already running (lock: $LOCK_FILE)"
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
        log "Unbinding GPU from amdgpu..."
        echo "$GPU" > /sys/bus/pci/drivers/amdgpu/unbind
        sleep 2
        log "Unbind completed. GPU driver: $(gpu_driver $GPU)"
    fi

    log_state "post_unbind"
}

ensure_gpu_on_vfio() {
    modprobe vfio-pci 2>/dev/null || true

    if [ "$(gpu_driver $GPU)" = "vfio-pci" ] && [ "$(gpu_driver $GPU_AUDIO)" = "vfio-pci" ]; then
        log "GPU already on vfio-pci — skipping bind"
        return 0
    fi

    log "Binding GPU to vfio-pci..."
    if [ "$(gpu_driver $GPU)" != "vfio-pci" ]; then
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU/driver_override
        echo "$GPU" > /sys/bus/pci/drivers/vfio-pci/bind
    fi
    if [ "$(gpu_driver $GPU_AUDIO)" != "vfio-pci" ]; then
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU_AUDIO/driver_override
        echo "$GPU_AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind
    fi
    sleep 1

    log "GPU driver: $(gpu_driver $GPU)"
    if [ "$(gpu_driver $GPU)" != "vfio-pci" ]; then
        log "ERROR: GPU not on vfio-pci after bind attempt"
        log_state "vfio_bind_failed"
        return 1
    fi
}

ensure_vm_running() {
    if virsh domstate overwatch 2>/dev/null | grep -q "running"; then
        log "ERROR: VM already running"
        return 1
    fi
    log "Starting VM..."
    virsh start overwatch
    log "VM started successfully."
}

# Re-attach USB devices — clears ghost entries from previous VM sessions
ensure_usb_reattached() {
    log "Re-attaching USB devices..."
    for usb_entry in "${USB_DEVICES[@]}"; do
        local usb_vid="${usb_entry%%:*}"
        local usb_rest="${usb_entry#*:}"
        local usb_pid="${usb_rest%%:*}"
        local usb_name="${usb_rest#*:}"
        local usb_xml="<hostdev mode='subsystem' type='usb' managed='yes'><source><vendor id='$usb_vid'/><product id='$usb_pid'/></source></hostdev>"

        # Detach (may fail if not currently attached — that's expected)
        virsh detach-device overwatch /dev/stdin --live <<< "$usb_xml" 2>/dev/null || true
        sleep 2

        # Re-attach (retry once — device may need time to re-enumerate on host bus)
        if virsh attach-device overwatch /dev/stdin --live <<< "$usb_xml" 2>/dev/null; then
            log "Re-attached $usb_name"
        else
            sleep 3
            if virsh attach-device overwatch /dev/stdin --live <<< "$usb_xml" 2>/dev/null; then
                log "Re-attached $usb_name (retry)"
            else
                log "WARNING: Failed to attach $usb_name ($usb_vid:$usb_pid)"
            fi
        fi
    done
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
    # Set CPU governor to performance on all cores
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null || true
    done
    # Pin all IRQs to host CPU so VM cores get no interrupt overhead
    systemctl stop irqbalance 2>/dev/null || true
    for irq_dir in /proc/irq/*/; do
        echo $HOST_CPU > "${irq_dir}smp_affinity_list" 2>/dev/null || true
    done
    # Move RCU callbacks to host CPU
    echo 1 > /sys/bus/workqueue/devices/writeback/cpumask 2>/dev/null || true
}

# --- Guest diagnostics (queries Windows via QEMU guest agent) ---

# Queries three data sources after VM boot:
#   1. Shutdown diagnostics (Event IDs 200-203) — shutdown duration, slow services/drivers
#   2. Recent crash dumps (LiveKernelReports, Minidump) — TDR/BSOD history
#   3. AMD GPU driver version — detect silent Windows Update driver changes
# Prints tagged sections to stdout; caller parses and logs them.
log_guest_diagnostics() {
    python3 << 'PYEOF'
import subprocess, json, base64, time, sys

def qga(payload):
    try:
        r = subprocess.run(
            ["virsh", "qemu-agent-command", "overwatch", json.dumps(payload)],
            capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except Exception:
        return None

def run_ps(cmd):
    result = qga({"execute": "guest-exec", "arguments": {
        "path": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "arg": ["-Command", cmd],
        "capture-output": True}})
    if not result:
        return ""
    pid = result["return"]["pid"]
    time.sleep(5)
    status = qga({"execute": "guest-exec-status", "arguments": {"pid": pid}})
    if not status:
        return ""
    r = status["return"]
    if not r.get("exited"):
        time.sleep(5)
        status = qga({"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if status:
            r = status["return"]
    if r.get("out-data"):
        return base64.b64decode(r["out-data"]).decode().strip()
    return ""

# Wait for guest agent (up to 60s)
for _ in range(30):
    if qga({"execute": "guest-ping"}):
        break
    time.sleep(2)
else:
    sys.exit(0)

# 1. Previous shutdown diagnostics
out = run_ps(
    "$events = Get-WinEvent -FilterHashtable @{"
    "LogName='Microsoft-Windows-Diagnostics-Performance/Operational';"
    "Id=200,201,202,203} -MaxEvents 10 -EA SilentlyContinue; "
    "foreach($e in $events){"
    "$lines = $e.Message.Trim().Split([char]10); "
    "$summary = ($lines | Select-Object -First 3 | "
    "ForEach-Object { $_.Trim() }) -join ' '; "
    "Write-Output(\"$($e.TimeCreated.ToString('HH:mm:ss'))"
    " ID=$($e.Id) $summary\")}"
)
if out:
    print("SHUTDOWN_DIAG")
    print(out)

# 2. Recent TDR/crash events (LiveKernelReports)
out = run_ps(
    "$files = Get-ChildItem "
    "C:\\Windows\\LiveKernelReports\\*\\*.dmp,"
    "C:\\Windows\\Minidump\\*.dmp "
    "-EA SilentlyContinue | Sort-Object LastWriteTime -Descending "
    "| Select-Object -First 5; "
    "foreach($f in $files){"
    "Write-Output(\"$($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    " $([math]::Round($f.Length/1MB,1))MB $($f.Name)\")}"
)
if out:
    print("CRASH_DUMPS")
    print(out)

# 3. AMD GPU driver version
out = run_ps(
    "$d = Get-PnpDevice -Class Display -EA SilentlyContinue "
    "| Where-Object { $_.FriendlyName -like '*AMD*' -or "
    "$_.FriendlyName -like '*Radeon*' } | Select-Object -First 1; "
    "if($d){ $drv = Get-PnpDeviceProperty -InstanceId $d.InstanceId "
    "-KeyName DEVPKEY_Device_DriverVersion -EA SilentlyContinue; "
    "Write-Output(\"$($d.Status) $($d.FriendlyName) v$($drv.Data)\") }"
)
if out:
    print("GPU_DRIVER")
    print(out)
PYEOF
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
        return 0
    fi

    # Bind GPU to amdgpu — this powers up the entire GPU die
    log "Binding to amdgpu..."
    echo "$GPU" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null || true
    sleep 3
    log "GPU driver: $(gpu_driver $GPU)"

    # Disable runtime PM on GPU immediately after bind — amdgpu sets
    # power/control to "auto" during probe, and the GPU crashes on D3 resume.
    # Must happen before audio re-enumeration to prevent cascading failures.
    echo on > "/sys/bus/pci/devices/$GPU/power/control" 2>/dev/null || true

    # GPU audio is often stuck in D3cold after VM passthrough — MODE1 reset
    # only resets the GFX engine, not the audio function. Binding snd_hda_intel
    # to a D3cold device triggers a failed power transition that crashes the
    # entire GPU ("device lost from bus"). Fix: PCI remove + rescan after amdgpu
    # has powered the GPU die, so the audio codec re-enumerates in a clean state.
    if [ -e "/sys/bus/pci/devices/$GPU_AUDIO" ]; then
        log "Re-enumerating GPU audio device..."
        echo 1 > "/sys/bus/pci/devices/$GPU_AUDIO/remove" 2>/dev/null || true
        sleep 1
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
        sleep 2
        # Disable runtime PM on audio immediately — snd_hda_intel puts it
        # into D3hot within seconds, and D3hot→D0 fails after passthrough.
        echo on > "/sys/bus/pci/devices/$GPU_AUDIO/power/control" 2>/dev/null || true
        if [ "$(gpu_driver $GPU_AUDIO)" = "snd_hda_intel" ]; then
            log "GPU audio re-enumerated and auto-probed successfully"
        elif [ -e "/sys/bus/pci/devices/$GPU_AUDIO" ]; then
            log "Binding GPU audio to snd_hda_intel..."
            echo "$GPU_AUDIO" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null || \
                log "WARNING: snd_hda_intel bind failed — HDMI/DP audio unavailable"
            echo on > "/sys/bus/pci/devices/$GPU_AUDIO/power/control" 2>/dev/null || true
        else
            log "WARNING: GPU audio device not found after rescan"
        fi
    fi

    log "Runtime PM disabled for GPU and audio"
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
    ensure_gpu_on_host || log "WARNING: Could not restore GPU to host — iGPU only"
    set_igpu_blank 0 unblank || true
    ensure_services_running

    log "=== Host restored ==="
}

_do_start() {
    log "=== Starting Overwatch VM ==="

    # Refuse if VM already running
    if virsh domstate overwatch 2>/dev/null | grep -q "running"; then
        log "ERROR: VM is already running. Use 'vm-overwatch stop' to stop it."
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
    ensure_usb_reattached
    set_igpu_blank 4 blank || true
    ensure_performance_tuning

    log_state "vm_running"
    log "VM running. Waiting for shutdown..."

    # Query guest diagnostics from Windows in background (non-blocking)
    (
        output=$(log_guest_diagnostics 2>/dev/null) || true
        if [ -n "$output" ]; then
            local section=""
            while IFS= read -r line; do
                case "$line" in
                    SHUTDOWN_DIAG) section="shutdown"; log "Previous shutdown diagnostics (Windows Event Log):" ;;
                    CRASH_DUMPS)   section="crashes";  log "Recent crash dumps:" ;;
                    GPU_DRIVER)    section="driver";   log "GPU driver:" ;;
                    "") ;;
                    *) log "  $line" ;;
                esac
            done <<< "$output"
        fi
    ) &
    local diag_pid=$!

    # Listen for shutdown signal from guest (user clicks "Shutdown VM" shortcut)
    local shutdown_ts_file="/tmp/.vm-overwatch-shutdown-ts"
    rm -f "$shutdown_ts_file"
    python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', ${SHUTDOWN_SIGNAL_PORT}))
s.recvfrom(64)
s.close()
open('${shutdown_ts_file}', 'w').write(str(int(time.time())))
" &>/dev/null &
    local listener_pid=$!

    # Wait for VM to shut down — instrumented with QEMU process state tracking
    # Accept definitive non-running state OR domain-not-found (libvirtd lost track).
    # Transient empty output (libvirtd hiccup) is treated as "keep waiting".
    # QEMU state transitions are only logged after the shutdown signal to avoid noise.
    local qemu_pid domain_missing=0 prev_pstate=""
    qemu_pid=$(pgrep -f "guest=overwatch" 2>/dev/null) || true
    while true; do
        local vm_poll pstate
        vm_poll=$(virsh domstate overwatch 2>&1) || true

        # Track QEMU process state transitions, but only after shutdown signal
        if [ -f "$shutdown_ts_file" ] && [ -n "$qemu_pid" ]; then
            if [ -d "/proc/$qemu_pid" ]; then
                pstate=$(sed -n 's/^State:\t\(.\).*/\1/p' "/proc/$qemu_pid/status" 2>/dev/null) || pstate="?"
            else
                pstate="exited"
            fi
            if [ -n "$prev_pstate" ] && [ "$pstate" != "$prev_pstate" ]; then
                log "Shutdown: QEMU process state $prev_pstate → $pstate"
            fi
            prev_pstate=$pstate
        fi

        if echo "$vm_poll" | grep -q "failed to get domain"; then
            domain_missing=$((domain_missing + 1))
            if [ $domain_missing -ge 3 ]; then
                log "WARNING: Domain not found in libvirt (QEMU orphaned?) — treating as shutdown"
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
    # Clean up listener and diagnostics background job
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    kill "$diag_pid" 2>/dev/null || true
    wait "$diag_pid" 2>/dev/null || true

    log "VM shut down detected."
    if [ -f "$shutdown_ts_file" ]; then
        local initiated completed delta
        initiated=$(cat "$shutdown_ts_file")
        completed=$(date +%s)
        delta=$((completed - initiated))
        # Ignore stale timestamps (e.g. from test runs) — must be within 5 min
        if [ $delta -le 300 ]; then
            log "Shutdown took ${delta}s (from shutdown signal to VM stop)"
        else
            log "Shutdown signal was stale (${delta}s ago) — ignoring"
        fi
        rm -f "$shutdown_ts_file"
    fi
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
