# transition-throttle-tray.ps1 — System tray status + toggle for OW2 Transition Throttle
#
# System tray icon reflects the live throttle state:
#   Green  = OW2 at full performance (or system enabled, OW2 not running)
#   Orange = OW2 throttled (reduced vCPUs / BelowNormal priority)
#   Red    = system disabled (script stopped, task won't auto-start)
#
# Pause/Break toggles are handled by transition-throttle.ps1 — this tray script
# polls OW2's affinity every second and updates the icon to match.
#
# Left-click or context menu "Toggle" enables/disables the entire system.
#
# Deploy: C:\Scripts\transition-throttle-tray.ps1
# Launch: wscript.exe C:\Scripts\transition-throttle-tray-launcher.vbs

# --- Hide console window immediately (no visible terminal regardless of launch method) ---
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[void][Console.Window]::ShowWindow($consolePtr, 0)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Single-instance mutex ---
$script:mtx = New-Object System.Threading.Mutex($false, 'Global\TransitionThrottleTray')
if (-not $script:mtx.WaitOne(0)) {
    exit 0
}

$script:taskName = 'OW2 Transition Throttle'
$script:FULL_AFFINITY     = 0x3F
$script:THROTTLE_AFFINITY = 0x3

# --- Icon generation ---
function New-TrayIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $brush.Dispose()
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

$script:iconFull      = New-TrayIcon ([System.Drawing.Color]::FromArgb(0, 200, 0))
$script:iconThrottled = New-TrayIcon ([System.Drawing.Color]::FromArgb(255, 165, 0))
$script:iconOff       = New-TrayIcon ([System.Drawing.Color]::FromArgb(200, 0, 0))

# --- State tracking ---
$script:lastIcon = $null
$script:enabled = $false
$script:taskCheckCounter = 0

# --- State detection ---
function Get-ThrottleEnabled {
    try {
        $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction Stop
        $task.State -ne 'Disabled'
    } catch {
        $false
    }
}

function Get-ScriptRunning {
    $test = New-Object System.Threading.Mutex($false, 'Global\TransitionThrottle')
    $acquired = $test.WaitOne(0)
    if ($acquired) {
        $test.ReleaseMutex()
        $test.Dispose()
        $false
    } else {
        $test.Dispose()
        $true
    }
}

# --- Toggle actions ---
function Enable-Throttle {
    Enable-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
    if (-not (Get-ScriptRunning)) {
        Start-Process wscript.exe -ArgumentList @(
            'C:\Scripts\transition-throttle-launcher.vbs'
        ) -Verb RunAs -WindowStyle Hidden
    }
}

function Disable-Throttle {
    Disable-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
    Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine -like '*transition-throttle.ps1*' -and
            $_.CommandLine -notlike '*transition-throttle-tray.ps1*') {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Get-Process -Name 'Overwatch' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.ProcessorAffinity = [IntPtr]$script:FULL_AFFINITY
            $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
        } catch {}
    }
}

# --- Tray setup ---
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:enabled = Get-ThrottleEnabled
$script:notify.Icon = if ($script:enabled) { $script:iconFull } else { $script:iconOff }
$script:notify.Text = if ($script:enabled) { 'OW2 Throttle: ON' } else { 'OW2 Throttle: OFF' }
$script:notify.Visible = $true

# Context menu
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:toggleItem = $script:menu.Items.Add('Toggle')
$script:exitItem = $script:menu.Items.Add('Exit')
$script:notify.ContextMenuStrip = $script:menu

# --- Polling timer: check OW2 affinity every second ---
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000

$script:timer.Add_Tick({
    $ow2 = Get-Process -Name 'Overwatch' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ow2) {
        try {
            $aff = [int]$ow2.ProcessorAffinity
            if ($aff -le $script:THROTTLE_AFFINITY) {
                if ($script:lastIcon -ne 'throttled') {
                    $script:notify.Icon = $script:iconThrottled
                    $script:notify.Text = 'OW2 Throttle: THROTTLED'
                    $script:lastIcon = 'throttled'
                }
            } else {
                if ($script:lastIcon -ne 'full') {
                    $script:notify.Icon = $script:iconFull
                    $script:notify.Text = 'OW2 Throttle: FULL'
                    $script:lastIcon = 'full'
                }
            }
        } catch {}
    } else {
        $script:taskCheckCounter++
        if ($script:taskCheckCounter -ge 5 -or $script:lastIcon -eq $null) {
            $script:taskCheckCounter = 0
            $script:enabled = Get-ThrottleEnabled
            if ($script:enabled) {
                if ($script:lastIcon -ne 'on') {
                    $script:notify.Icon = $script:iconFull
                    $script:notify.Text = 'OW2 Throttle: ON'
                    $script:lastIcon = 'on'
                }
            } else {
                if ($script:lastIcon -ne 'off') {
                    $script:notify.Icon = $script:iconOff
                    $script:notify.Text = 'OW2 Throttle: OFF'
                    $script:lastIcon = 'off'
                }
            }
        }
    }
})

$script:timer.Start()

# Left-click = toggle system on/off
$script:notify.Add_Click({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($script:enabled) { Disable-Throttle } else { Enable-Throttle }
        Start-Sleep -Milliseconds 500
        $script:enabled = Get-ThrottleEnabled
        $script:lastIcon = $null
    }
})

# Menu toggle
$script:toggleItem.Add_Click({
    if ($script:enabled) { Disable-Throttle } else { Enable-Throttle }
    Start-Sleep -Milliseconds 500
    $script:enabled = Get-ThrottleEnabled
    $script:lastIcon = $null
})

# Menu exit
$script:exitItem.Add_Click({
    $script:timer.Stop()
    $script:timer.Dispose()
    $script:notify.Visible = $false
    $script:notify.Dispose()
    $script:mtx.ReleaseMutex()
    $script:mtx.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Run message loop
[System.Windows.Forms.Application]::Run()
