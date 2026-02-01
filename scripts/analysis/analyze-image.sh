#!/bin/bash
# HiberPower-NTFS: Disk Image Analyzer
# Purpose: Analyze qcow2 disk images for NTFS hibernate state and corruption

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/data/dumps"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

usage() {
    cat << EOF
Usage: $0 IMAGE [OPTIONS]

Arguments:
    IMAGE               Path to qcow2 disk image

Options:
    -o, --output DIR    Output directory (default: $OUTPUT_DIR)
    -v, --verbose       Verbose output
    -k, --keep-mounted  Keep NBD connected after analysis
    -h, --help          Show this help

Examples:
    $0 nvme-test-256g.qcow2
    $0 /path/to/image.qcow2 -o /tmp/analysis
    $0 corrupted.qcow2 -v
EOF
    exit 0
}

# Parse arguments
IMAGE=""
VERBOSE=false
KEEP_MOUNTED=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -k|--keep-mounted) KEEP_MOUNTED=true; shift ;;
        -h|--help) usage ;;
        -*) error "Unknown option: $1"; usage ;;
        *)
            if [ -z "$IMAGE" ]; then
                IMAGE="$1"
            else
                error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$IMAGE" ]; then
    error "Image path required"
    usage
fi

if [ ! -f "$IMAGE" ]; then
    error "Image not found: $IMAGE"
    exit 1
fi

# Setup
mkdir -p "$OUTPUT_DIR"
NBD_DEV="/dev/nbd0"
REPORT_FILE="$OUTPUT_DIR/analysis_${TIMESTAMP}.txt"

# Cleanup function
cleanup() {
    if [ "$KEEP_MOUNTED" = false ]; then
        log "Disconnecting NBD..."
        sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Connect image via NBD
connect_nbd() {
    section "Connecting Image via NBD"

    sudo modprobe nbd max_part=16

    # Disconnect if already connected
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sleep 1

    log "Connecting: $IMAGE"
    sudo qemu-nbd --connect="$NBD_DEV" --read-only "$IMAGE"
    sleep 2

    if [ ! -b "$NBD_DEV" ]; then
        error "Failed to connect NBD device"
        exit 1
    fi

    log "Connected to $NBD_DEV"
}

# Analyze image metadata
analyze_qcow2() {
    section "QCOW2 Image Information"

    qemu-img info "$IMAGE" | tee -a "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"
    echo "Snapshot list:" >> "$REPORT_FILE"
    qemu-img snapshot -l "$IMAGE" 2>/dev/null | tee -a "$REPORT_FILE" || echo "No snapshots found" | tee -a "$REPORT_FILE"
}

# Analyze partition table
analyze_partitions() {
    section "Partition Table"

    sudo fdisk -l "$NBD_DEV" 2>&1 | tee -a "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"
    echo "Block device info:" >> "$REPORT_FILE"
    sudo blkid "$NBD_DEV"* 2>/dev/null | tee -a "$REPORT_FILE" || echo "No partitions detected"
}

# Dump first sectors
dump_boot_sector() {
    section "Boot Sector Analysis"

    local hex_file="$OUTPUT_DIR/boot_sector_${TIMESTAMP}.hex"

    # First 512 bytes (MBR or GPT protective MBR)
    log "Dumping first 512 bytes..."
    sudo dd if="$NBD_DEV" bs=512 count=1 2>/dev/null | xxd > "$hex_file"

    echo "First 16 lines of boot sector:" >> "$REPORT_FILE"
    head -16 "$hex_file" >> "$REPORT_FILE"

    # Check for GPT signature at LBA 1
    log "Checking for GPT signature..."
    local gpt_sig=$(sudo dd if="$NBD_DEV" bs=512 skip=1 count=1 2>/dev/null | head -c 8)
    if [ "$gpt_sig" = "EFI PART" ]; then
        echo "Partition type: GPT" | tee -a "$REPORT_FILE"
    else
        echo "Partition type: MBR or unknown" | tee -a "$REPORT_FILE"
    fi

    log "Boot sector saved to: $hex_file"
}

# Analyze NTFS partitions
analyze_ntfs() {
    section "NTFS Partition Analysis"

    for part in ${NBD_DEV}p*; do
        if [ ! -b "$part" ]; then
            continue
        fi

        local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || true)

        if [ "$fs_type" != "ntfs" ]; then
            [ "$VERBOSE" = true ] && log "Skipping $part (type: ${fs_type:-unknown})"
            continue
        fi

        log "Analyzing NTFS partition: $part"
        echo "" >> "$REPORT_FILE"
        echo "=== NTFS Partition: $part ===" >> "$REPORT_FILE"

        # NTFS-3G probe for hibernate flag
        echo "" >> "$REPORT_FILE"
        echo "Hibernate status:" >> "$REPORT_FILE"
        if sudo ntfs-3g.probe --readonly "$part" 2>&1 | tee -a "$REPORT_FILE"; then
            log "NTFS appears clean"
        else
            warn "NTFS may have hibernate flag or errors"
        fi

        # NTFS info
        echo "" >> "$REPORT_FILE"
        echo "NTFS Volume Info:" >> "$REPORT_FILE"
        sudo ntfsinfo -m "$part" 2>&1 | head -50 >> "$REPORT_FILE" || echo "ntfsinfo failed" >> "$REPORT_FILE"

        # Check for hiberfil.sys
        echo "" >> "$REPORT_FILE"
        echo "Checking for hiberfil.sys:" >> "$REPORT_FILE"

        local mount_point="/tmp/ntfs-analyze-$$"
        mkdir -p "$mount_point"

        if sudo ntfs-3g -o ro "$part" "$mount_point" 2>/dev/null; then
            if [ -f "$mount_point/hiberfil.sys" ]; then
                local hib_size=$(stat -c%s "$mount_point/hiberfil.sys" 2>/dev/null || echo "unknown")
                echo "  FOUND: hiberfil.sys ($hib_size bytes)" | tee -a "$REPORT_FILE"
                warn "hiberfil.sys present - Windows was hibernated!"

                # Analyze hiberfil.sys header
                echo "" >> "$REPORT_FILE"
                echo "hiberfil.sys header (first 64 bytes):" >> "$REPORT_FILE"
                sudo xxd -l 64 "$mount_point/hiberfil.sys" >> "$REPORT_FILE"
            else
                echo "  NOT FOUND: hiberfil.sys" | tee -a "$REPORT_FILE"
            fi

            # Check pagefile too
            if [ -f "$mount_point/pagefile.sys" ]; then
                local page_size=$(stat -c%s "$mount_point/pagefile.sys" 2>/dev/null || echo "unknown")
                echo "  FOUND: pagefile.sys ($page_size bytes)" >> "$REPORT_FILE"
            fi

            sudo umount "$mount_point"
        else
            echo "  Could not mount partition (may be hibernated)" | tee -a "$REPORT_FILE"
        fi

        rmdir "$mount_point" 2>/dev/null || true
    done
}

