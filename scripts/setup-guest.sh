#!/bin/bash
# setup-guest — Configure Windows guest via QEMU guest agent
# Automates Phases 10-14 from tasks/gpu-passthrough/recipe/configure.md
# Phase 9 (Windows/driver/game install) remains manual.
#
# Prerequisite: VM running with guest agent installed and active.
#
# Subcommands:
#   all        Run all guest configuration steps in order
#   power      Phase 10: Power plan, ASPM, sleep, AMD driver PM
#   hda-audio  Phase 11: Remove AMD HD Audio driver from driver store
#   defender   Phase 12: Defender exclusions for AMD driver paths
#   telemetry  Phase 12: Disable AMD telemetry (AUEPMaster)
#   display    Phase 13: Auto HDR off, Game Bar off, toast off
#   shutdown   Phase 14: Install shutdown signal script and scheduled task
#   verify     Query all settings and report current vs expected
#
# Usage: setup-guest [--dry-run] [--verbose] <subcommand>

set -uo pipefail

# --- Constants ---

VM_NAME="overwatch"
HOST_IP="192.168.0.100"
SHUTDOWN_SIGNAL_PORT=9147

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
    echo "Usage: setup-guest [--dry-run] [--verbose] <subcommand>"
    echo ""
    echo "  all        Run all guest configuration steps"
    echo "  power      Phase 10: Power plan, ASPM, sleep, AMD driver PM"
    echo "  hda-audio  Phase 11: Remove AMD HD Audio driver"
    echo "  defender   Phase 12: Defender exclusions for AMD driver paths"
    echo "  telemetry  Phase 12: Disable AMD telemetry (AUEPMaster)"
    echo "  display    Phase 13: Auto HDR off, Game Bar off, toast off"
    echo "  shutdown   Phase 14: Shutdown signal script and scheduled task"
    echo "  verify     Query all settings and report status"
    exit 1
fi

# --- Guest agent check ---

ensure_guest_agent() {
    local vm_state
    vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null) || true
    if ! echo "$vm_state" | grep -q "running"; then
        log "ERROR: VM '$VM_NAME' is not running (state: ${vm_state:-unknown})"
        log "Start the VM and ensure the guest agent is installed before running this script"
        return 1
    fi
    if ! virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' &>/dev/null; then
        log "ERROR: Guest agent not responding on VM '$VM_NAME'"
        log "Ensure qemu-guest-agent is installed and running in the Windows guest"
        return 1
    fi
    log "Guest agent: connected"
}

# --- Python helper ---

