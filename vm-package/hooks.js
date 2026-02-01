/**
 * Frida hooks for capturing Windows DeviceIoControl calls from SP Toolbox
 *
 * This script intercepts SCSI passthrough commands sent to the USB-NVMe bridge,
 * capturing the raw CDBs and responses for analysis and replay.
 *
 * Usage:
 *   1. Install Frida: pip install frida frida-tools
 *   2. Find SP Toolbox process ID: tasklist | findstr SP
 *   3. Attach and run: frida -p <PID> -l hooks.js
 *   4. Perform the desired operation in SP Toolbox
 *   5. Check captured commands in frida console
 *
 * Or spawn with Frida:
 *   frida -f "C:\Program Files\SP Toolbox\SPToolbox.exe" -l hooks.js --no-pause
 *
 * Output format: JSON for easy replay with asm2362-tool
 */

'use strict';

// =============================================================================
// IOCTL Codes
// =============================================================================

const IOCTL_SCSI_PASS_THROUGH = 0x4d004;
const IOCTL_SCSI_PASS_THROUGH_DIRECT = 0x4d014;
const IOCTL_ATA_PASS_THROUGH = 0x4d02c;
const IOCTL_ATA_PASS_THROUGH_DIRECT = 0x4d030;
const IOCTL_STORAGE_QUERY_PROPERTY = 0x2d1400;
const IOCTL_STORAGE_PROTOCOL_COMMAND = 0x2d0140;  // Fixed: different from QUERY_PROPERTY
const IOCTL_STORAGE_REINITIALIZE_MEDIA = 0x2d0590; // For crypto erase (Win10 19H1+)

// =============================================================================
// Global State
// =============================================================================

const capturedCommands = [];
const deviceHandles = new Map();  // Handle -> Device path mapping
const pendingAsyncOps = new Map(); // Track async operations

// =============================================================================
// Utility Functions
// =============================================================================

function bytesToHex(bytes, length) {
    let hex = '';
    const len = Math.min(length, bytes.length);
    for (let i = 0; i < len; i++) {
        hex += bytes[i].toString(16).padStart(2, '0') + ' ';
    }
    return hex.trim();
}

function readBuffer(ptr, length) {
    const buf = [];
    for (let i = 0; i < length; i++) {
        buf.push(ptr.add(i).readU8());
    }
    return buf;
}

function hexdump(ptr, length) {
    if (length === 0 || ptr.isNull()) return '';
    const safeLen = Math.min(length, 512);
    let output = '';

    try {
        for (let i = 0; i < safeLen; i += 16) {
            const lineBytes = [];
            let hex = '';
            let ascii = '';

            for (let j = 0; j < 16 && (i + j) < safeLen; j++) {
                const b = ptr.add(i + j).readU8();
                lineBytes.push(b);
                hex += b.toString(16).padStart(2, '0') + ' ';
                ascii += (b >= 32 && b < 127) ? String.fromCharCode(b) : '.';
            }

            output += i.toString(16).padStart(8, '0') + '  ' +
                      hex.padEnd(48) + '  ' + ascii + '\n';
        }
    } catch (e) {
        output = '<error reading memory: ' + e + '>';
    }

    return output;
}

function getDevicePath(handle) {
    const key = handle.toString();
    return deviceHandles.get(key) || '<unknown device>';
}

// =============================================================================
// NVMe Command Definitions
// =============================================================================

const nvmeOpcodes = {
    0x00: 'Delete I/O SQ',
    0x01: 'Create I/O SQ',
    0x02: 'Get Log Page',
    0x04: 'Delete I/O CQ',
    0x05: 'Create I/O CQ',
    0x06: 'Identify',
    0x08: 'Abort',
    0x09: 'Set Features',
    0x0a: 'Get Features',
    0x0c: 'Async Event Request',
    0x0d: 'NS Management',
    0x10: 'Firmware Commit',
    0x11: 'Firmware Download',
    0x14: 'Device Self-Test',
    0x15: 'NS Attachment',
    0x80: 'Format NVM',
    0x81: 'Security Send',
    0x82: 'Security Receive',
    0x84: 'Sanitize',
    0x86: 'Get LBA Status'
};

