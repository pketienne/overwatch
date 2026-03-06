# transition-throttle.ps1 — OW2 transition freeze mitigation
#
# Monitors OW2's GPU utilization via Windows GPU Engine performance counters.
# When a loading screen is detected (GPU drops below threshold), proactively
# throttles OW2's CPU affinity to reduce GPU command submission rate, preventing
# the VFIO TDR burst that causes "Rendering Device Lost" / screen freezes.
#
# State machine: IDLE → STEADY → LOADING → THROTTLED → STEADY
#
# Deploy: C:\Scripts\transition-throttle.ps1
# Task Scheduler: AtLogon, user myuser, Interactive, Highest, indefinite
#
# Setup (run once from host via guest agent or on guest as admin):
#   $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
#     -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Scripts\transition-throttle.ps1'
#   $trigger = New-ScheduledTaskTrigger -AtLogon -User 'myuser'
#   $principal = New-ScheduledTaskPrincipal -UserId 'myuser' -LogonType Interactive -RunLevel Highest
#   $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
#     -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1)) -AllowStartIfOnBatteries
#   Register-ScheduledTask -TaskName 'OW2 Transition Throttle' -Action $action `
#     -Trigger $trigger -Principal $principal -Settings $settings

# --- Hotkey (ScrollLock toggle) ---
Add-Type -TypeDefinition 'using System.Runtime.InteropServices;
public class User32 {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}'
$VK_SCROLL = 0x91

function Test-HotkeyPressed {
    ([User32]::GetAsyncKeyState($VK_SCROLL) -band 0x0001) -ne 0
}

# --- Configuration ---
$POLL_IDLE_MS      = 2000    # Poll interval when OW2 not running
$POLL_ACTIVE_MS    = 500     # Poll interval during gameplay
$THROTTLE_SECS     = 15      # Max duration of throttle before auto-restore
$GPU_LOW           = 15      # Below this = loading screen
$LOADING_HOLD_MS   = 1000    # GPU must stay below GPU_LOW for this long before throttle
$FULL_AFFINITY     = 0x3F    # All 6 vCPUs (bits 0-5)
$THROTTLE_AFFINITY = 0x3     # vCPUs 0-1 only
$HOST_IP           = '192.168.0.100'
$HOST_PORT         = 9148

# --- Single-instance mutex ---
$mtx = New-Object System.Threading.Mutex($false, 'Global\TransitionThrottle')
if (-not $mtx.WaitOne(0)) {
    exit 0
}

# --- UDP sender ---
$udp = New-Object System.Net.Sockets.UdpClient
$endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($HOST_IP), $HOST_PORT)

function Send-Log($msg) {
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("TRANSITION $msg")
        $udp.Send($bytes, $bytes.Length, $endpoint) | Out-Null
    } catch {}
}

# --- GPU counter reader ---
function Get-OW2GpuUtil($pid) {
    try {
        $samples = (Get-Counter "\GPU Engine(pid_${pid}_*engtype_3D)\Utilization Percentage" -ErrorAction Stop).CounterSamples
        $max = ($samples | Measure-Object -Property CookedValue -Maximum).Maximum
        [math]::Round($max, 1)
    } catch {
        -1
    }
}

# --- Throttle/restore ---
function Set-Throttle($proc) {
    try {
        $proc.ProcessorAffinity = [IntPtr]$THROTTLE_AFFINITY
        $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    } catch {}
}

function Set-Restore($proc) {
    try {
        $proc.ProcessorAffinity = [IntPtr]$FULL_AFFINITY
        $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    } catch {}
}

# --- Main loop ---
try {
    Send-Log 'started'

    while ($true) {
        # IDLE: wait for OW2
        $ow2 = $null
        while (-not $ow2) {
            $ow2 = Get-Process -Name 'Overwatch' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $ow2) {
                Start-Sleep -Milliseconds $POLL_IDLE_MS
            }
        }

        $ow2pid = $ow2.Id
        Send-Log "ow2_detected pid=$ow2pid"

        $state = 'STEADY'
        $loadingStart = $null
        $throttleStart = $null
        $manualOverride = $false

        try {
            # Active loop while OW2 is running
            while (-not $ow2.HasExited) {
                $ow2.Refresh()
                if ($ow2.HasExited) { break }

                # --- Hotkey toggle ---
                if (Test-HotkeyPressed) {
                    if ($state -ne 'THROTTLED') {
                        Send-Log 'manual_throttle_on'
                        Set-Throttle $ow2
                        $throttleStart = [DateTime]::UtcNow
                        $manualOverride = $true
                        $state = 'THROTTLED'
                    } else {
                        $elapsed = ([DateTime]::UtcNow - $throttleStart).TotalSeconds
                        $duration = [math]::Round($elapsed, 1)
                        Set-Restore $ow2
                        Send-Log "manual_throttle_off duration=${duration}s"
                        $state = 'STEADY'
                        $throttleStart = $null
                        $manualOverride = $false
                    }
                }

                $gpu = Get-OW2GpuUtil $ow2pid

                switch ($state) {
                    'STEADY' {
                        if ($gpu -ge 0 -and $gpu -lt $GPU_LOW) {
                            $loadingStart = [DateTime]::UtcNow
                            $state = 'LOADING'
                        }
                    }
                    'LOADING' {
                        if ($gpu -ge $GPU_LOW) {
                            # GPU recovered before hold time — false alarm
                            $state = 'STEADY'
                            $loadingStart = $null
                        } elseif (([DateTime]::UtcNow - $loadingStart).TotalMilliseconds -ge $LOADING_HOLD_MS) {
                            Send-Log "throttle_on gpu=$gpu"
                            Set-Throttle $ow2
                            $throttleStart = [DateTime]::UtcNow
                            $manualOverride = $false
                            $state = 'THROTTLED'
                        }
                    }
                    'THROTTLED' {
                        $elapsed = ([DateTime]::UtcNow - $throttleStart).TotalSeconds
                        if ($elapsed -ge $THROTTLE_SECS -or (-not $manualOverride -and $gpu -ge $GPU_LOW -and $elapsed -ge 3)) {
                            # Restore after timeout or GPU stabilized (min 3s to ride out initial spike)
                            Set-Restore $ow2
                            $duration = [math]::Round($elapsed, 1)
                            $tag = if ($manualOverride) { 'manual_throttle_off' } else { 'throttle_off' }
                            Send-Log "$tag duration=${duration}s gpu=$gpu"
                            $state = 'STEADY'
                            $throttleStart = $null
                            $manualOverride = $false
                        }
                    }
                }

                Start-Sleep -Milliseconds $POLL_ACTIVE_MS
            }
        } finally {
            # Always restore if OW2 exits while throttled
            if ($state -eq 'THROTTLED' -and $ow2 -and -not $ow2.HasExited) {
                Set-Restore $ow2
            }
        }

        Send-Log "ow2_exited pid=$ow2pid"
    }
} finally {
    Send-Log 'stopped'
    $udp.Close()
    $mtx.ReleaseMutex()
    $mtx.Dispose()
}
