# start-synapse.ps1 - Launch Synapse, wait, restart to apply device settings

# --- Timing helper ---
function Write-Timing($phase) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $dir = "C:\ProgramData\overwatch"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path "$dir\boot-timing.log" -Value "$ts SYNAPSE $phase"
}

$synapse = "C:\Program Files\Razer\RazerAppEngine\RazerAppEngine.exe"
$argList = "--url-params=apps=synapse,chroma-app --launch-force-hidden=synapse,chroma-app --autoStart=1"

Write-Timing "script-start"

# Wait for explorer shell (interactive desktop ready)
for ($i = 0; $i -lt 30; $i++) {
    $shell = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
    if ($shell) { break }
    Start-Sleep -Seconds 1
}
Write-Timing "shell-ready"

# First launch
Start-Process -FilePath $synapse -ArgumentList $argList -WindowStyle Minimized
Write-Timing "first-launch"
Start-Sleep -Seconds 30

# Kill all Synapse processes
Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Timing "kill"
Start-Sleep -Seconds 5

# Relaunch - settings now apply to already-enumerated USB devices
Start-Process -FilePath $synapse -ArgumentList $argList -WindowStyle Minimized
Write-Timing "complete"