const senseKeyNames = {
    0x0: 'NO SENSE',
    0x1: 'RECOVERED ERROR',
    0x2: 'NOT READY',
    0x3: 'MEDIUM ERROR',
    0x4: 'HARDWARE ERROR',
    0x5: 'ILLEGAL REQUEST',
    0x6: 'UNIT ATTENTION',
    0x7: 'DATA PROTECT',
    0xb: 'ABORTED COMMAND'
};

const ascDescriptions = {
    0x00: 'No additional sense',
    0x04: 'Logical unit not ready',
    0x20: 'Invalid command operation code',
    0x24: 'Invalid field in CDB',
    0x25: 'Logical unit not supported',
    0x27: 'Write protected',
    0x28: 'Not ready to ready transition',
    0x29: 'Power on or reset',
    0x3a: 'Medium not present',
    0x44: 'Internal target failure'
};

// =============================================================================
// Structure Parsers
// =============================================================================

function parseSCSI_PASS_THROUGH(ptr) {
    const is64bit = Process.pointerSize === 8;

    if (is64bit) {
        return {
            Length: ptr.readU16(),
            ScsiStatus: ptr.add(2).readU8(),
            PathId: ptr.add(3).readU8(),
            TargetId: ptr.add(4).readU8(),
            Lun: ptr.add(5).readU8(),
            CdbLength: ptr.add(6).readU8(),
            SenseInfoLength: ptr.add(7).readU8(),
            DataIn: ptr.add(8).readU8(),
            DataTransferLength: ptr.add(12).readU32(),
            TimeOutValue: ptr.add(16).readU32(),
            DataBufferOffset: ptr.add(20).readU64(),
            SenseInfoOffset: ptr.add(28).readU32(),
            Cdb: readBuffer(ptr.add(32), 16)
        };
    } else {
        return {
            Length: ptr.readU16(),
            ScsiStatus: ptr.add(2).readU8(),
            PathId: ptr.add(3).readU8(),
            TargetId: ptr.add(4).readU8(),
            Lun: ptr.add(5).readU8(),
            CdbLength: ptr.add(6).readU8(),
            SenseInfoLength: ptr.add(7).readU8(),
            DataIn: ptr.add(8).readU8(),
            DataTransferLength: ptr.add(12).readU32(),
            TimeOutValue: ptr.add(16).readU32(),
            DataBufferOffset: ptr.add(20).readU32(),
            SenseInfoOffset: ptr.add(24).readU32(),
            Cdb: readBuffer(ptr.add(28), 16)
        };
    }
}

function parseSCSI_PASS_THROUGH_DIRECT(ptr) {
    const is64bit = Process.pointerSize === 8;

    if (is64bit) {
        return {
            Length: ptr.readU16(),
            ScsiStatus: ptr.add(2).readU8(),
            PathId: ptr.add(3).readU8(),
            TargetId: ptr.add(4).readU8(),
            Lun: ptr.add(5).readU8(),
            CdbLength: ptr.add(6).readU8(),
            SenseInfoLength: ptr.add(7).readU8(),
            DataIn: ptr.add(8).readU8(),
            DataTransferLength: ptr.add(12).readU32(),
            TimeOutValue: ptr.add(16).readU32(),
            DataBuffer: ptr.add(24).readPointer(),
            SenseInfoOffset: ptr.add(32).readU32(),
            Cdb: readBuffer(ptr.add(36), 16)
        };
    } else {
        return {
            Length: ptr.readU16(),
            ScsiStatus: ptr.add(2).readU8(),
            PathId: ptr.add(3).readU8(),
            TargetId: ptr.add(4).readU8(),
            Lun: ptr.add(5).readU8(),
            CdbLength: ptr.add(6).readU8(),
            SenseInfoLength: ptr.add(7).readU8(),
            DataIn: ptr.add(8).readU8(),
            DataTransferLength: ptr.add(12).readU32(),
            TimeOutValue: ptr.add(16).readU32(),
            DataBuffer: ptr.add(20).readPointer(),
            SenseInfoOffset: ptr.add(24).readU32(),
            Cdb: readBuffer(ptr.add(28), 16)
        };
    }
}

