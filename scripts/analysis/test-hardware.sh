#!/bin/bash
# Hardware test script for ASM2362 Recovery Tool
# Run with: sudo ./scripts/test-hardware.sh /dev/sdb

set -e

DEVICE="${1:-/dev/sdb}"
TOOL="./zig-out/bin/asm2362-tool"
LOG_DIR="./data/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

echo "=============================================="
echo "ASM2362 Recovery Tool - Hardware Test Suite"
echo "=============================================="
echo "Device: $DEVICE"
echo "Timestamp: $TIMESTAMP"
echo ""

# Check device exists
if [ ! -b "$DEVICE" ]; then
    echo "ERROR: Device $DEVICE not found"
    exit 1
fi

# Check we have root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)"
    exit 1
fi

echo "=== Test 1: Device Info (lsblk) ==="
lsblk -o NAME,SIZE,MODEL,TRAN,VENDOR "$DEVICE" 2>/dev/null || true
echo ""

echo "=== Test 2: USB Device Info ==="
lsusb | grep -i "174c\|asmedia" || echo "No ASMedia USB device found"
echo ""

echo "=== Test 3: asm2362-tool probe ==="
"$TOOL" probe "$DEVICE" 2>&1 | tee "$LOG_DIR/probe_$TIMESTAMP.log"
echo ""

echo "=== Test 4: asm2362-tool identify ==="
"$TOOL" identify "$DEVICE" 2>&1 | tee "$LOG_DIR/identify_$TIMESTAMP.log"
echo ""

echo "=== Test 5: asm2362-tool smart ==="
"$TOOL" smart "$DEVICE" 2>&1 | tee "$LOG_DIR/smart_$TIMESTAMP.log"
echo ""

echo "=== Test 6: smartctl comparison (sntasmedia mode) ==="
if command -v smartctl &> /dev/null; then
    smartctl -d sntasmedia -i "$DEVICE" 2>&1 | tee "$LOG_DIR/smartctl_info_$TIMESTAMP.log"
    echo ""
    smartctl -d sntasmedia -H "$DEVICE" 2>&1 | tee -a "$LOG_DIR/smartctl_info_$TIMESTAMP.log"
else
    echo "smartctl not found, skipping comparison"
fi
echo ""

echo "=== Test 7: Raw SCSI inquiry ==="
if command -v sg_inq &> /dev/null; then
    sg_inq "$DEVICE" 2>&1 | tee "$LOG_DIR/sg_inq_$TIMESTAMP.log"
else
    echo "sg_inq not found, skipping"
fi
echo ""

echo "=============================================="
echo "Test complete. Logs saved to: $LOG_DIR/"
echo "=============================================="
ls -la "$LOG_DIR"/*_$TIMESTAMP.log 2>/dev/null || true
