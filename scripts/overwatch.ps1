# overwatch.ps1 — Signal host when Windows initiates shutdown.
# Deploy to C:\Scripts\overwatch.ps1 on the guest.
#
# Setup (run once as Administrator in PowerShell):
#
#   $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
#       -Argument '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Scripts\overwatch.ps1'
#   $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 30)
#   $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
#   Register-ScheduledTask -TaskName 'Overwatch Shutdown Signal' -Action $action `
#       -Settings $settings -Principal $principal -Force
#
#   # Update trigger to Event 1074 (User32 — system shutdown initiated):
#   $xml = (Get-ScheduledTask 'Overwatch Shutdown Signal' | Export-ScheduledTask) -replace '<Triggers/>', `
#       '<Triggers><EventTrigger><Enabled>true</Enabled><Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name=''User32''] and EventID=1074]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription></EventTrigger></Triggers>'
#   $xml | Out-File "$env:TEMP\ow-task.xml" -Encoding Unicode
#   Unregister-ScheduledTask -TaskName 'Overwatch Shutdown Signal' -Confirm:$false
#   Register-ScheduledTask -Xml (Get-Content "$env:TEMP\ow-task.xml" -Raw) -TaskName 'Overwatch Shutdown Signal'

$udp = New-Object Net.Sockets.UdpClient
$udp.Connect('192.168.0.100', 9147)
$bytes = [Text.Encoding]::ASCII.GetBytes('shutdown')
[void]$udp.Send($bytes, $bytes.Length)
$udp.Close()