function parseSTORAGE_PROTOCOL_COMMAND(ptr) {
    return {
        Version: ptr.readU32(),
        Length: ptr.add(4).readU32(),
        ProtocolType: ptr.add(8).readU32(),  // 1=SCSI, 2=ATA, 3=NVMe
        Flags: ptr.add(12).readU32(),
        CommandLength: ptr.add(16).readU32(),
        ErrorInfoLength: ptr.add(20).readU32(),
        DataToDeviceTransferLength: ptr.add(24).readU32(),
        DataFromDeviceTransferLength: ptr.add(28).readU32(),
        TimeOutValue: ptr.add(32).readU32(),
        ErrorInfoOffset: ptr.add(36).readU32(),
        DataToDeviceBufferOffset: ptr.add(40).readU32(),
        DataFromDeviceBufferOffset: ptr.add(44).readU32(),
        CommandSpecificInformation: ptr.add(48).readU32(),
        ReturnStatus: ptr.add(52).readU32(),
        ErrorCode: ptr.add(56).readU32()
        // Command data follows at offset 60
    };
}

// =============================================================================
// ASMedia Command Parsing
// =============================================================================

function parseASMediaCommand(cdb, spt) {
    const nvmeOpcode = cdb[1];
    const opName = nvmeOpcodes[nvmeOpcode] || 'Unknown (0x' + nvmeOpcode.toString(16) + ')';

    console.log('\n  >>> ASMedia 0xe6 Passthrough Detected! <<<');
    console.log('  NVMe Opcode:   0x' + nvmeOpcode.toString(16).padStart(2, '0'));
    console.log('  NVMe Command:  ' + opName);

    // Decode CDW10 from CDB
    const cdw10 = cdb[3] | (cdb[6] << 16) | (cdb[7] << 24);
    console.log('  CDW10:         0x' + cdw10.toString(16).padStart(8, '0'));

    // Command-specific parsing
    if (nvmeOpcode === 0x06) {  // Identify
        const cns = cdw10 & 0xFF;
        const cnsNames = { 0: 'Namespace', 1: 'Controller', 2: 'Active NS List' };
        console.log('  Identify CNS:  ' + cns + ' (' + (cnsNames[cns] || 'Unknown') + ')');
    }
    else if (nvmeOpcode === 0x02) {  // Get Log Page
        const lid = cdw10 & 0xFF;
        const numdl = (cdw10 >> 16) & 0xFFFF;
        const lidNames = { 1: 'Error Info', 2: 'SMART/Health', 3: 'Firmware Slot' };
        console.log('  Log Page ID:   ' + lid + ' (' + (lidNames[lid] || 'Unknown') + ')');
        console.log('  NUMDL:         ' + numdl + ' (' + ((numdl + 1) * 4) + ' bytes)');
    }
    else if (nvmeOpcode === 0x80) {  // Format NVM
        const lbaf = cdw10 & 0x0F;
        const mset = (cdw10 >> 4) & 0x01;
        const pi = (cdw10 >> 5) & 0x07;
        const pil = (cdw10 >> 8) & 0x01;
        const ses = (cdw10 >> 9) & 0x07;
        const sesNames = ['No Secure Erase', 'User Data Erase', 'Cryptographic Erase'];
        console.log('  LBAF:          ' + lbaf);
        console.log('  SES:           ' + ses + ' (' + (sesNames[ses] || 'Unknown') + ')');
        console.log('  !!! DESTRUCTIVE OPERATION !!!');
    }
    else if (nvmeOpcode === 0x84) {  // Sanitize
        const sanact = cdw10 & 0x07;
        const ause = (cdw10 >> 3) & 0x01;
        const owpass = (cdw10 >> 4) & 0x0F;
        const oipbp = (cdw10 >> 8) & 0x01;
        const nodas = (cdw10 >> 9) & 0x01;
        const sanactNames = ['Reserved', 'Exit Failure Mode', 'Block Erase', 'Overwrite', 'Crypto Erase'];
        console.log('  SANACT:        ' + sanact + ' (' + (sanactNames[sanact] || 'Unknown') + ')');
        console.log('  !!! DESTRUCTIVE OPERATION !!!');
    }
    else if (nvmeOpcode === 0x09) {  // Set Features
        const fid = cdw10 & 0xFF;
        console.log('  Feature ID:    0x' + fid.toString(16).padStart(2, '0'));
    }
    else if (nvmeOpcode === 0x0a) {  // Get Features
        const fid = cdw10 & 0xFF;
        console.log('  Feature ID:    0x' + fid.toString(16).padStart(2, '0'));
    }

    // Build captured command object
    const cmd = {
        timestamp: Date.now(),
        type: 'asm2362_passthrough',
        cdb: cdb.slice(0, spt.CdbLength),
        cdb_hex: bytesToHex(cdb, spt.CdbLength),
        nvme_opcode: nvmeOpcode,
        nvme_opcode_name: opName,
        cdw10: cdw10,
        data_direction: spt.DataIn === 1 ? 'read' : spt.DataIn === 0 ? 'write' : 'none',
        data_length: spt.DataTransferLength,
        timeout_sec: spt.TimeOutValue
    };

    return cmd;
}

