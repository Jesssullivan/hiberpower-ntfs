#!/bin/bash
# Install Wine on Rocky Linux 10
# Run with: sudo ./scripts/setup-wine-rocky.sh

set -e

echo "=== Installing Wine on Rocky Linux 10 ==="

# Enable EPEL
dnf install -y epel-release

# For Rocky 10, Wine might be in EPEL or need WineHQ repo
# Try EPEL first
dnf install -y wine || {
    echo "Wine not in EPEL, trying WineHQ..."

    # Add WineHQ repo (RHEL/CentOS compatible)
    dnf config-manager --add-repo https://dl.winehq.org/wine-builds/centos/9/winehq.repo

    # Note: Rocky 10 might need Rocky 9 repo as workaround
    # or use Flatpak
    dnf install -y winehq-stable || dnf install -y winehq-devel
}

# Initialize Wine prefix
echo "Initializing Wine prefix..."
su - $SUDO_USER -c "WINEARCH=win64 WINEPREFIX=~/.wine winecfg /v"

echo ""
echo "=== Wine Installation Complete ==="
wine --version
