#!/bin/bash
# HiberPower-NTFS: Disk State Comparator
# Purpose: Compare two disk image states to identify changes from hibernation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/data/dumps/compare_$(date +%Y%m%d_%H%M%S)"

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
Usage: $0 IMAGE1 IMAGE2 [OPTIONS]

Compare two qcow2 disk images to find differences.

Arguments:
    IMAGE1              First (baseline/before) image
    IMAGE2              Second (after) image

Options:
    -o, --output DIR    Output directory
    -r, --raw           Convert to raw for detailed comparison
    -s, --sectors N     Compare first N sectors only (default: all)
    -b, --block-size N  Block size for comparison (default: 4096)
    -h, --help          Show this help

Examples:
    $0 before.qcow2 after.qcow2
    $0 baseline.qcow2 corrupted.qcow2 -r
    $0 pre-hibernate.qcow2 post-hibernate.qcow2 -s 100000
EOF
    exit 0
}

# Parse arguments
IMAGE1=""
IMAGE2=""
CONVERT_RAW=false
MAX_SECTORS=0
BLOCK_SIZE=4096

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -r|--raw) CONVERT_RAW=true; shift ;;
        -s|--sectors) MAX_SECTORS="$2"; shift 2 ;;
        -b|--block-size) BLOCK_SIZE="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*)
            error "Unknown option: $1"
            usage
            ;;
        *)
            if [ -z "$IMAGE1" ]; then
                IMAGE1="$1"
            elif [ -z "$IMAGE2" ]; then
                IMAGE2="$1"
            else
                error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [ -z "$IMAGE1" ] || [ -z "$IMAGE2" ]; then
    error "Both IMAGE1 and IMAGE2 are required"
    usage
fi

for img in "$IMAGE1" "$IMAGE2"; do
    if [ ! -f "$img" ]; then
        error "Image not found: $img"
        exit 1
    fi
done

# Setup
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/comparison_report.txt"

# Cleanup
cleanup() {
    log "Cleaning up..."
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
    [ -f "$OUTPUT_DIR/image1.raw" ] && [ "$KEEP_RAW" != true ] && rm -f "$OUTPUT_DIR/image1.raw"
    [ -f "$OUTPUT_DIR/image2.raw" ] && [ "$KEEP_RAW" != true ] && rm -f "$OUTPUT_DIR/image2.raw"
}
trap cleanup EXIT

KEEP_RAW=false

# Compare qcow2 metadata
compare_metadata() {
    section "Image Metadata Comparison"

    echo "=== Image Metadata ===" >> "$REPORT"
    echo "" >> "$REPORT"

    echo "IMAGE 1: $IMAGE1" >> "$REPORT"
    qemu-img info "$IMAGE1" >> "$REPORT"
    echo "" >> "$REPORT"

    echo "IMAGE 2: $IMAGE2" >> "$REPORT"
    qemu-img info "$IMAGE2" >> "$REPORT"
    echo "" >> "$REPORT"
}

# Quick comparison using qemu-img
quick_compare() {
    section "Quick Comparison (qemu-img)"

    echo "=== Quick Comparison ===" >> "$REPORT"

    if qemu-img compare "$IMAGE1" "$IMAGE2" 2>&1 | tee -a "$REPORT"; then
        log "Images are IDENTICAL"
        echo "Result: IDENTICAL" >> "$REPORT"
        return 0
    else
        log "Images DIFFER"
        echo "Result: DIFFER" >> "$REPORT"
        return 1
    fi
}