// =============================================================================
// Hook: CreateFileW - Track device handles
// =============================================================================

const CreateFileW = Module.findExportByName('kernel32.dll', 'CreateFileW');

if (CreateFileW) {
    Interceptor.attach(CreateFileW, {
        onEnter: function(args) {
            try {
                this.path = args[0].readUtf16String();
            } catch (e) {
                this.path = null;
            }
        },
        onLeave: function(retval) {
            const handle = retval.toInt32();
            if (handle !== -1 && this.path) {
                // Track device handles (\\.\PhysicalDriveX, \\.\ScsiX:, etc.)
                if (this.path.startsWith('\\\\.\\')) {
                    deviceHandles.set(retval.toString(), this.path);
                    console.log('[CreateFile] ' + this.path + ' -> Handle ' + retval);
                }
            }
        }
    });
    console.log('[+] Hooked CreateFileW');
}

// =============================================================================
// Hook: CloseHandle - Clean up tracked handles
// =============================================================================

const CloseHandle = Module.findExportByName('kernel32.dll', 'CloseHandle');

if (CloseHandle) {
    Interceptor.attach(CloseHandle, {
        onEnter: function(args) {
            const key = args[0].toString();
            if (deviceHandles.has(key)) {
                console.log('[CloseHandle] ' + deviceHandles.get(key));
                deviceHandles.delete(key);
            }
        }
    });
    console.log('[+] Hooked CloseHandle');
}

// =============================================================================
// Hook: DeviceIoControl - Main capture point
// =============================================================================

const DeviceIoControl = Module.findExportByName('kernel32.dll', 'DeviceIoControl');