# Run Python code with guest agent helpers pre-loaded.
# Phase-specific code is read from stdin (use a quoted heredoc).
# The preamble provides: log(), qga(), run_ps(), guest_file_write(),
# plus VM, HOST_IP, SHUTDOWN_PORT, DRY_RUN variables.
guest_python() {
    local tmpf
    tmpf=$(mktemp /tmp/setup-guest-XXXXXX.py)
    local dry_run_val
    [ "$DRY_RUN" = true ] && dry_run_val="True" || dry_run_val="False"

    # Preamble: variables (bash-substituted)
    cat > "$tmpf" <<ENDVARS
import subprocess, json, base64, time, sys, datetime

VM = "${VM_NAME}"
HOST_IP = "${HOST_IP}"
SHUTDOWN_PORT = ${SHUTDOWN_SIGNAL_PORT}
DRY_RUN = ${dry_run_val}
ENDVARS

    # Preamble: helpers (no bash substitution)
    cat >> "$tmpf" << 'ENDHELPERS'

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    print(f"{ts}   {msg}", flush=True)

def qga(payload):
    try:
        r = subprocess.run(
            ["virsh", "qemu-agent-command", VM, json.dumps(payload)],
            capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except Exception:
        return None

def run_ps(cmd):
    """Execute PowerShell command on guest, return stdout."""
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
        time.sleep(10)
        status = qga({"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if status:
            r = status["return"]
    if r.get("out-data"):
        return base64.b64decode(r["out-data"]).decode().strip()
    return ""

def guest_file_write(path, content):
    """Write a file on the guest via guest-file-* API."""
    result = qga({"execute": "guest-file-open", "arguments": {
        "path": path, "mode": "wb"}})
    if not result:
        log(f"ERROR: Could not open {path} for writing")
        return False
    handle = result["return"]
    if isinstance(content, str):
        content = content.encode("utf-8")
    encoded = base64.b64encode(content).decode()
    qga({"execute": "guest-file-write", "arguments": {
        "handle": handle, "buf-b64": encoded}})
    qga({"execute": "guest-file-flush", "arguments": {"handle": handle}})
    qga({"execute": "guest-file-close", "arguments": {"handle": handle}})
    return True

ENDHELPERS

    # Append phase-specific code from stdin
    cat >> "$tmpf"

    python3 "$tmpf"
    local rc=$?
    rm -f "$tmpf"
    return $rc
}

# ============================================================
# Phase 10: Power settings & AMD driver tuning
# ============================================================

ensure_power_settings() {
    log "=== Phase 10: Power settings ==="
    guest_python << 'PYEOF'
# --- Power plan ---
out = run_ps("powercfg /getactivescheme")
hp_guid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
if hp_guid in (out or ""):
    log("Power plan: already High Performance")
else:
    log(f"Power plan: {out or 'unknown'}")
    if DRY_RUN:
        log("[dry-run] Would switch to High Performance")
    else:
        run_ps("powercfg /setactive " + hp_guid)
        log("Switched to High Performance")

# --- Power settings (idempotent, always apply) ---
if DRY_RUN:
    log("[dry-run] Would apply power settings (ASPM off, USB suspend off, no sleep)")
else:
    run_ps(
        # PCI Express ASPM off
        "powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0; "
        "powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0; "
        # USB selective suspend off
        "powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0; "
        "powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0; "
        # Display timeout never
        "powercfg /setacvalueindex SCHEME_CURRENT 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0; "
        "powercfg /setdcvalueindex SCHEME_CURRENT 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0; "
        # Sleep never
        "powercfg /setacvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0; "
        "powercfg /setdcvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0; "
        # Hybrid sleep off
        "powercfg /setacvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0; "
        "powercfg /setdcvalueindex SCHEME_CURRENT 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0; "
        # Apply
        "powercfg /setactive SCHEME_CURRENT"
    )
    log("Power settings applied (ASPM off, USB suspend off, display/sleep never, hybrid sleep off)")

# --- AMD driver internal power management ---
# Find AMD GPU registry index (don't hardcode \0001)
display_class = r"HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
out = run_ps(
    "$base = '" + display_class + "'; "
    "for($i=0; $i -le 9; $i++){ "
    "  $path = \"$base\\$('{0:D4}' -f $i)\"; "
    "  $desc = (Get-ItemProperty -Path $path -Name DriverDesc -EA SilentlyContinue).DriverDesc; "
    "  if($desc -like '*AMD*' -or $desc -like '*Radeon*'){ "
    "    Write-Output('{0:D4}' -f $i); break "
    "  } "
    "}"
)
if not out:
    log("WARNING: AMD GPU driver not found in registry — skipping driver PM settings")
else:
    amd_idx = out.strip()
    regpath = display_class + "\\" + amd_idx
    log(f"AMD GPU driver at registry index {amd_idx}")

    # Check current values
    vals = run_ps(
        "$p = '" + regpath + "'; "
        "$ulps = (Get-ItemProperty -Path $p -Name EnableUlps -EA SilentlyContinue).EnableUlps; "
        "$sclk = (Get-ItemProperty -Path $p -Name PP_SclkDeepSleepDisable -EA SilentlyContinue).PP_SclkDeepSleepDisable; "
        "$drm = (Get-ItemProperty -Path $p -Name DisableDrmdmaPowerOff -EA SilentlyContinue).DisableDrmdmaPowerOff; "
        "Write-Output \"$ulps|$sclk|$drm\""
    )
    parts = (vals or "||").split("|")
    ulps, sclk, drm = parts[0].strip(), parts[1].strip(), parts[2].strip()

    if ulps == "0" and sclk == "1" and drm == "1":
        log("AMD driver PM: already configured (EnableUlps=0, SclkDeepSleep=1, DrmdmaPowerOff=1)")
    else:
        log(f"AMD driver PM: EnableUlps={ulps}, SclkDeepSleep={sclk}, DrmdmaPowerOff={drm}")
        if DRY_RUN:
            log("[dry-run] Would set EnableUlps=0, PP_SclkDeepSleepDisable=1, DisableDrmdmaPowerOff=1")
        else:
            run_ps(
                "$p = '" + regpath + "'; "
                "Set-ItemProperty -Path $p -Name EnableUlps -Value 0; "
                "Set-ItemProperty -Path $p -Name PP_SclkDeepSleepDisable -Value 1; "
                "Set-ItemProperty -Path $p -Name DisableDrmdmaPowerOff -Value 1"
            )
            log("AMD driver PM disabled")
PYEOF
}

# ============================================================
# Phase 11: GPU HDA Audio driver removal
# ============================================================

ensure_hda_audio() {
    log "=== Phase 11: HDA Audio ==="
    guest_python << 'PYEOF'
import re

# Check if AtiHDAudioService driver is in the driver store
out = run_ps(
    "$drv = pnputil /enum-drivers /class MEDIA 2>&1 "
    "| Select-String 'oem.*\\.inf|AtiHDAudio|Provider.*AMD'; "
    "if($drv){ ($drv | ForEach-Object { $_.Line.Trim() }) -join '|' } "
    "else { 'NOT_FOUND' }"
)

if "NOT_FOUND" in (out or "NOT_FOUND"):
    log("AtiHDAudioService not in driver store — already removed")
else:
    log(f"Found AMD HD Audio driver: {out}")
    oem_match = re.search(r'(oem\d+\.inf)', out or "", re.IGNORECASE)
    if not oem_match:
        log("WARNING: Could not extract OEM inf name — manual removal required")
        sys.exit(1)

    oem_inf = oem_match.group(1)
    log(f"Driver package: {oem_inf}")

    # Find the device instance ID
    dev_out = run_ps(
        "$dev = Get-PnpDevice -EA SilentlyContinue "
        "| Where-Object InstanceId -like 'HDAUDIO*VEN_1002*' "
        "| Select-Object -First 1; "
        "if($dev){ $dev.InstanceId } else { 'NONE' }"
    )

    if DRY_RUN:
        if dev_out and dev_out != "NONE":
            log(f"[dry-run] Would remove device {dev_out}")
        log(f"[dry-run] Would delete driver {oem_inf} from store")
    else:
        if dev_out and dev_out != "NONE":
            run_ps('pnputil /remove-device "' + dev_out + '"')
            log(f"Removed device {dev_out}")
        run_ps("pnputil /delete-driver " + oem_inf + " /force")
        log(f"Deleted {oem_inf} from driver store")
PYEOF
}

# ============================================================
# Phase 12: Defender exclusions
# ============================================================

ensure_defender_exclusions() {
    log "=== Phase 12: Defender exclusions ==="
    guest_python << 'PYEOF'
# Check current exclusions
out = run_ps(
    "$prefs = Get-MpPreference -EA SilentlyContinue; "
    "$paths = @($prefs.ExclusionPath) -join '|'; "
    "$procs = @($prefs.ExclusionProcess) -join '|'; "
    "Write-Output \"PATHS:$paths\"; "
    "Write-Output \"PROCS:$procs\""
)

current_paths = ""
current_procs = ""
for line in (out or "").splitlines():
    if line.startswith("PATHS:"):
        current_paths = line[6:]
    elif line.startswith("PROCS:"):
        current_procs = line[6:]

needed_paths = [
    r"C:\Program Files\AMD",
    r"C:\Windows\System32\amd*",
    r"C:\Windows\SysWOW64\amd*",
    r"C:\Windows\System32\ati*",
    r"C:\Windows\SysWOW64\ati*",
    r"C:\Windows\System32\drivers\amd*",
    r"C:\Windows\System32\DriverStore\FileRepository\u0*",
]
needed_procs = [
    "amdfendrsr.exe", "atiesrxx.exe", "atieclxx.exe",
    "RadeonSoftware.exe", "AMDRSServ.exe", "AMDRSSrcExt.exe",
    "amdow.exe", "cncmd.exe", "CPUMetricsServer.exe",
]

missing_paths = [p for p in needed_paths if p not in current_paths]
missing_procs = [p for p in needed_procs if p.lower() not in current_procs.lower()]

if not missing_paths and not missing_procs:
    log("Defender exclusions: all present")
else:
    if missing_paths:
        log(f"Missing path exclusions: {len(missing_paths)}")
    if missing_procs:
        log(f"Missing process exclusions: {len(missing_procs)}")

    if DRY_RUN:
        log(f"[dry-run] Would add {len(missing_paths)} path + {len(missing_procs)} process exclusions")
    else:
        # Add-MpPreference is additive and idempotent — safe to re-add all
        path_list = ",".join("'" + p + "'" for p in needed_paths)
        proc_list = ",".join("'" + p + "'" for p in needed_procs)
        run_ps(
            "@(" + path_list + ") | ForEach-Object { Add-MpPreference -ExclusionPath $_ }; "
            "@(" + proc_list + ") | ForEach-Object { Add-MpPreference -ExclusionProcess $_ }"
        )
        log("Defender exclusions applied")
PYEOF
}

# ============================================================
# Phase 12: AMD telemetry
# ============================================================

ensure_telemetry_disabled() {
    log "=== Phase 12: AMD telemetry ==="
    guest_python << 'PYEOF'
# Check AUEPLauncher service
svc_out = run_ps(
    "$svc = Get-Service AUEPLauncher -EA SilentlyContinue; "
    "if($svc){ Write-Output \"$($svc.StartType)|$($svc.Status)\" } "
    "else { Write-Output 'NOT_FOUND' }"
)

# Check StartAUEP task
task_out = run_ps(
    "$t = Get-ScheduledTask -TaskName StartAUEP -EA SilentlyContinue; "
    "if($t){ $t.State } else { 'NOT_FOUND' }"
)

svc_ok = "NOT_FOUND" in (svc_out or "") or "Disabled" in (svc_out or "")
task_ok = "NOT_FOUND" in (task_out or "") or "Disabled" in (task_out or "")

if svc_ok and task_ok:
    log(f"AMD telemetry: already disabled (service={svc_out}, task={task_out})")
else:
    log(f"AMD telemetry: service={svc_out}, task={task_out}")
    if DRY_RUN:
        log("[dry-run] Would disable AUEPLauncher service and StartAUEP task")
    else:
        run_ps(
            "sc.exe config AUEPLauncher start=disabled; "
            "Stop-Service AUEPLauncher -EA SilentlyContinue; "
            "Disable-ScheduledTask -TaskName StartAUEP -EA SilentlyContinue"
        )
        log("AMD telemetry disabled (AUEPLauncher service + StartAUEP task)")
PYEOF
}

# ============================================================
# Phase 13: Display configuration
# ============================================================

ensure_display_config() {
    log "=== Phase 13: Display configuration ==="
    guest_python << 'PYEOF'
# Find the logged-in user's SID for HKU registry access
sid_out = run_ps(
    "$p = Get-CimInstance Win32_UserProfile "
    "| Where-Object { -not $_.Special -and $_.Loaded } "
    "| Select-Object -First 1; "
    "if($p){ $p.SID } else { 'NONE' }"
)
if not sid_out or sid_out == "NONE":
    log("WARNING: No loaded user profile found — skipping per-user display settings")
    log("Log in to the Windows guest interactively, then re-run")
    sys.exit(1)

sid = sid_out.strip()
log(f"User SID: {sid}")

if DRY_RUN:
    log("[dry-run] Would configure: Auto HDR off, Game Bar off, toast off")
else:
    # Auto HDR off (per-user)
    run_ps(
        "$dxPath = \"Registry::HKEY_USERS\\" + sid + "\\SOFTWARE\\Microsoft\\DirectX\\UserGpuPreferences\"; "
        "if(-not (Test-Path $dxPath)){ New-Item -Path $dxPath -Force | Out-Null }; "
        "Set-ItemProperty -Path $dxPath -Name 'DirectXUserGlobalSettings' "
        "-Value 'SwapEffectUpgradeEnable=1;AutoHDREnable=0;' -Type String"
    )
    log("Auto HDR: disabled (global)")

    # Game Bar off (machine policy + per-user)
    run_ps(
        "New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\GameDVR' -Force | Out-Null; "
        "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord; "
        "$gbPath = \"Registry::HKEY_USERS\\" + sid + "\\SOFTWARE\\Microsoft\\GameBar\"; "
        "if(-not (Test-Path $gbPath)){ New-Item -Path $gbPath -Force | Out-Null }; "
        "Set-ItemProperty -Path $gbPath -Name 'UseNexusForGameBarEnabled' -Value 0 -Type DWord; "
        "$gdvrPath = \"Registry::HKEY_USERS\\" + sid + "\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\GameDVR\"; "
        "if(-not (Test-Path $gdvrPath)){ New-Item -Path $gdvrPath -Force | Out-Null }; "
        "Set-ItemProperty -Path $gdvrPath -Name 'AppCaptureEnabled' -Value 0 -Type DWord"
    )
    log("Game Bar: disabled (policy + user settings)")

    # Auto HDR toast notification off (per-user)
    run_ps(
        "$toastPath = \"Registry::HKEY_USERS\\" + sid + "\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion"
        "\\Notifications\\Settings\\Windows.SystemToast.Graphics.AutoHDR\"; "
        "New-Item -Path $toastPath -Force | Out-Null; "
        "Set-ItemProperty -Path $toastPath -Name 'Enabled' -Value 0 -Type DWord"
    )
    log("Auto HDR toast: disabled")
PYEOF
}

# ============================================================
# Phase 14: Shutdown signal
# ============================================================

ensure_shutdown_signal() {
    log "=== Phase 14: Shutdown signal ==="
    guest_python << 'PYEOF'
# Check if script already exists
out = run_ps(
    r"if(Test-Path 'C:\ProgramData\overwatch\overwatch.ps1'){ 'EXISTS' } else { 'MISSING' }"
)
script_exists = "EXISTS" in (out or "")

# Check if scheduled task exists
task_out = run_ps(
    "$t = Get-ScheduledTask -TaskName NotifyHostShutdown -EA SilentlyContinue; "
    "if($t){ $t.State } else { 'MISSING' }"
)
task_exists = "MISSING" not in (task_out or "MISSING")

if script_exists and task_exists:
    log(f"Shutdown signal: already configured (task={task_out})")
    log("To reinstall, delete C:\\ProgramData\\overwatch\\overwatch.ps1 on guest and re-run")
    sys.exit(0)

if DRY_RUN:
    if not script_exists:
        log("[dry-run] Would write C:\\ProgramData\\overwatch\\overwatch.ps1")
    if not task_exists:
        log("[dry-run] Would create NotifyHostShutdown scheduled task (Event ID 1074 trigger)")
    sys.exit(0)

# Create directory
run_ps(r"New-Item -ItemType Directory -Path 'C:\ProgramData\overwatch' -Force | Out-Null")

# Write overwatch.ps1 via guest-file API (avoids PowerShell quoting issues)
ps1_content = (
    "$udp = New-Object System.Net.Sockets.UdpClient\r\n"
    '$bytes = [System.Text.Encoding]::ASCII.GetBytes("shutdown")\r\n'
    "$udp.Send($bytes, $bytes.Length, \""
    + HOST_IP + "\", " + str(SHUTDOWN_PORT) + ")\r\n"
    "$udp.Close()\r\n"
)
if guest_file_write(r"C:\ProgramData\overwatch\overwatch.ps1", ps1_content):
    log("Wrote overwatch.ps1")
else:
    log("ERROR: Failed to write overwatch.ps1")
    sys.exit(1)

# Write task XML via guest-file API, then import with schtasks
task_xml = (
    '<?xml version="1.0"?>\r\n'
    '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">\r\n'
    '  <Triggers>\r\n'
    '    <EventTrigger>\r\n'
    '      <Subscription>&lt;QueryList&gt;&lt;Query Id="0"&gt;&lt;Select Path="System"&gt;'
    '*[System[EventID=1074]]'
    '&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>\r\n'
    '    </EventTrigger>\r\n'
    '  </Triggers>\r\n'
    '  <Actions>\r\n'
    '    <Exec>\r\n'
    '      <Command>powershell.exe</Command>\r\n'
    '      <Arguments>-NoProfile -ExecutionPolicy Bypass -File '
    'C:\\ProgramData\\overwatch\\overwatch.ps1</Arguments>\r\n'
    '    </Exec>\r\n'
    '  </Actions>\r\n'
    '  <Principals>\r\n'
    '    <Principal>\r\n'
    '      <UserId>S-1-5-18</UserId>\r\n'
    '      <RunLevel>HighestAvailable</RunLevel>\r\n'
    '    </Principal>\r\n'
    '  </Principals>\r\n'
    '  <Settings>\r\n'
    '    <Enabled>true</Enabled>\r\n'
    '    <AllowStartIfOnBatteries>true</AllowStartIfOnBatteries>\r\n'
    '  </Settings>\r\n'
    '</Task>\r\n'
)
guest_file_write(r"C:\ProgramData\overwatch\task.xml", task_xml)
out = run_ps(
    r"schtasks /Create /TN 'NotifyHostShutdown' /XML 'C:\ProgramData\overwatch\task.xml' /F 2>&1"
)
run_ps(r"Remove-Item 'C:\ProgramData\overwatch\task.xml' -EA SilentlyContinue")

if out and "SUCCESS" in out.upper():
    log("Created NotifyHostShutdown scheduled task (triggers on Event ID 1074)")
elif out and "ERROR" in out.upper():
    log(f"WARNING: schtasks returned: {out}")
    log("Fallback: create the task manually via Task Scheduler GUI")
else:
    log("Created NotifyHostShutdown scheduled task")
PYEOF
}

# ============================================================
# Verify all guest settings
# ============================================================

verify_guest() {
    log "=== Verify: Guest configuration ==="
    guest_python << 'PYEOF'
ok = True

# --- Power plan ---
out = run_ps("powercfg /getactivescheme")
hp_guid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
if hp_guid in (out or ""):
    log("Power plan: High Performance")
else:
    log(f"Power plan: {out or 'unknown'} (expected High Performance)")
    ok = False

# --- AMD driver PM ---
display_class = r"HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
idx_out = run_ps(
    "$base = '" + display_class + "'; "
    "for($i=0; $i -le 9; $i++){ "
    "  $path = \"$base\\$('{0:D4}' -f $i)\"; "
    "  $desc = (Get-ItemProperty -Path $path -Name DriverDesc -EA SilentlyContinue).DriverDesc; "
    "  if($desc -like '*AMD*' -or $desc -like '*Radeon*'){ "
    "    Write-Output('{0:D4}' -f $i); break "
    "  } "
    "}"
)
if idx_out:
    regpath = display_class + "\\" + idx_out.strip()
    vals = run_ps(
        "$p = '" + regpath + "'; "
        "$ulps = (Get-ItemProperty -Path $p -Name EnableUlps -EA SilentlyContinue).EnableUlps; "
        "$sclk = (Get-ItemProperty -Path $p -Name PP_SclkDeepSleepDisable -EA SilentlyContinue).PP_SclkDeepSleepDisable; "
        "$drm = (Get-ItemProperty -Path $p -Name DisableDrmdmaPowerOff -EA SilentlyContinue).DisableDrmdmaPowerOff; "
        "Write-Output \"$ulps|$sclk|$drm\""
    )
    parts = (vals or "||").split("|")
    if parts[0].strip() == "0" and parts[1].strip() == "1" and parts[2].strip() == "1":
        log(f"AMD driver PM: OK (index {idx_out.strip()})")
    else:
        log(f"AMD driver PM: EnableUlps={parts[0]}, SclkDeepSleep={parts[1]}, DrmdmaPowerOff={parts[2]}")
        ok = False
else:
    log("AMD GPU driver: not found in registry")
    ok = False

# --- HDA Audio ---
out = run_ps(
    "$drv = pnputil /enum-drivers /class MEDIA 2>&1 "
    "| Select-String 'AtiHDAudio'; "
    "if($drv){ 'PRESENT' } else { 'REMOVED' }"
)
if "REMOVED" in (out or "REMOVED"):
    log("HDA Audio: AtiHDAudioService removed from driver store")
else:
    log("HDA Audio: AtiHDAudioService still present")
    ok = False

# --- Defender exclusions ---
out = run_ps(
    "$prefs = Get-MpPreference -EA SilentlyContinue; "
    "$pc = @($prefs.ExclusionPath).Count; "
    "$rc = @($prefs.ExclusionProcess).Count; "
    "Write-Output \"$pc|$rc\""
)
parts = (out or "0|0").split("|")
path_count = int(parts[0].strip() or "0")
proc_count = int(parts[1].strip() or "0")
if path_count >= 7 and proc_count >= 9:
    log(f"Defender exclusions: {path_count} paths, {proc_count} processes")
else:
    log(f"Defender exclusions: {path_count} paths, {proc_count} processes (expected >=7 paths, >=9 processes)")
    ok = False

# --- AMD telemetry ---
svc_out = run_ps(
    "$svc = Get-Service AUEPLauncher -EA SilentlyContinue; "
    "if($svc){ $svc.StartType } else { 'NotFound' }"
)
task_out = run_ps(
    "$t = Get-ScheduledTask -TaskName StartAUEP -EA SilentlyContinue; "
    "if($t){ $t.State } else { 'NotFound' }"
)
svc_disabled = "Disabled" in (svc_out or "") or "NotFound" in (svc_out or "")
task_disabled = "Disabled" in (task_out or "") or "NotFound" in (task_out or "")
if svc_disabled and task_disabled:
    log(f"AMD telemetry: disabled (service={svc_out}, task={task_out})")
else:
    log(f"AMD telemetry: service={svc_out}, task={task_out}")
    ok = False

# --- Display config ---
sid_out = run_ps(
    "$p = Get-CimInstance Win32_UserProfile "
    "| Where-Object { -not $_.Special -and $_.Loaded } "
    "| Select-Object -First 1; "
    "if($p){ $p.SID } else { 'NONE' }"
)
if sid_out and sid_out != "NONE":
    sid = sid_out.strip()
    # Auto HDR
    out = run_ps(
        "$dxPath = \"Registry::HKEY_USERS\\" + sid + "\\SOFTWARE\\Microsoft\\DirectX\\UserGpuPreferences\"; "
        "(Get-ItemProperty -Path $dxPath -Name DirectXUserGlobalSettings -EA SilentlyContinue).DirectXUserGlobalSettings"
    )
    if "AutoHDREnable=0" in (out or ""):
        log("Auto HDR: disabled")
    else:
        log(f"Auto HDR: {out or 'not configured'}")
        ok = False

    # Game Bar
    out = run_ps(
        "$v = (Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\GameDVR' "
        "-Name AllowGameDVR -EA SilentlyContinue).AllowGameDVR; "
        "Write-Output $v"
    )
    if (out or "").strip() == "0":
        log("Game Bar: disabled (policy)")
    else:
        log(f"Game Bar policy: AllowGameDVR={out or 'not set'}")
        ok = False
else:
    log("Display config: no loaded user profile — cannot verify per-user settings")
    ok = False

# --- Shutdown signal ---
out = run_ps(
    r"if(Test-Path 'C:\ProgramData\overwatch\overwatch.ps1'){ 'EXISTS' } else { 'MISSING' }"
)
if "EXISTS" in (out or ""):
    log("Shutdown script: installed")
else:
    log("Shutdown script: missing")
    ok = False

task_out = run_ps(
    "$t = Get-ScheduledTask -TaskName NotifyHostShutdown -EA SilentlyContinue; "
    "if($t){ $t.State } else { 'MISSING' }"
)
if "MISSING" not in (task_out or "MISSING"):
    log(f"Shutdown task: {task_out}")
else:
    log("Shutdown task: not registered")
    ok = False

# --- Summary ---
if ok:
    log("All checks passed")
else:
    log("Some checks failed — review above and re-run relevant subcommands")
PYEOF
}

# ============================================================
# Main dispatch
# ============================================================

do_all() {
    ensure_power_settings
    ensure_hda_audio
    ensure_defender_exclusions
    ensure_telemetry_disabled
    ensure_display_config
    ensure_shutdown_signal
    log "=== Guest configuration complete ==="
}

case "$CMD" in
    all|power|hda-audio|defender|telemetry|display|shutdown)
        ensure_guest_agent
        ;;&
    all)       do_all ;;
    power)     ensure_power_settings ;;
    hda-audio) ensure_hda_audio ;;
    defender)  ensure_defender_exclusions ;;
    telemetry) ensure_telemetry_disabled ;;
    display)   ensure_display_config ;;
    shutdown)  ensure_shutdown_signal ;;
    verify)    ensure_guest_agent && verify_guest ;;
    *)
        log "ERROR: Unknown subcommand '$CMD'"
        exit 1
        ;;
esac
