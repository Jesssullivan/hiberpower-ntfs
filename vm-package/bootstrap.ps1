# HiberPower Bootstrap - Run this in PowerShell
# Download: Save this file, right-click -> Run with PowerShell

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$ErrorActionPreference = "Continue"

Write-Host "=== HiberPower Capture Setup ===" -ForegroundColor Cyan

# Create directory
$dir = "C:\HiberPower-Capture"
mkdir $dir -Force | Out-Null
cd $dir
Write-Host "[1/4] Created $dir" -ForegroundColor Green

# Download capture tools
Write-Host "[2/4] Downloading capture tools..." -ForegroundColor Green
Invoke-WebRequest "http://10.0.2.2:8888/hooks.js" -OutFile hooks.js
Invoke-WebRequest "http://10.0.2.2:8888/capture.py" -OutFile capture.py
Write-Host "  Downloaded hooks.js and capture.py" -ForegroundColor White

# Download Python
Write-Host "[3/4] Downloading Python installer..." -ForegroundColor Green
$pyUrl = "https://www.python.org/ftp/python/3.12.0/python-3.12.0-amd64.exe"
Invoke-WebRequest $pyUrl -OutFile python-installer.exe
Write-Host "  Downloaded python-installer.exe" -ForegroundColor White

Write-Host "[4/4] Installing Python (this may take a minute)..." -ForegroundColor Green
Start-Process -FilePath ".\python-installer.exe" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
Write-Host "  Python installed" -ForegroundColor White

# Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# Install Frida
Write-Host "[5/5] Installing Frida..." -ForegroundColor Green
pip install frida frida-tools

Write-Host ""
Write-Host "=== Setup Complete! ===" -ForegroundColor Cyan
Write-Host "Next: Download SP Toolbox from silicon-power.com" -ForegroundColor Yellow
Write-Host "Then run: python capture.py spawn 'C:\path\to\SPToolbox.exe'" -ForegroundColor Yellow
pause
