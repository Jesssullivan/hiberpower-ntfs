#!/bin/bash
# Serve capture tools via HTTP for Windows VM to download
#
# Usage: ./scripts/serve-capture-tools.sh [port]
#
# From Windows VM (PowerShell):
#   cd C:\HiberPower-Capture
#   Invoke-WebRequest -Uri "http://10.0.2.2:8888/hooks.js" -OutFile hooks.js
#   Invoke-WebRequest -Uri "http://10.0.2.2:8888/capture.py" -OutFile capture.py
#
# Note: 10.0.2.2 is QEMU's host address from guest perspective

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_PACKAGE="$PROJECT_DIR/vm-package"

PORT="${1:-8888}"

if [ ! -d "$VM_PACKAGE" ]; then
    echo "Error: vm-package directory not found at $VM_PACKAGE"
    exit 1
fi

echo "Starting HTTP server for VM file transfer..."
echo ""
echo "Serving files from: $VM_PACKAGE"
echo "Host address (from VM): http://10.0.2.2:$PORT"
echo ""
echo "Files available:"
ls -la "$VM_PACKAGE"
echo ""
echo "To download from Windows VM (PowerShell):"
echo "============================================"
echo "  # Create capture directory"
echo '  mkdir C:\HiberPower-Capture -Force'
echo '  cd C:\HiberPower-Capture'
echo ""
echo "  # Download files"
echo "  Invoke-WebRequest -Uri \"http://10.0.2.2:$PORT/hooks.js\" -OutFile hooks.js"
echo "  Invoke-WebRequest -Uri \"http://10.0.2.2:$PORT/capture.py\" -OutFile capture.py"
echo "  Invoke-WebRequest -Uri \"http://10.0.2.2:$PORT/windows-setup.ps1\" -OutFile setup.ps1"
echo ""
echo "  # Run setup"
echo "  .\\setup.ps1"
echo "============================================"
echo ""
echo "Press Ctrl+C to stop server"
echo ""

cd "$VM_PACKAGE"
python3 -m http.server "$PORT" --bind 0.0.0.0
