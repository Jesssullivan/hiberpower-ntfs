#!/bin/bash
# Install tools for SP Toolbox analysis
# Run with: sudo ./scripts/install-analysis-tools.sh

set -e

echo "=== Installing Analysis Tools ==="

# Core tools
echo "[1/5] Installing Wireshark..."
dnf install -y wireshark wireshark-cli

# Wine for running Windows apps
echo "[2/5] Installing Wine..."
dnf install -y wine

# Radare2 for binary analysis
echo "[3/5] Installing Radare2..."
dnf install -y radare2

# Python tools
echo "[4/5] Installing Python pip..."
dnf install -y python3-pip

# .NET disassembly (SP Toolbox is .NET)
echo "[5/5] Installing Mono tools..."
dnf install -y mono-devel || echo "Mono not available, will use alternatives"

echo ""
echo "=== Installing Python packages ==="
pip3 install --user pefile capstone frida frida-tools

echo ""
echo "=== Downloading Ghidra ==="
GHIDRA_VERSION="11.2.1"
GHIDRA_DATE="20241105"
if [ ! -d "/opt/ghidra" ]; then
    cd /tmp
    wget -q "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip" -O ghidra.zip
    unzip -q ghidra.zip -d /opt/
    mv /opt/ghidra_* /opt/ghidra
    ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidra
    echo "Ghidra installed to /opt/ghidra"
else
    echo "Ghidra already installed"
fi

echo ""
echo "=== Downloading ILSpy (.NET decompiler) ==="
if [ ! -f "/usr/local/bin/ilspycmd" ]; then
    # ILSpy command-line version
    dotnet tool install -g ilspycmd 2>/dev/null || echo "ilspycmd requires .NET SDK"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Available tools:"
echo "  wireshark   - USB/network capture"
echo "  wine        - Run Windows apps"
echo "  r2 / radare2 - Binary analysis"
echo "  ghidra      - Decompiler (run: ghidra)"
echo "  monodis     - .NET disassembler"
echo "  frida       - Dynamic instrumentation"
