$udp = New-Object System.Net.Sockets.UdpClient
$bytes = [System.Text.Encoding]::ASCII.GetBytes("shutdown")
$udp.Send($bytes, $bytes.Length, "192.168.0.100", 9147)
$udp.Close()
