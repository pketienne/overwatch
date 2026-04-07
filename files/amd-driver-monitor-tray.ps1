# transition-throttle-tray.ps1 — System tray AMD driver health indicator
#
# System tray icon monitors AMD GPU driver power management:
#   Green = ULPS disabled (correct for VFIO passthrough)
#   Red   = ULPS re-enabled (AMD driver update reset the setting)
#
# Checks ULPS registry value once at startup and every 24 hours.
# Shows a balloon notification when ULPS is found re-enabled.
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

$script:iconOk    = New-TrayIcon ([System.Drawing.Color]::FromArgb(0, 200, 0))
$script:iconAlert = New-TrayIcon ([System.Drawing.Color]::FromArgb(200, 0, 0))

# --- AMD driver power management check ---
# ULPS (Ultra Low Power State) causes TDR in VFIO passthrough.
# AMD driver updates reset EnableUlps back to 1.
function Test-UlpsMisconfigured {
    try {
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        Get-ChildItem $regPath -ErrorAction Stop | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DriverDesc -match 'AMD|Radeon') {
                return ($props.EnableUlps -ne 0)
            }
        }
    } catch {}
    $false
}

# --- Tray setup ---
$script:ulpsBad = Test-UlpsMisconfigured

$script:notify = New-Object System.Windows.Forms.NotifyIcon
if ($script:ulpsBad) {
    $script:notify.Icon = $script:iconAlert
    $script:notify.Text = 'AMD Driver: ULPS ENABLED - run setup-guest.sh gpu'
} else {
    $script:notify.Icon = $script:iconOk
    $script:notify.Text = 'AMD Driver: OK'
}
$script:notify.Visible = $true

# Context menu
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:exitItem = $script:menu.Items.Add('Exit')
$script:notify.ContextMenuStrip = $script:menu

# Show balloon on startup if misconfigured
if ($script:ulpsBad) {
    $script:notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
    $script:notify.BalloonTipTitle = 'AMD Driver: ULPS Enabled'
    $script:notify.BalloonTipText = 'ULPS has been re-enabled by a driver update. Run setup-guest.sh gpu from the host to fix.'
    $script:notify.ShowBalloonTip(10000)
}

# --- Daily ULPS check (86400s timer) ---
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 86400000  # 24 hours in ms

$script:timer.Add_Tick({
    $wasBad = $script:ulpsBad
    $script:ulpsBad = Test-UlpsMisconfigured

    if ($script:ulpsBad) {
        $script:notify.Icon = $script:iconAlert
        $script:notify.Text = 'AMD Driver: ULPS ENABLED - run setup-guest.sh gpu'
        if (-not $wasBad) {
            $script:notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
            $script:notify.BalloonTipTitle = 'AMD Driver Updated'
            $script:notify.BalloonTipText = 'ULPS has been re-enabled. Run setup-guest.sh gpu from the host to fix.'
            $script:notify.ShowBalloonTip(10000)
        }
    } else {
        $script:notify.Icon = $script:iconOk
        $script:notify.Text = 'AMD Driver: OK'
    }
})

$script:timer.Start()

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
