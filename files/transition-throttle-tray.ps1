# transition-throttle-tray.ps1 — System tray controller for OW2 throttle
#
# Reads HKCU:\Software\Overwatch\TransitionThrottle for runtime state and
# observes the OW2 process's processor affinity to determine display state.
# Writes to the same registry key to flip throttle/mode from menu items.
#
# The throttle script (transition-throttle.ps1) listens for registry
# change notifications and applies new state with sub-millisecond latency.
#
# Visual states (single 16x16 icon):
#   Green   → throttle ENABLED, OW2 currently FULL power (or OW2 not running)
#   Orange  → throttle ENABLED, OW2 currently THROTTLED
#   Gray    → throttle DISABLED (system off, throttle script idle)
#
# Tooltip is the source of truth for full state breakdown.
#
# Context menu:
#   ▸ Status: <line>                       (read-only header)
#   ──────────
#   ☑/☐ Throttle enabled                   (toggles HKCU:Enabled)
#   ☑/☐ Auto mode (read GPU metrics)       (toggles HKCU:Mode)
#   ──────────
#   ▸ Force throttle now                   (one-shot affinity flip)
#   ▸ Force full now                       (one-shot affinity flip)
#   ──────────
#   ▸ Exit
#
# Deploy: C:\Scripts\transition-throttle-tray.ps1
# Launch: wscript.exe C:\Scripts\transition-throttle-tray-launcher.vbs
#         (the .vbs launcher ensures the tray runs without a console window
#         and survives explorer.exe restarts via the AtLogon scheduled task)

[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Drawing') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Single-instance mutex ---
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\TransitionThrottleTray')
if (-not $script:mutex.WaitOne(0)) {
    exit 0
}

$script:RegPath           = 'HKCU:\Software\Overwatch\TransitionThrottle'
$script:FULL_AFFINITY     = 0x3F
$script:THROTTLE_AFFINITY = 0x3

# --- Icon generation ---
function New-TrayIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $brush.Dispose()
    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()
    $icon
}

$script:iconFull      = New-TrayIcon ([System.Drawing.Color]::FromArgb(0, 200, 0))
$script:iconThrottled = New-TrayIcon ([System.Drawing.Color]::FromArgb(255, 165, 0))
$script:iconDisabled  = New-TrayIcon ([System.Drawing.Color]::FromArgb(128, 128, 128))

# --- State tracking (display only — registry is the source of truth) ---
$script:lastIconKey = $null

# --- Registry helpers ---
function Get-ThrottleEnabled {
    try {
        $v = (Get-ItemProperty -Path $script:RegPath -Name 'Enabled' -ErrorAction Stop).Enabled
        return ([int]$v -ne 0)
    } catch {
        return $true
    }
}

function Get-ThrottleMode {
    try {
        $v = (Get-ItemProperty -Path $script:RegPath -Name 'Mode' -ErrorAction Stop).Mode
        if ($v) { return $v }
    } catch {}
    return 'manual'
}

