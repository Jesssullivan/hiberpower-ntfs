# Post-installation setup script for HiberPower Frida capture
# This script is run automatically after Windows installation
# Can also be run manually via: powershell -ExecutionPolicy Bypass -File post-install-setup.ps1

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HiberPower Post-Install Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Create directories
$captureDir = "C:\HiberPower-Capture"
$toolsDir = "C:\HiberPower-Tools"

Write-Host "[1/5] Creating directories..." -ForegroundColor Green
New-Item -ItemType Directory -Path $captureDir -Force | Out-Null
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
Write-Host "  Created: $captureDir" -ForegroundColor White
Write-Host "  Created: $toolsDir" -ForegroundColor White

# Download Python (portable)
Write-Host ""
Write-Host "[2/5] Downloading Python..." -ForegroundColor Green
$pythonUrl = "https://www.python.org/ftp/python/3.12.0/python-3.12.0-embed-amd64.zip"
$pythonZip = "$toolsDir\python.zip"
$pythonDir = "$toolsDir\python"

try {
    Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonZip -UseBasicParsing
    Expand-Archive -Path $pythonZip -DestinationPath $pythonDir -Force
    Remove-Item $pythonZip
    Write-Host "  Python extracted to: $pythonDir" -ForegroundColor White
} catch {
    Write-Host "  Failed to download Python: $_" -ForegroundColor Red
    Write-Host "  Please install Python manually from python.org" -ForegroundColor Yellow
}

# Download get-pip.py and install pip
Write-Host ""
Write-Host "[3/5] Installing pip..." -ForegroundColor Green
try {
    $getPipUrl = "https://bootstrap.pypa.io/get-pip.py"
    $getPip = "$pythonDir\get-pip.py"
    Invoke-WebRequest -Uri $getPipUrl -OutFile $getPip -UseBasicParsing

    # Enable pip in embedded Python
    $pthFile = Get-ChildItem "$pythonDir\python*._pth" | Select-Object -First 1
    if ($pthFile) {
        $content = Get-Content $pthFile.FullName
        $content = $content -replace '#import site', 'import site'
        Set-Content $pthFile.FullName $content
    }

    & "$pythonDir\python.exe" $getPip
    Write-Host "  pip installed" -ForegroundColor White
} catch {
    Write-Host "  Failed to install pip: $_" -ForegroundColor Red
}

# Install Frida
Write-Host ""
Write-Host "[4/5] Installing Frida..." -ForegroundColor Green
try {
    & "$pythonDir\python.exe" -m pip install frida frida-tools
    Write-Host "  Frida installed" -ForegroundColor White
} catch {
    Write-Host "  Failed to install Frida: $_" -ForegroundColor Red
}

# Copy capture scripts (if available from shared folder)
Write-Host ""
Write-Host "[5/5] Setting up capture scripts..." -ForegroundColor Green

# Check for VirtIO shared folder or try to copy from known locations
$scriptSource = $null
$possibleSources = @(
    "D:\vm-package",
    "E:\vm-package",
    "\\VBOXSVR\shared\vm-package"
)

foreach ($src in $possibleSources) {
    if (Test-Path "$src\hooks.js") {
        $scriptSource = $src
        break
    }
}

if ($scriptSource) {
    Copy-Item "$scriptSource\hooks.js" "$captureDir\" -Force
    Copy-Item "$scriptSource\capture.py" "$captureDir\" -Force
    Write-Host "  Copied capture scripts from $scriptSource" -ForegroundColor White
} else {
    Write-Host "  Capture scripts not found in shared folder" -ForegroundColor Yellow
    Write-Host "  Please manually copy hooks.js and capture.py to $captureDir" -ForegroundColor Yellow
}

# Add Python to PATH for current session
$env:Path = "$pythonDir;$pythonDir\Scripts;$env:Path"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Python location: $pythonDir\python.exe" -ForegroundColor White
Write-Host "Capture directory: $captureDir" -ForegroundColor White
Write-Host ""
Write-Host "To run capture:" -ForegroundColor Yellow
Write-Host "  cd $captureDir" -ForegroundColor Gray
Write-Host "  $pythonDir\python.exe capture.py spawn `"C:\path\to\SPToolbox.exe`"" -ForegroundColor Gray
Write-Host ""
