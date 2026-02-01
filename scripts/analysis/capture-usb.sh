#!/bin/bash
# Capture USB traffic from ASM2362 device
# Run with: sudo ./scripts/capture-usb.sh [duration_seconds]
#
# This captures SCSI/NVMe commands sent through the USB-NVMe bridge

set -e

DURATION=${1:-60}
OUTPUT_DIR="captures"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PCAP_FILE="$OUTPUT_DIR/asm2362-$TIMESTAMP.pcapng"

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "=== ASM2362 USB Capture ==="
echo ""

# Load usbmon if not loaded
if ! lsmod | grep -q usbmon; then
    echo "[1/4] Loading usbmon kernel module..."
    modprobe usbmon
else
    echo "[1/4] usbmon already loaded"
fi

# Find ASM2362 device
echo "[2/4] Finding ASM2362 device..."
USB_INFO=$(lsusb | grep "174c:2362" || true)

if [ -z "$USB_INFO" ]; then
    echo "ERROR: ASM2362 device not found!"
    echo "Please connect the USB-NVMe enclosure"
    exit 1
fi

# Extract bus and device number
BUS=$(echo "$USB_INFO" | sed -n 's/Bus \([0-9]*\).*/\1/p')
DEVICE=$(echo "$USB_INFO" | sed -n 's/.*Device \([0-9]*\).*/\1/p')

echo "  Found: $USB_INFO"
echo "  Bus: $BUS, Device: $DEVICE"

# Determine usbmon interface
USBMON="usbmon${BUS#0}"  # Remove leading zero if present
echo "  Capture interface: $USBMON"

# Set up display filter for device
DEVICE_NUM=$(echo "$DEVICE" | sed 's/^0*//')  # Remove leading zeros
FILTER="usb.device_address == $DEVICE_NUM"

echo ""
echo "[3/4] Starting capture for $DURATION seconds..."
echo "  Output: $PCAP_FILE"
echo "  Filter: $FILTER"
echo ""
echo ">>> NOW: Run SP Toolbox operations in another terminal <<<"
echo ""

# Capture with tshark
tshark -i "$USBMON" -a duration:$DURATION -w "$PCAP_FILE" 2>/dev/null

echo ""
echo "[4/4] Capture complete!"
echo ""

# Analyze the capture
echo "=== Quick Analysis ==="
echo ""

echo "Total packets captured:"
tshark -r "$PCAP_FILE" -Y "$FILTER" 2>/dev/null | wc -l

echo ""
echo "SCSI command packets (CBW/CSW):"
tshark -r "$PCAP_FILE" -Y "$FILTER and usb.bInterfaceClass == 8" 2>/dev/null | head -20

echo ""
echo "Looking for 0xe6 CDB patterns (ASMedia passthrough):"
# Extract USB bulk data and look for 0xe6
tshark -r "$PCAP_FILE" -Y "$FILTER" -T fields -e usb.capdata 2>/dev/null | \
    grep -i "^e6" | head -10 || echo "  (none found - run SP Toolbox during capture)"

echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Open capture in Wireshark:"
echo "   wireshark $PCAP_FILE"
echo ""
echo "2. Apply filter: $FILTER"
echo ""
echo "3. Look for SCSI CDBs starting with 0xe6"
echo ""
echo "4. Document any Format NVM (0x80) or Sanitize (0x84) commands"