# Scan for corruption patterns
scan_corruption() {
    section "Corruption Pattern Scan"

    log "Scanning for known corruption patterns..."

    # Check for all-zeros sectors in critical areas
    echo "" >> "$REPORT_FILE"
    echo "Critical sector checks:" >> "$REPORT_FILE"

    # GPT header
    local gpt_header=$(sudo dd if="$NBD_DEV" bs=512 skip=1 count=1 2>/dev/null | xxd -p | tr -d '\n')
    if [[ "$gpt_header" == "0"* ]] && [[ ${#gpt_header} -gt 100 ]] && [[ "$gpt_header" =~ ^0+$ ]]; then
        echo "  WARNING: GPT header appears zeroed!" | tee -a "$REPORT_FILE"
    else
        echo "  GPT header: present" >> "$REPORT_FILE"
    fi

    # Check for repeated patterns (potential corruption)
    echo "" >> "$REPORT_FILE"
    echo "Pattern analysis (first 1MB):" >> "$REPORT_FILE"

    local unique_sectors=$(sudo dd if="$NBD_DEV" bs=512 count=2048 2>/dev/null | \
        split -b 512 --filter='sha256sum' | sort -u | wc -l)
    echo "  Unique sectors in first 1MB: $unique_sectors / 2048" >> "$REPORT_FILE"

    if [ "$unique_sectors" -lt 10 ]; then
        warn "Very few unique sectors - possible corruption or uninitialized"
    fi
}

# Generate summary
generate_summary() {
    section "Analysis Summary"

    echo "" >> "$REPORT_FILE"
    echo "================================================" >> "$REPORT_FILE"
    echo "ANALYSIS SUMMARY" >> "$REPORT_FILE"
    echo "================================================" >> "$REPORT_FILE"
    echo "Image: $IMAGE" >> "$REPORT_FILE"
    echo "Date: $(date)" >> "$REPORT_FILE"
    echo "Report: $REPORT_FILE" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Check for key indicators
    if grep -q "hiberfil.sys" "$REPORT_FILE" 2>/dev/null; then
        echo "HIBERNATE STATUS: Hibernated (hiberfil.sys present)" >> "$REPORT_FILE"
    else
        echo "HIBERNATE STATUS: Unknown or not hibernated" >> "$REPORT_FILE"
    fi

    if grep -qi "could not mount" "$REPORT_FILE" 2>/dev/null; then
        echo "MOUNT STATUS: Failed to mount NTFS (possible hibernate lock)" >> "$REPORT_FILE"
    fi

    echo "" >> "$REPORT_FILE"
    log "Report saved to: $REPORT_FILE"
}

# Main
main() {
    log "HiberPower-NTFS Disk Image Analyzer"
    log "===================================="
    log "Image: $IMAGE"
    log "Output: $OUTPUT_DIR"

    echo "HiberPower-NTFS Disk Image Analysis Report" > "$REPORT_FILE"
    echo "==========================================" >> "$REPORT_FILE"
    echo "Image: $IMAGE" >> "$REPORT_FILE"
    echo "Date: $(date)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    analyze_qcow2
    connect_nbd
    analyze_partitions
    dump_boot_sector
    analyze_ntfs
    scan_corruption
    generate_summary

    echo ""
    log "Analysis complete!"
    log "Full report: $REPORT_FILE"

    if [ "$KEEP_MOUNTED" = true ]; then
        warn "NBD device kept connected at $NBD_DEV"
        warn "Run 'sudo qemu-nbd --disconnect $NBD_DEV' when done"
    fi
}

main
