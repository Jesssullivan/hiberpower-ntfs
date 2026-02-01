# Configure WinRM for remote access
# Run as Administrator

Write-Host "=== Configuring WinRM ===" -ForegroundColor Cyan

# Enable WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Configure WinRM for unencrypted traffic (required for Linux clients)
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true

# Set TrustedHosts to allow any connection
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# Configure firewall
New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue

# Restart WinRM service
Restart-Service WinRM

# Verify configuration
Write-Host ""
Write-Host "WinRM Configuration:" -ForegroundColor Green
winrm get winrm/config/service

Write-Host ""
Write-Host "=== WinRM Configured! ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Connect from Linux with:" -ForegroundColor Yellow
Write-Host '  python3 -c "import winrm; s=winrm.Session(\"http://127.0.0.1:5985/wsman\", auth=(\"Admin\",\"hiberpower\"), transport=\"basic\"); print(s.run_cmd(\"hostname\").std_out)"' -ForegroundColor Gray
Write-Host ""
pause
