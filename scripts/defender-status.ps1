#Requires -Version 5.1
# defender-status.ps1 — System tray icon showing Windows Defender scan status.
# Runs at logon via Task Scheduler.
#
#   Orange = scan in progress  (wait before launching Overwatch)
#   Green  = idle              (safe to launch)
#   Grey   = Defender disabled (re-enable via Windows Security)
#
# Detection: watches Event 1000 (scan start) and 1001 (scan end) in
# Microsoft-Windows-Windows Defender/Operational. Fires even with
# full-disk exclusions.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Icon factory ──────────────────────────────────────────────────────────────
function New-CircleIcon([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $br  = New-Object System.Drawing.SolidBrush($c)
    $g.FillEllipse($br, 1, 1, 14, 14)
    $br.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# ── Shared state ──────────────────────────────────────────────────────────────
$script:bootTime    = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$script:lastState   = ''
$script:notified    = $false
$script:currentIcon = $null

# ── Tray icon ─────────────────────────────────────────────────────────────────
$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Text    = 'Windows Defender'
$tray.Icon    = New-CircleIcon ([System.Drawing.Color]::DarkOrange)
$tray.Visible = $true
$script:currentIcon = $tray.Icon

$ctxMenu   = New-Object System.Windows.Forms.ContextMenuStrip
$infoItem  = New-Object System.Windows.Forms.ToolStripMenuItem('Checking...')
$infoItem.Enabled = $false
$sep       = New-Object System.Windows.Forms.ToolStripSeparator
$quitItem  = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$quitItem.Add_Click({
    $tray.Visible = $false
    $timer.Stop()
    [System.Windows.Forms.Application]::Exit()
})
[void]$ctxMenu.Items.Add($infoItem)
[void]$ctxMenu.Items.Add($sep)
[void]$ctxMenu.Items.Add($quitItem)
$tray.ContextMenuStrip = $ctxMenu

# ── Timer ─────────────────────────────────────────────────────────────────────
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({

    # --- Detect state ---
    $state = 'idle'
    try {
        $mpStatus = Get-MpComputerStatus -EA Stop
        if (-not $mpStatus.AntivirusEnabled) {
            $state = 'disabled'
        } else {
            # Scanning if Event 1000 (scan start) exists since boot and is
            # more recent than the last Event 1001 (scan end)
            $lastStart = Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-Windows Defender/Operational'
                Id        = 1000
                StartTime = $script:bootTime
            } -MaxEvents 1 -EA SilentlyContinue

            $lastEnd = Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-Windows Defender/Operational'
                Id        = 1001
                StartTime = $script:bootTime
            } -MaxEvents 1 -EA SilentlyContinue

            if ($lastStart -and (-not $lastEnd -or $lastStart.TimeCreated -gt $lastEnd.TimeCreated)) {
                $state = 'scanning'
            }
        }
    } catch {
        $state = 'error'
    }

    # --- Update tray ---
    if ($state -eq $script:lastState) { return }
    $script:lastState = $state

    $oldIcon = $script:currentIcon
    switch ($state) {
        'idle' {
            $script:currentIcon = New-CircleIcon ([System.Drawing.Color]::LimeGreen)
            $tray.Icon     = $script:currentIcon
            $tray.Text     = 'Windows Defender: Ready'
            $infoItem.Text = 'Defender idle — safe to launch Overwatch'
            if (-not $script:notified) {
                $tray.ShowBalloonTip(6000, 'Overwatch Ready',
                    'Defender is idle. Safe to launch.',
                    [System.Windows.Forms.ToolTipIcon]::Info)
                $script:notified = $true
            }
            $timer.Interval = 5000
        }
        'scanning' {
            $script:currentIcon = New-CircleIcon ([System.Drawing.Color]::DarkOrange)
            $tray.Icon     = $script:currentIcon
            $tray.Text     = 'Windows Defender: Scanning'
            $infoItem.Text = 'Scan in progress — wait before launching Overwatch'
            $script:notified = $false
            $timer.Interval  = 2000
        }
        'disabled' {
            $script:currentIcon = New-CircleIcon ([System.Drawing.Color]::DimGray)
            $tray.Icon     = $script:currentIcon
            $tray.Text     = 'Windows Defender: Disabled'
            $infoItem.Text = 'Defender is disabled — re-enable via Windows Security'
            $timer.Interval = 30000
        }
        'error' {
            $script:currentIcon = New-CircleIcon ([System.Drawing.Color]::Crimson)
            $tray.Icon     = $script:currentIcon
            $tray.Text     = 'Windows Defender: Error'
            $infoItem.Text = 'Could not read Defender status'
            $timer.Interval = 10000
        }
    }
    if ($oldIcon -and ($oldIcon -ne $script:currentIcon)) { $oldIcon.Dispose() }
})

$timer.Start()
[System.Windows.Forms.Application]::Run()
