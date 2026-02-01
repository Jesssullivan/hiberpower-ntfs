# Windows Setup Script for Frida Capture Environment
# Run this in PowerShell after Windows installation

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HiberPower Frida Capture Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "WARNING: Not running as Administrator. Some operations may fail." -ForegroundColor Yellow
    Write-Host ""
}

# Step 1: Check/Install Python
Write-Host "[1/4] Checking Python installation..." -ForegroundColor Green
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $pyVersion = python --version 2>&1
    Write-Host "  Found: $pyVersion" -ForegroundColor White
} else {
    Write-Host "  Python not found. Please install from https://www.python.org/downloads/" -ForegroundColor Red
    Write-Host "  Make sure to check 'Add Python to PATH' during installation!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  After installing Python, run this script again." -ForegroundColor Yellow
    exit 1
}

# Step 2: Install Frida
Write-Host ""
Write-Host "[2/4] Installing Frida..." -ForegroundColor Green
try {
    pip install --upgrade frida frida-tools 2>&1 | Out-Null
    $fridaVersion = frida --version 2>&1
    Write-Host "  Frida installed: $fridaVersion" -ForegroundColor White
} catch {
    Write-Host "  Failed to install Frida: $_" -ForegroundColor Red
    Write-Host "  Try manually: pip install frida frida-tools" -ForegroundColor Yellow
}

# Step 3: Create capture directory
Write-Host ""
Write-Host "[3/4] Setting up capture directory..." -ForegroundColor Green
$captureDir = "C:\HiberPower-Capture"
if (-not (Test-Path $captureDir)) {
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
    Write-Host "  Created: $captureDir" -ForegroundColor White
} else {
    Write-Host "  Already exists: $captureDir" -ForegroundColor White
}

# Step 4: Download capture scripts (if network share available)
Write-Host ""
Write-Host "[4/4] Capture scripts location..." -ForegroundColor Green
Write-Host "  Copy hooks.js and capture.py to $captureDir" -ForegroundColor White
Write-Host "  From Linux host: /home/jsullivan2/git/hiberpower-ntfs/vm-package/" -ForegroundColor Gray

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Install SP Toolbox from silicon-power.com" -ForegroundColor White
Write-Host "  2. Copy hooks.js and capture.py to $captureDir" -ForegroundColor White
Write-Host "  3. Connect the ASM2362 USB drive" -ForegroundColor White
Write-Host "  4. Run capture:" -ForegroundColor White
Write-Host "     cd $captureDir" -ForegroundColor Gray
Write-Host '     python capture.py spawn "C:\Program Files\SP Toolbox\SPToolbox.exe"' -ForegroundColor Gray
Write-Host ""