if (DeviceIoControl) {
    Interceptor.attach(DeviceIoControl, {
        onEnter: function(args) {
            this.hDevice = args[0];
            this.dwIoControlCode = args[1].toInt32() >>> 0;
            this.lpInBuffer = args[2];
            this.nInBufferSize = args[3].toInt32();
            this.lpOutBuffer = args[4];
            this.nOutBufferSize = args[5].toInt32();
            this.lpBytesReturned = args[6];
            this.lpOverlapped = args[7];

            const code = this.dwIoControlCode;
            const devicePath = getDevicePath(this.hDevice);

            // SCSI Passthrough
            if (code === IOCTL_SCSI_PASS_THROUGH || code === IOCTL_SCSI_PASS_THROUGH_DIRECT) {
                this.isSCSI = true;
                this.isDirect = (code === IOCTL_SCSI_PASS_THROUGH_DIRECT);

                console.log('\n' + '='.repeat(60));
                console.log('[DeviceIoControl] SCSI Passthrough' + (this.isDirect ? ' DIRECT' : ''));
                console.log('='.repeat(60));
                console.log('Device:     ' + devicePath);
                console.log('Handle:     ' + this.hDevice);
                console.log('IOCTL:      0x' + code.toString(16));
                console.log('InSize:     ' + this.nInBufferSize);
                console.log('OutSize:    ' + this.nOutBufferSize);
                console.log('Async:      ' + (!this.lpOverlapped.isNull()));

                try {
                    let spt;
                    if (this.isDirect) {
                        spt = parseSCSI_PASS_THROUGH_DIRECT(this.lpInBuffer);
                    } else {
                        spt = parseSCSI_PASS_THROUGH(this.lpInBuffer);
                    }
                    this.parsedSPT = spt;

                    console.log('\nSCSI_PASS_THROUGH:');
                    console.log('  CdbLength:          ' + spt.CdbLength);
                    const dirStr = spt.DataIn === 1 ? 'READ' : spt.DataIn === 0 ? 'WRITE' : 'NONE';
                    console.log('  DataIn:             ' + spt.DataIn + ' (' + dirStr + ')');
                    console.log('  DataTransferLength: ' + spt.DataTransferLength);
                    console.log('  TimeOutValue:       ' + spt.TimeOutValue + 's');
                    console.log('  CDB:                ' + bytesToHex(spt.Cdb, spt.CdbLength));

                    // Check for ASMedia passthrough (0xe6)
                    if (spt.Cdb[0] === 0xe6) {
                        const cmd = parseASMediaCommand(spt.Cdb, spt);
                        cmd.device = devicePath;

                        // Capture write data if present
                        if (spt.DataIn === 0 && spt.DataTransferLength > 0) {
                            let dataPtr;
                            if (this.isDirect) {
                                dataPtr = spt.DataBuffer;
                            } else {
                                dataPtr = this.lpInBuffer.add(spt.DataBufferOffset);
                            }
                            if (!dataPtr.isNull()) {
                                const writeData = readBuffer(dataPtr, Math.min(512, spt.DataTransferLength));
                                cmd.write_data_hex = bytesToHex(writeData, writeData.length);
                                console.log('\nWrite Data (first ' + writeData.length + ' bytes):');
                                console.log(hexdump(dataPtr, Math.min(256, spt.DataTransferLength)));
                            }
                        }

                        capturedCommands.push(cmd);
                        console.log('\n  Command captured (#' + capturedCommands.length + ')');
                    }
                    // Check for other SCSI commands
                    else {
                        const scsiOpcodes = {
                            0x00: 'TEST UNIT READY',
                            0x03: 'REQUEST SENSE',
                            0x12: 'INQUIRY',
                            0x1a: 'MODE SENSE(6)',
                            0x25: 'READ CAPACITY(10)',
                            0x28: 'READ(10)',
                            0x2a: 'WRITE(10)',
                            0x35: 'SYNCHRONIZE CACHE(10)',
                            0x5a: 'MODE SENSE(10)',
                            0x9e: 'SERVICE ACTION IN',
                            0xa0: 'REPORT LUNS'
                        };
                        const opName = scsiOpcodes[spt.Cdb[0]] || 'Unknown SCSI';
                        console.log('\n  SCSI Command: ' + opName + ' (0x' + spt.Cdb[0].toString(16) + ')');
                    }

                } catch (e) {
                    console.log('Error parsing SCSI_PASS_THROUGH: ' + e);
                }
            }
            // Storage Protocol Command (Native NVMe)
            else if (code === IOCTL_STORAGE_PROTOCOL_COMMAND) {
                this.isStorageProtocol = true;

                console.log('\n' + '='.repeat(60));
                console.log('[DeviceIoControl] STORAGE_PROTOCOL_COMMAND');
                console.log('='.repeat(60));
                console.log('Device:     ' + devicePath);
                console.log('Handle:     ' + this.hDevice);

                try {
                    const spc = parseSTORAGE_PROTOCOL_COMMAND(this.lpInBuffer);
                    this.parsedSPC = spc;

                    const protoNames = { 1: 'SCSI', 2: 'ATA', 3: 'NVMe' };
                    console.log('Protocol:   ' + (protoNames[spc.ProtocolType] || spc.ProtocolType));
                    console.log('CmdLength:  ' + spc.CommandLength);
                    console.log('ToDevice:   ' + spc.DataToDeviceTransferLength);
                    console.log('FromDevice: ' + spc.DataFromDeviceTransferLength);

                    if (spc.ProtocolType === 3 && spc.CommandLength >= 64) {
                        // NVMe command at offset 60
                        const cmdPtr = this.lpInBuffer.add(60);
                        const nvmeCmd = readBuffer(cmdPtr, 64);
                        console.log('NVMe Cmd:   ' + bytesToHex(nvmeCmd.slice(0, 16), 16));
                    }
                } catch (e) {
                    console.log('Error parsing STORAGE_PROTOCOL_COMMAND: ' + e);
                }
            }
            // Storage Query Property
            else if (code === IOCTL_STORAGE_QUERY_PROPERTY) {
                console.log('[DeviceIoControl] STORAGE_QUERY_PROPERTY on ' + devicePath);
            }
        },

        onLeave: function(retval) {
            if (this.isSCSI && this.parsedSPT) {
                const success = retval.toInt32() !== 0;
                console.log('\nResult: ' + (success ? 'SUCCESS' : 'FAILED'));

                if (success) {
                    try {
                        let spt;
                        if (this.isDirect) {
                            spt = parseSCSI_PASS_THROUGH_DIRECT(this.lpInBuffer);
                        } else {
                            spt = parseSCSI_PASS_THROUGH(this.lpInBuffer);
                        }

                        console.log('SCSI Status: 0x' + spt.ScsiStatus.toString(16).padStart(2, '0'));

                        // Update last captured command with result
                        if (capturedCommands.length > 0) {
                            const lastCmd = capturedCommands[capturedCommands.length - 1];
                            lastCmd.scsi_status = spt.ScsiStatus;
                            lastCmd.success = (spt.ScsiStatus === 0);
                        }

                        // Parse sense data if present
                        if (spt.SenseInfoLength > 0 && spt.SenseInfoOffset > 0) {
                            const sensePtr = this.lpInBuffer.add(spt.SenseInfoOffset);
                            const senseData = readBuffer(sensePtr, spt.SenseInfoLength);
                            console.log('Sense Data: ' + bytesToHex(senseData, spt.SenseInfoLength));

                            if (senseData.length >= 14 && (senseData[0] & 0x7f) === 0x70) {
                                const senseKey = senseData[2] & 0x0f;
                                const asc = senseData[12];
                                const ascq = senseData[13];

                                const skName = senseKeyNames[senseKey] || 'UNKNOWN';
                                const ascName = ascDescriptions[asc] || 'Unknown';

                                console.log('  Sense Key: 0x' + senseKey.toString(16) + ' (' + skName + ')');
                                console.log('  ASC/ASCQ:  0x' + asc.toString(16) + '/0x' + ascq.toString(16) + ' (' + ascName + ')');

                                // Update captured command
                                if (capturedCommands.length > 0) {
                                    const lastCmd = capturedCommands[capturedCommands.length - 1];
                                    lastCmd.sense_key = senseKey;
                                    lastCmd.asc = asc;
                                    lastCmd.ascq = ascq;
                                    lastCmd.sense_description = skName + ': ' + ascName;
                                }

                                // Highlight important errors
                                if (asc === 0x3a) {
                                    console.log('  >>> MEDIUM NOT PRESENT - Controller blocking admin commands <<<');
                                } else if (asc === 0x27) {
                                    console.log('  >>> WRITE PROTECTED - Drive in read-only mode <<<');
                                } else if (asc === 0x20 || asc === 0x24) {
                                    console.log('  >>> INVALID COMMAND - Not supported by bridge/drive <<<');
                                }
                            }
                        }

                        // Capture read data
                        if (spt.DataIn === 1 && spt.DataTransferLength > 0) {
                            let dataPtr;
                            if (this.isDirect) {
                                dataPtr = spt.DataBuffer;
                            } else {
                                dataPtr = this.lpInBuffer.add(spt.DataBufferOffset);
                            }

                            if (!dataPtr.isNull()) {
                                console.log('\nRead Data (first 256 bytes):');
                                console.log(hexdump(dataPtr, Math.min(256, spt.DataTransferLength)));

                                // Store in captured command
                                if (capturedCommands.length > 0) {
                                    const lastCmd = capturedCommands[capturedCommands.length - 1];
                                    const readData = readBuffer(dataPtr, Math.min(512, spt.DataTransferLength));
                                    lastCmd.read_data_hex = bytesToHex(readData, readData.length);
                                }
                            }
                        }

                    } catch (e) {
                        console.log('Error reading result: ' + e);
                    }
                } else {
                    // Get last error
                    const GetLastError = new NativeFunction(
                        Module.findExportByName('kernel32.dll', 'GetLastError'),
                        'uint32', []
                    );
                    console.log('GetLastError: ' + GetLastError());
                }

                console.log('='.repeat(60) + '\n');
            }

            if (this.isStorageProtocol) {
                const success = retval.toInt32() !== 0;
                console.log('Result: ' + (success ? 'SUCCESS' : 'FAILED'));
                console.log('='.repeat(60) + '\n');
            }
        }
    });

    console.log('[+] Hooked DeviceIoControl');
} else {
    console.log('[-] Could not find DeviceIoControl');
}