function Set-ThrottleEnabled([bool]$value) {
    if (-not (Test-Path $script:RegPath)) {
        New-Item -Path $script:RegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RegPath -Name 'Enabled' -Value ([int]$value) -Type DWord
}

function Set-ThrottleMode([string]$value) {
    if (-not (Test-Path $script:RegPath)) {
        New-Item -Path $script:RegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RegPath -Name 'Mode' -Value $value -Type String
}

# --- OW2 affinity helpers ---
function Get-OW2Process {
    Get-Process -Name 'Overwatch' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-OW2Throttled {
    $ow2 = Get-OW2Process
    if (-not $ow2) { return $null }  # OW2 not running
    try {
        return ([int]$ow2.ProcessorAffinity -eq $script:THROTTLE_AFFINITY)
    } catch {
        return $null
    }
}

function Force-OW2Throttle {
    $ow2 = Get-OW2Process
    if (-not $ow2) { return }
    try {
        $ow2.ProcessorAffinity = [IntPtr]$script:THROTTLE_AFFINITY
        $ow2.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    } catch {}
}

function Force-OW2Full {
    $ow2 = Get-OW2Process
    if (-not $ow2) { return }
    try {
        $ow2.ProcessorAffinity = [IntPtr]$script:FULL_AFFINITY
        $ow2.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    } catch {}
}

# --- Tray setup ---
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = $script:iconFull
$script:notify.Text = 'OW2 Throttle'
$script:notify.Visible = $true

# Context menu
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip

$script:statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:statusItem.Text = 'Status: ...'
$script:statusItem.Enabled = $false
$script:menu.Items.Add($script:statusItem) | Out-Null

$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$script:enabledItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:enabledItem.Text = 'Throttle enabled'
$script:enabledItem.CheckOnClick = $false  # we manage Checked manually
$script:menu.Items.Add($script:enabledItem) | Out-Null

$script:autoItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:autoItem.Text = 'Auto mode (read GPU metrics)'
$script:autoItem.CheckOnClick = $false
$script:menu.Items.Add($script:autoItem) | Out-Null

$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$script:forceThrottleItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:forceThrottleItem.Text = 'Force throttle now'
$script:menu.Items.Add($script:forceThrottleItem) | Out-Null

$script:forceFullItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:forceFullItem.Text = 'Force full now'
$script:menu.Items.Add($script:forceFullItem) | Out-Null

$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$script:exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:exitItem.Text = 'Exit'
$script:menu.Items.Add($script:exitItem) | Out-Null

$script:notify.ContextMenuStrip = $script:menu

# --- Menu handlers ---
$script:enabledItem.Add_Click({
    $current = Get-ThrottleEnabled
    Set-ThrottleEnabled (-not $current)
})

$script:autoItem.Add_Click({
    $current = Get-ThrottleMode
    if ($current -eq 'auto') {
        Set-ThrottleMode 'manual'
    } else {
        Set-ThrottleMode 'auto'
    }
})

$script:forceThrottleItem.Add_Click({ Force-OW2Throttle })
$script:forceFullItem.Add_Click({ Force-OW2Full })

$script:exitItem.Add_Click({
    $script:timer.Stop()
    $script:notify.Visible = $false
    $script:notify.Dispose()
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# --- Polling timer (display refresh + menu state sync) ---
# Updates icon, tooltip, and menu checkmarks once per second based on
# the current registry values + OW2 affinity. This is purely a display
# concern — the throttle script itself uses RegNotifyChangeKeyValue and
# does not poll.
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000

$script:timer.Add_Tick({
    $enabled    = Get-ThrottleEnabled
    $mode       = Get-ThrottleMode
    $isThrottle = Get-OW2Throttled  # $true / $false / $null (not running)

    # Determine icon + tooltip
    if (-not $enabled) {
        $iconKey = 'disabled'
        $script:notify.Text = "OW2 Throttle: DISABLED"
        $statusText = "Status: throttle disabled"
    } elseif ($null -eq $isThrottle) {
        $iconKey = 'full'
        $script:notify.Text = "OW2 Throttle: idle (OW2 not running) | mode: $mode"
        $statusText = "Status: enabled, $mode mode, OW2 not running"
    } elseif ($isThrottle) {
        $iconKey = 'throttled'
        $script:notify.Text = "OW2 Throttle: THROTTLED | mode: $mode"
        $statusText = "Status: enabled, $mode mode, OW2 throttled"
    } else {
        $iconKey = 'full'
        $script:notify.Text = "OW2 Throttle: full | mode: $mode"
        $statusText = "Status: enabled, $mode mode, OW2 full"
    }

    if ($iconKey -ne $script:lastIconKey) {
        switch ($iconKey) {
            'full'      { $script:notify.Icon = $script:iconFull }
            'throttled' { $script:notify.Icon = $script:iconThrottled }
            'disabled'  { $script:notify.Icon = $script:iconDisabled }
        }
        $script:lastIconKey = $iconKey
    }

    $script:statusItem.Text     = $statusText
    $script:enabledItem.Checked = $enabled
    $script:autoItem.Checked    = ($mode -eq 'auto')
    $script:autoItem.Enabled    = $enabled
})

$script:timer.Start()

# --- Run the message pump ---
[System.Windows.Forms.Application]::Run()
