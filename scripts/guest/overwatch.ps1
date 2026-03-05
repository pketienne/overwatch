# overwatch.ps1 — Signal host when Windows initiates shutdown.
# Deploy to C:\Scripts\overwatch.ps1 on the guest.
#
# Setup (run once as Administrator in PowerShell):
#
#   $trigger = New-CimInstance -CimClass (Get-CimClass MSFT_TaskEventTrigger `
#       -Namespace 'Root/Microsoft/Windows/TaskScheduler') -ClientOnly
#   $trigger.Subscription = "<QueryList><Query Id='0' Path='System'>" +
#       "<Select Path='System'>*[System[Provider[@Name='User32'] and EventID=1074]]" +
#       "</Select></Query></QueryList>"
#   $trigger.Enabled = $true
#   $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
#       -Argument '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Scripts\overwatch.ps1'
#   $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 30)
#   $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
#   Unregister-ScheduledTask -TaskName 'Overwatch Shutdown Signal' -Confirm:$false -EA SilentlyContinue
#   Register-ScheduledTask -TaskName 'Overwatch Shutdown Signal' -Action $action `
#       -Trigger $trigger -Settings $settings -Principal $principal

$udp = New-Object Net.Sockets.UdpClient
$udp.Connect('192.168.0.100', 9147)
$bytes = [Text.Encoding]::ASCII.GetBytes('shutdown')
[void]$udp.Send($bytes, $bytes.Length)
$udp.Close()
