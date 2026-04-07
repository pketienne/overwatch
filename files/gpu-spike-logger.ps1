# gpu-spike-logger.ps1 — High-frequency GPU utilization logger for OW2
#
# Captures GPU engine utilization, compute, and VRAM usage at 200ms intervals
# while OW2 is running. Detects spikes (rapid utilization jumps) and annotates
# them in the log for post-session analysis.
#
# Output: C:\Logs\gpu-spikes\YYYYMMDD-HHmmss.csv
#   Columns: timestamp, gpu3d, compute0, compute1, hiPri3d, vramMB, spike
#   spike column: empty normally, "SPIKE peak=N prev=N" on detected spike
#
# Deploy: C:\Scripts\gpu-spike-logger.ps1
# Run manually: powershell -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\gpu-spike-logger.ps1
# Stop: Ctrl+C or kill the process (writes partial CSV cleanly)
#
# NOT auto-started. Run on-demand for diagnostic sessions.

param(
    [int]$PollMs        = 200,    # Sample interval
    [int]$SpikeThreshold = 90,    # 3D util % to flag as spike
    [int]$SpikeDelta     = 25,    # Min jump from previous sample to flag
    [int]$IdlePollMs     = 2000   # Poll interval when OW2 not running
)

# --- Hide console window ---
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[void][Console.Window]::ShowWindow($consolePtr, 0)

# --- Single-instance mutex ---
$mtx = New-Object System.Threading.Mutex($false, 'Global\GpuSpikeLogger')
if (-not $mtx.WaitOne(0)) {
    Write-Host "Another instance is already running."
    exit 0
}

# --- Log directory ---
$logDir = "C:\Logs\gpu-spikes"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# --- Counter readers ---
function Get-GpuEngineUtil($procId, $engType) {
    try {
        $pattern = "\GPU Engine(pid_${procId}_*engtype_${engType})\Utilization Percentage"
        $samples = (Get-Counter $pattern -ErrorAction Stop).CounterSamples
        $max = ($samples | Measure-Object -Property CookedValue -Maximum).Maximum
        [math]::Round($max, 1)
    } catch {
        -1
    }
}

function Get-VramUsageMB($procId) {
    try {
        $pattern = "\GPU Process Memory(pid_${procId}_*)\Dedicated Usage"
        $samples = (Get-Counter $pattern -ErrorAction Stop).CounterSamples
        $total = ($samples | Measure-Object -Property CookedValue -Sum).Sum
        [math]::Round($total / 1MB, 0)
    } catch {
        -1
    }
}

# --- Main loop ---
try {
    Write-Host "GPU Spike Logger started. Waiting for OW2..."

    while ($true) {
        # Wait for OW2
        $ow2 = $null
        while (-not $ow2) {
            $ow2 = Get-Process -Name 'Overwatch' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $ow2) {
                Start-Sleep -Milliseconds $IdlePollMs
            }
        }

        $pid = $ow2.Id
        $sessionFile = Join-Path $logDir ((Get-Date -Format "yyyyMMdd-HHmmss") + ".csv")
        $writer = [System.IO.StreamWriter]::new($sessionFile, $false, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $true
        $writer.WriteLine("timestamp,gpu3d,compute0,compute1,hiPri3d,vramMB,spike")

        Write-Host "OW2 detected (pid $pid). Logging to $sessionFile"

        $prev3d = 0
        $spikeCount = 0

        try {
            while ($true) {
                try { $ow2.Refresh(); if ($ow2.HasExited) { break } } catch { break }

                $ts = Get-Date -Format "HH:mm:ss.fff"
                $gpu3d     = Get-GpuEngineUtil $pid "3d"
                $compute0  = Get-GpuEngineUtil $pid "compute 0"
                $compute1  = Get-GpuEngineUtil $pid "compute 1"
                $hiPri3d   = Get-GpuEngineUtil $pid "high priority 3d"
                $vram      = Get-VramUsageMB $pid

                # Spike detection
                $spike = ""
                if ($gpu3d -ge $SpikeThreshold -and ($gpu3d - $prev3d) -ge $SpikeDelta) {
                    $spike = "SPIKE peak=$gpu3d prev=$prev3d"
                    $spikeCount++
                }

                $writer.WriteLine("$ts,$gpu3d,$compute0,$compute1,$hiPri3d,$vram,$spike")
                $prev3d = $gpu3d

                Start-Sleep -Milliseconds $PollMs
            }
        } finally {
            $writer.Close()
            Write-Host "OW2 exited. Session: $sessionFile ($spikeCount spikes detected)"
        }
    }
} catch {
    Write-Host "FATAL: $_"
} finally {
    $mtx.ReleaseMutex()
    $mtx.Dispose()
}