// =============================================================================
// RPC Exports
// =============================================================================

function exportCapturedCommands() {
    const output = JSON.stringify(capturedCommands, null, 2);
    console.log('\n======== CAPTURED COMMANDS ========');
    console.log(output);
    console.log('===================================');
    console.log('Total commands captured: ' + capturedCommands.length);
    return output;
}

function saveToFile(filename) {
    const json = JSON.stringify(capturedCommands, null, 2);
    const file = new File(filename, 'w');
    file.write(json);
    file.close();
    console.log('Saved ' + capturedCommands.length + ' commands to ' + filename);
    return filename;
}

function getStatistics() {
    const stats = {
        total_commands: capturedCommands.length,
        by_opcode: {},
        successful: 0,
        failed: 0,
        medium_not_present: 0
    };

    capturedCommands.forEach(cmd => {
        const op = cmd.nvme_opcode_name || 'Other';
        stats.by_opcode[op] = (stats.by_opcode[op] || 0) + 1;

        if (cmd.success === true) stats.successful++;
        else if (cmd.success === false) stats.failed++;

        if (cmd.asc === 0x3a) stats.medium_not_present++;
    });

    return stats;
}

rpc.exports = {
    getCapturedCommands: function() {
        return capturedCommands;
    },
    exportJson: function() {
        return exportCapturedCommands();
    },
    clearCapture: function() {
        capturedCommands.length = 0;
        return 'Cleared ' + capturedCommands.length + ' commands';
    },
    getDevices: function() {
        const devices = {};
        deviceHandles.forEach((path, handle) => {
            devices[handle] = path;
        });
        return devices;
    },
    getStats: function() {
        return getStatistics();
    },
    saveToFile: saveToFile
};

