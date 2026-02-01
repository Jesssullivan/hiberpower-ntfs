#!/bin/bash
# HiberPower-NTFS: Power Loss Simulator
# Purpose: Simulate various power loss scenarios during Windows operations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOGS="$PROJECT_DIR/data/logs"
QMP_SOCK="${QMP_SOCK:-/tmp/qmp-hiberpower-*}"

# Find QMP socket if using wildcard
if [[ "$QMP_SOCK" == *"*"* ]]; then
    QMP_SOCK=$(ls $QMP_SOCK 2>/dev/null | head -1 || echo "")
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
    cat << EOF
Usage: $0 SCENARIO [OPTIONS]

Scenarios:
    immediate           Kill VM immediately (hard power loss)
    hibernate-early     Send hibernate, kill after 2 seconds
    hibernate-mid       Send hibernate, kill after 5 seconds
    hibernate-late      Send hibernate, kill after 10 seconds
    hibernate-complete  Send hibernate, wait for VM to stop
    timed SECONDS       Kill VM after SECONDS delay
    snapshot-then-kill  Create snapshot, then kill

Options:
    -s, --socket PATH   QMP socket path (default: auto-detect)
    -q, --quiet         Minimal output
    -h, --help          Show this help

Environment Variables:
    QMP_SOCK            QMP socket path

Examples:
    $0 immediate
    $0 hibernate-mid
    $0 timed 7
    $0 -s /tmp/qmp-sock hibernate-early
EOF
    exit 0
}

# QMP communication
send_qmp() {
    local cmd="$1"
    if [ -S "$QMP_SOCK" ]; then
        echo "$cmd" | timeout 5 socat - UNIX-CONNECT:"$QMP_SOCK" 2>/dev/null || true
    else
        error "QMP socket not found: $QMP_SOCK"
        return 1
    fi
}

init_qmp() {
    send_qmp '{"execute":"qmp_capabilities"}' > /dev/null
    sleep 0.5
}

# Create snapshot
create_snapshot() {
    local name="$1"
    log "Creating snapshot: $name"
    send_qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"savevm $name\"}}"
    sleep 2
}

# Send ACPI power button (triggers hibernate if configured)
send_hibernate() {
    log "Sending ACPI power button (hibernate trigger)..."
    send_qmp '{"execute":"system_powerdown"}'
}

# Kill VM
kill_vm() {
    log "POWER LOSS - Killing VM NOW!"
    send_qmp '{"execute":"quit"}'
}

# Check VM is running
check_vm() {
    if [ ! -S "$QMP_SOCK" ]; then
        error "QMP socket not found. Is the VM running?"
        error "Looking for: $QMP_SOCK"
        exit 1
    fi
}

# Scenarios
scenario_immediate() {
    log "Scenario: Immediate power loss"
    check_vm
    init_qmp
    kill_vm
}

scenario_hibernate_early() {
    log "Scenario: Hibernate interrupted (early - 2s)"
    check_vm
    init_qmp
    create_snapshot "pre-hibernate-early-$(date +%s)"
    send_hibernate
    sleep 2
    kill_vm
}

scenario_hibernate_mid() {
    log "Scenario: Hibernate interrupted (mid - 5s)"
    check_vm
    init_qmp
    create_snapshot "pre-hibernate-mid-$(date +%s)"
    send_hibernate
    sleep 5
    kill_vm
}

scenario_hibernate_late() {
    log "Scenario: Hibernate interrupted (late - 10s)"
    check_vm
    init_qmp
    create_snapshot "pre-hibernate-late-$(date +%s)"
    send_hibernate
    sleep 10
    kill_vm
}

scenario_hibernate_complete() {
    log "Scenario: Complete hibernate (no power loss)"
    check_vm
    init_qmp
    create_snapshot "pre-hibernate-complete-$(date +%s)"
    send_hibernate
    log "Waiting for VM to stop (hibernate complete)..."
    # Wait for QEMU to exit (hibernate causes clean shutdown)
    while [ -S "$QMP_SOCK" ]; do
        sleep 1
    done
    log "VM stopped (hibernate complete)"
}

scenario_timed() {
    local seconds="${1:-5}"
    log "Scenario: Timed power loss after ${seconds}s"
    check_vm
    init_qmp
    create_snapshot "pre-timed-$(date +%s)"
    log "Waiting ${seconds} seconds..."
    sleep "$seconds"
    kill_vm
}

scenario_snapshot_then_kill() {
    log "Scenario: Snapshot then kill"
    check_vm
    init_qmp
    create_snapshot "snapshot-before-kill-$(date +%s)"
    log "Snapshot created. Killing VM..."
    kill_vm
}

# Parse arguments
QUIET=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--socket) QMP_SOCK="$2"; shift 2 ;;
        -q|--quiet) QUIET=true; shift ;;
        -h|--help) usage ;;
        immediate) scenario_immediate; exit 0 ;;
        hibernate-early) scenario_hibernate_early; exit 0 ;;
        hibernate-mid) scenario_hibernate_mid; exit 0 ;;
        hibernate-late) scenario_hibernate_late; exit 0 ;;
        hibernate-complete) scenario_hibernate_complete; exit 0 ;;
        timed)
            shift
            scenario_timed "${1:-5}"
            exit 0
            ;;
        snapshot-then-kill) scenario_snapshot_then_kill; exit 0 ;;
        *)
            error "Unknown scenario: $1"
            usage
            ;;
    esac
done

# No scenario specified
usage
