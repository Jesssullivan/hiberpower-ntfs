#!/bin/bash
# Combined setup: Install Wine + Start USB capture
# Run with: sudo ./scripts/setup-and-capture.sh

set -e

echo "=========================================="
echo "  HiberPower-NTFS: Setup & USB Capture"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Step 1: Install Wine
echo "[1/4] Installing Wine..."
if ! command -v wine &> /dev/null; then
    dnf install -y epel-release 2>/dev/null || true
    dnf install -y wine || {
        echo "Wine not in repos, trying WineHQ..."
        dnf config-manager --add-repo https://dl.winehq.org/wine-builds/centos/9/winehq.repo 2>/dev/null || true
        dnf install -y winehq-stable || dnf install -y wine-core wine-common
    }
    echo "Wine installed: $(wine --version 2>/dev/null || echo 'check installation')"
else
    echo "Wine already installed: $(wine --version)"
fi

# Step 2: Load usbmon
echo ""
echo "[2/4] Loading usbmon kernel module..."
modprobe usbmon
echo "usbmon loaded"

# Step 3: Find ASM2362
echo ""
echo "[3/4] Finding ASM2362 device..."
USB_INFO=$(lsusb | grep "174c:2362" || true)

if [ -z "$USB_INFO" ]; then
    echo "WARNING: ASM2362 device not found!"
    echo "Connect the USB-NVMe enclosure and re-run"
else
    BUS=$(echo "$USB_INFO" | sed -n 's/Bus \([0-9]*\).*/\1/p')
    DEVICE=$(echo "$USB_INFO" | sed -n 's/.*Device \([0-9]*\).*/\1/p')
    echo "Found: $USB_INFO"
    echo "  Bus: $BUS, Device: $DEVICE"

    # Create captures directory
    CAPTURE_DIR="/home/jsullivan2/git/hiberpower-ntfs/captures"
    mkdir -p "$CAPTURE_DIR"
    chown -R jsullivan2:jsullivan2 "$CAPTURE_DIR"

    USBMON="usbmon${BUS#0}"
    DEVICE_NUM=$(echo "$DEVICE" | sed 's/^0*//')

    echo ""
    echo "[4/4] Ready for capture!"
    echo ""
    echo "=========================================="
    echo "  USB Capture Commands"
    echo "=========================================="
    echo ""
    echo "# Start background capture (60 seconds):"
    echo "sudo tshark -i $USBMON -a duration:60 -w $CAPTURE_DIR/capture-\$(date +%H%M%S).pcapng &"
    echo ""
    echo "# Then run SP Toolbox under Wine:"
    echo "wine 'downloads/SP_Toolbox_V4.1.2-20251128/SP Toolbox.exe'"
    echo ""
    echo "# Or start interactive capture:"
    echo "sudo wireshark -i $USBMON -k -Y 'usb.device_address == $DEVICE_NUM'"
    echo ""
fi

echo ""
echo "=========================================="
echo "  Wine Test"
echo "=========================================="
echo ""
echo "# Initialize Wine prefix (run as your user, not root):"
echo "su - jsullivan2 -c 'WINEARCH=win64 wineboot'"
echo ""
echo "# Then test SP Toolbox:"
echo "su - jsullivan2 -c 'wine downloads/SP_Toolbox_V4.1.2-20251128/SP\\ Toolbox.exe'"