# Detailed comparison via NBD
detailed_compare_nbd() {
    section "Detailed Comparison via NBD"

    sudo modprobe nbd max_part=1

    # Disconnect any existing
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    sudo qemu-nbd --disconnect /dev/nbd1 2>/dev/null || true
    sleep 1

    log "Connecting images..."
    sudo qemu-nbd --connect=/dev/nbd0 --read-only "$IMAGE1"
    sudo qemu-nbd --connect=/dev/nbd1 --read-only "$IMAGE2"
    sleep 2

    # Get sizes
    local size1=$(sudo blockdev --getsize64 /dev/nbd0)
    local size2=$(sudo blockdev --getsize64 /dev/nbd1)

    echo "" >> "$REPORT"
    echo "Image 1 size: $size1 bytes" >> "$REPORT"
    echo "Image 2 size: $size2 bytes" >> "$REPORT"

    if [ "$size1" != "$size2" ]; then
        warn "Images have different sizes!"
        echo "WARNING: Size mismatch!" >> "$REPORT"
    fi

    # Calculate sectors to compare
    local total_sectors=$((size1 / BLOCK_SIZE))
    if [ "$MAX_SECTORS" -gt 0 ] && [ "$MAX_SECTORS" -lt "$total_sectors" ]; then
        total_sectors=$MAX_SECTORS
    fi

    log "Comparing $total_sectors blocks of $BLOCK_SIZE bytes..."

    echo "" >> "$REPORT"
    echo "=== Block-by-Block Comparison ===" >> "$REPORT"
    echo "Block size: $BLOCK_SIZE bytes" >> "$REPORT"
    echo "Blocks to compare: $total_sectors" >> "$REPORT"
    echo "" >> "$REPORT"

    # Compare block by block
    local diff_count=0
    local diff_blocks=""
    local progress_interval=$((total_sectors / 20))  # 5% intervals
    [ "$progress_interval" -eq 0 ] && progress_interval=1

    for ((i=0; i<total_sectors; i++)); do
        local hash1=$(sudo dd if=/dev/nbd0 bs=$BLOCK_SIZE skip=$i count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
        local hash2=$(sudo dd if=/dev/nbd1 bs=$BLOCK_SIZE skip=$i count=1 2>/dev/null | sha256sum | cut -d' ' -f1)

        if [ "$hash1" != "$hash2" ]; then
            ((diff_count++))
            if [ $diff_count -le 100 ]; then
                diff_blocks="$diff_blocks $i"
                echo "Block $i differs (offset: $((i * BLOCK_SIZE)))" >> "$REPORT"
            fi
        fi

        # Progress
        if [ $((i % progress_interval)) -eq 0 ] && [ $i -gt 0 ]; then
            local pct=$((i * 100 / total_sectors))
            echo -ne "\rProgress: $pct% ($diff_count differences found)"
        fi
    done

    echo -e "\rProgress: 100% complete                    "

    echo "" >> "$REPORT"
    echo "Total differing blocks: $diff_count" >> "$REPORT"

    if [ $diff_count -gt 100 ]; then
        echo "(Only first 100 listed above)" >> "$REPORT"
    fi

    log "Found $diff_count differing blocks"

    # Dump first few differing blocks
    if [ $diff_count -gt 0 ]; then
        section "Sample Differences"

        local first_diff=$(echo "$diff_blocks" | awk '{print $1}')
        if [ -n "$first_diff" ]; then
            log "Dumping first differing block ($first_diff)..."

            echo "" >> "$REPORT"
            echo "=== First Differing Block ($first_diff) ===" >> "$REPORT"

            echo "Image 1:" >> "$REPORT"
            sudo dd if=/dev/nbd0 bs=$BLOCK_SIZE skip=$first_diff count=1 2>/dev/null | xxd | head -32 >> "$REPORT"

            echo "" >> "$REPORT"
            echo "Image 2:" >> "$REPORT"
            sudo dd if=/dev/nbd1 bs=$BLOCK_SIZE skip=$first_diff count=1 2>/dev/null | xxd | head -32 >> "$REPORT"

            # Save full block dumps
            sudo dd if=/dev/nbd0 bs=$BLOCK_SIZE skip=$first_diff count=1 2>/dev/null > "$OUTPUT_DIR/diff_block_${first_diff}_image1.bin"
            sudo dd if=/dev/nbd1 bs=$BLOCK_SIZE skip=$first_diff count=1 2>/dev/null > "$OUTPUT_DIR/diff_block_${first_diff}_image2.bin"

            log "Block dumps saved to $OUTPUT_DIR/"
        fi
    fi
}

# Raw conversion comparison
raw_compare() {
    section "Raw Image Comparison"

    log "Converting images to raw format..."

    RAW1="$OUTPUT_DIR/image1.raw"
    RAW2="$OUTPUT_DIR/image2.raw"
    KEEP_RAW=true

    log "Converting image 1..."
    qemu-img convert -f qcow2 -O raw "$IMAGE1" "$RAW1"

    log "Converting image 2..."
    qemu-img convert -f qcow2 -O raw "$IMAGE2" "$RAW2"

    echo "" >> "$REPORT"
    echo "=== Raw Image Checksums ===" >> "$REPORT"
    local hash1=$(sha256sum "$RAW1" | cut -d' ' -f1)
    local hash2=$(sha256sum "$RAW2" | cut -d' ' -f1)

    echo "Image 1: $hash1" | tee -a "$REPORT"
    echo "Image 2: $hash2" | tee -a "$REPORT"

    if [ "$hash1" = "$hash2" ]; then
        log "Raw images are IDENTICAL"
        KEEP_RAW=false  # No need to keep if identical
    else
        log "Raw images DIFFER"

        # Find byte-level differences
        echo "" >> "$REPORT"
        echo "=== Byte-Level Differences ===" >> "$REPORT"

        local byte_diffs="$OUTPUT_DIR/byte_differences.txt"
        cmp -l "$RAW1" "$RAW2" 2>/dev/null | head -1000 > "$byte_diffs" || true

        if [ -s "$byte_diffs" ]; then
            local first_byte=$(head -1 "$byte_diffs" | awk '{print $1}')
            local total_diffs=$(wc -l < "$byte_diffs")

            echo "First differing byte: $first_byte" >> "$REPORT"
            echo "Differences found: $total_diffs (capped at 1000)" >> "$REPORT"

            log "First difference at byte: $first_byte"
            log "Byte differences saved to: $byte_diffs"
        fi
    fi
}

# Generate summary
generate_summary() {
    section "Summary"

    echo "" >> "$REPORT"
    echo "================================================" >> "$REPORT"
    echo "COMPARISON SUMMARY" >> "$REPORT"
    echo "================================================" >> "$REPORT"
    echo "Image 1: $IMAGE1" >> "$REPORT"
    echo "Image 2: $IMAGE2" >> "$REPORT"
    echo "Date: $(date)" >> "$REPORT"
    echo "" >> "$REPORT"

    log "Comparison complete!"
    log "Report: $REPORT"
    log "Output directory: $OUTPUT_DIR"

    ls -la "$OUTPUT_DIR/"
}

# Main
main() {
    log "HiberPower-NTFS Disk State Comparator"
    log "======================================"
    log "Image 1 (before): $IMAGE1"
    log "Image 2 (after):  $IMAGE2"
    log "Output: $OUTPUT_DIR"

    echo "HiberPower-NTFS Disk State Comparison Report" > "$REPORT"
    echo "=============================================" >> "$REPORT"
    echo "Date: $(date)" >> "$REPORT"
    echo "" >> "$REPORT"

    compare_metadata

    if quick_compare; then
        log "Images are identical - no further analysis needed"
        generate_summary
        exit 0
    fi

    detailed_compare_nbd

    if [ "$CONVERT_RAW" = true ]; then
        raw_compare
    fi

    generate_summary
}

main