// =============================================================================
// Startup Banner
// =============================================================================

console.log('');
console.log('╔══════════════════════════════════════════════════════════════╗');
console.log('║  ASM2362 Command Capture - Frida Hook v2.0                   ║');
console.log('║  HiberPower-NTFS Project                                     ║');
console.log('╠══════════════════════════════════════════════════════════════╣');
console.log('║  Monitoring:                                                 ║');
console.log('║  - IOCTL_SCSI_PASS_THROUGH / DIRECT                          ║');
console.log('║  - IOCTL_STORAGE_PROTOCOL_COMMAND                            ║');
console.log('║  - Device handle tracking (CreateFile/CloseHandle)          ║');
console.log('╠══════════════════════════════════════════════════════════════╣');
console.log('║  RPC Commands:                                               ║');
console.log('║  rpc.exports.getCapturedCommands() - Get all captured        ║');
console.log('║  rpc.exports.exportJson()          - Export as JSON          ║');
console.log('║  rpc.exports.clearCapture()        - Clear captured          ║');
console.log('║  rpc.exports.getDevices()          - List tracked devices    ║');
console.log('║  rpc.exports.getStats()            - Get capture statistics  ║');
console.log('║  rpc.exports.saveToFile(path)      - Save to JSON file       ║');
console.log('╚══════════════════════════════════════════════════════════════╝');
console.log('');
console.log('Waiting for SCSI passthrough commands...');
console.log('');
