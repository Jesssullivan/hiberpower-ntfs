# Download SP Toolbox
# Run as Administrator

$ErrorActionPreference = "Continue"
Write-Host "=== Downloading SP Toolbox ===" -ForegroundColor Cyan

$downloadDir = "C:\HiberPower-Capture"
cd $downloadDir

Write-Host "Trying download sources..." -ForegroundColor Green

# Try official Silicon Power URLs
$urls = @(
    "https://www.silicon-power.com/web/us/download_software",
    "https://www.silicon-power.com/download/application-software/",
    "https://www.majorgeeks.com/files/details/sp_toolbox.html"
)

Write-Host ""
Write-Host "Opening download page in Edge..." -ForegroundColor Yellow
Start-Process "https://www.silicon-power.com/web/us/download_software"

Write-Host ""
Write-Host "INSTRUCTIONS:" -ForegroundColor Cyan
Write-Host "1. Find 'SP ToolBox' in the list" -ForegroundColor White
Write-Host "2. Click the Windows download button" -ForegroundColor White
Write-Host "3. Save and run the installer" -ForegroundColor White
Write-Host ""
Write-Host "If that page doesn't work, try:" -ForegroundColor Yellow
Write-Host "  https://www.majorgeeks.com/files/details/sp_toolbox.html" -ForegroundColor Gray
Write-Host ""
Write-Host "After installing, the default path is:" -ForegroundColor White
Write-Host '  C:\Program Files (x86)\Silicon Power\SP ToolBox\SP ToolBox.exe' -ForegroundColor Gray
Write-Host ""
Write-Host "Then run Frida capture:" -ForegroundColor Cyan
Write-Host '  cd C:\HiberPower-Capture' -ForegroundColor White
Write-Host '  python capture.py spawn "C:\Program Files (x86)\Silicon Power\SP ToolBox\SP ToolBox.exe"' -ForegroundColor White
Write-Host ""
pause
