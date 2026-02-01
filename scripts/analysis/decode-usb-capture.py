#!/usr/bin/env python3
"""
Decode USB/UAS capture to extract SCSI and ASMedia 0xe6 commands.
Usage: ./scripts/decode-usb-capture.py captures/file.pcapng
"""

import subprocess
import sys

def decode_cdb(cdb):
    """Decode a SCSI CDB and return human-readable info."""
    if len(cdb) < 1:
        return "Empty CDB"

    opcode = cdb[0]

    # SCSI opcodes
    scsi_ops = {
        0x00: "Test Unit Ready",
        0x03: "Request Sense",
        0x12: "Inquiry",
        0x1a: "Mode Sense(6)",
        0x1b: "Start Stop Unit",
        0x25: "Read Capacity(10)",
        0x28: "Read(10)",
        0x2a: "Write(10)",
        0x35: "Synchronize Cache",
        0x42: "Unmap",
        0x5a: "Mode Sense(10)",
        0x85: "ATA Pass-Through(16)",
        0x9e: "Service Action In (Read Capacity 16)",
        0xa0: "Report LUNs",
        0xa1: "ATA Pass-Through(12)",
        0xe6: "ASMedia NVMe Passthrough",
    }

    result = scsi_ops.get(opcode, f"Unknown(0x{opcode:02x})")

    # Decode ASMedia passthrough
    if opcode == 0xe6 and len(cdb) >= 2:
        nvme_op = cdb[1]
        nvme_ops = {
            0x00: "Delete I/O Submission Queue",
            0x01: "Create I/O Submission Queue",
            0x02: "Get Log Page",
            0x04: "Delete I/O Completion Queue",
            0x05: "Create I/O Completion Queue",
            0x06: "Identify",
            0x08: "Abort",
            0x09: "Set Features",
            0x0a: "Get Features",
            0x0c: "Async Event Request",
            0x10: "Firmware Commit",
            0x11: "Firmware Image Download",
            0x18: "Device Self-Test",
            0x80: "Format NVM",
            0x81: "Security Receive",
            0x82: "Security Send",
            0x84: "Sanitize",
        }
        nvme_name = nvme_ops.get(nvme_op, f"NVMe(0x{nvme_op:02x})")
        result = f"ASMedia → {nvme_name}"

        # Decode additional fields for common commands
        if nvme_op == 0x02 and len(cdb) >= 8:  # Get Log Page
            lid = cdb[2] | (cdb[3] << 8)
            numd = cdb[4] | (cdb[5] << 8) | (cdb[6] << 16) | (cdb[7] << 24)
            log_names = {0x01: "Error Log", 0x02: "SMART/Health", 0x03: "Firmware Slot"}
            log_name = log_names.get(lid, f"0x{lid:04x}")
            result += f" (Log={log_name}, Size={numd*4}B)"

        elif nvme_op == 0x06 and len(cdb) >= 6:  # Identify
            cns = cdb[2]
            cns_names = {0: "Namespace", 1: "Controller", 2: "Active NS List"}
            result += f" (CNS={cns_names.get(cns, cns)})"

        elif nvme_op == 0x80 and len(cdb) >= 6:  # Format NVM
            lbaf = cdb[2] & 0x0f
            ses = (cdb[2] >> 4) & 0x07
            ses_names = {0: "None", 1: "User Data Erase", 2: "Cryptographic Erase"}
            result += f" (LBAF={lbaf}, SES={ses_names.get(ses, ses)})"

    return result


def decode_sense(sense_data):
    """Decode SCSI sense data."""
    if len(sense_data) < 3:
        return "Invalid sense data"

    resp_code = sense_data[0] & 0x7f
    sense_key = sense_data[2] & 0x0f

    sense_keys = {
        0x00: "No Sense",
        0x01: "Recovered Error",
        0x02: "Not Ready",
        0x03: "Medium Error",
        0x04: "Hardware Error",
        0x05: "Illegal Request",
        0x06: "Unit Attention",
        0x07: "Data Protect",
        0x0b: "Aborted Command",
    }

    result = sense_keys.get(sense_key, f"SK=0x{sense_key:02x}")

    if len(sense_data) >= 14:
        asc = sense_data[12]
        ascq = sense_data[13]

        asc_codes = {
            (0x00, 0x00): "No additional sense",
            (0x04, 0x00): "Logical unit not ready, cause not reportable",
            (0x20, 0x00): "Invalid command operation code",
            (0x24, 0x00): "Invalid field in CDB",
            (0x3a, 0x00): "Medium not present",
            (0x3a, 0x01): "Medium not present - tray closed",
            (0x3a, 0x02): "Medium not present - tray open",
        }

        asc_desc = asc_codes.get((asc, ascq), f"ASC={asc:02x}/{ascq:02x}")
        result += f", {asc_desc}"

    return result


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <capture.pcapng>")
        sys.exit(1)

    pcap_file = sys.argv[1]

    # Extract USB capdata using tshark - try both capdata and data_fragment
    result = subprocess.run([
        'tshark', '-r', pcap_file,
        '-Y', 'usb.device_address == 28',
        '-T', 'fields', '-e', 'frame.number', '-e', 'usb.capdata', '-e', 'usb.data_fragment'
    ], capture_output=True, text=True)

    print(f"=== Decoded USB Capture: {pcap_file} ===\n")

    commands = []

    for line in result.stdout.strip().split('\n'):
        if not line:
            continue

        parts = line.split('\t')
        if len(parts) < 1:
            continue

        frame = parts[0]
        # Try capdata first, then data_fragment
        hex_data = ''
        if len(parts) >= 2 and parts[1]:
            hex_data = parts[1].replace(':', '')
        elif len(parts) >= 3 and parts[2]:
            hex_data = parts[2].replace(':', '')

        if not hex_data or len(hex_data) < 10:
            continue

        try:
            data = bytes.fromhex(hex_data)
        except:
            continue

        # Check for UAS Command IU (ID=0x01) with CDB at byte 16
        if len(data) >= 17 and data[0] == 0x01:
            cdb = data[16:]
            if len(cdb) > 0 and cdb[0] != 0:
                desc = decode_cdb(cdb)
                cdb_hex = ' '.join(f'{b:02x}' for b in cdb[:16])
                commands.append((frame, 'CMD', desc, cdb_hex))

        # Check for UAS Sense IU (ID=0x03) or Response IU (ID=0x03)
        elif len(data) >= 14 and data[0] == 0x03:
            # Check if this contains sense data
            # Sense data typically starts at offset 16 in Response IU
            if len(data) >= 32:
                sense = data[16:]
                if sense[0] in [0x70, 0x72]:  # Fixed or descriptor format
                    desc = decode_sense(sense)
                    commands.append((frame, 'SENSE', desc, ''))

    # Print commands
    for frame, cmd_type, desc, cdb_hex in commands:
        if cmd_type == 'CMD':
            print(f"Frame {frame}: {desc}")
            if 'ASMedia' in desc:
                print(f"  CDB: {cdb_hex}")
        else:
            print(f"  → {desc}")

    print(f"\n=== Total: {len([c for c in commands if c[1] == 'CMD'])} commands ===")

    # Summary
    print("\n=== Command Summary ===")
    cmd_counts = {}
    for _, cmd_type, desc, _ in commands:
        if cmd_type == 'CMD':
            key = desc.split('(')[0].strip()  # Remove parameters
            cmd_counts[key] = cmd_counts.get(key, 0) + 1

    for cmd, count in sorted(cmd_counts.items(), key=lambda x: -x[1]):
        print(f"  {count}x {cmd}")


if __name__ == '__main__':
    main()
