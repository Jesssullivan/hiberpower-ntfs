# Enable RDP on Windows
# Run as Administrator

Write-Host "Enabling Remote Desktop..." -ForegroundColor Cyan

# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0

# Enable firewall rule
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Optional: Allow connections from any version of RDP client
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0

Write-Host "RDP Enabled!" -ForegroundColor Green
Write-Host ""
Write-Host "Connect from Linux host with:" -ForegroundColor Yellow
Write-Host "  xfreerdp /v:localhost:3389 /u:Admin /p:hiberpower /clipboard" -ForegroundColor White
Write-Host ""
pause
