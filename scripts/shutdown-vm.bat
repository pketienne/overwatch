@echo off
:: Signal vm-overwatch that shutdown was initiated (for timing measurement)
powershell -NoProfile -Command "$u=New-Object Net.Sockets.UdpClient;$b=[byte[]]@(1);$u.Send($b,1,'192.168.0.100',9147);$u.Close()"
:: Initiate Windows shutdown
shutdown /s /t 0
