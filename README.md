# ASM2362 NVMe Research Toys

Experimental research into recovering NVMe SSDs exhibiting firmware-level write protection after FTL corruption. **This is a project**

I used this nvme stick and the ASM2362 every day all day between 2017 and 2020 for all my laptop computing.  It happpily ran Tails, ubuntu budgie, and even windows via a little usb 3 enclosure velcroed to my laptop during this time.  I haven't thrown it away because I am stubborn, I think that it should continue to work forever. 


- 256GB Silicon Power NVMe SSD connected via ASMedia ASM2362 USB bridge now exhibits silent write failure after a Windows hibernate + power loss event.
- It is impossible to write zeros to this drive.  Amazing!  Never seen this before. 


| Operation | Reports | Actual |
|-----------|---------|--------|
| `dd if=/dev/zero of=/dev/sdb` | Success | Data unchanged |
| `wipefs --all` | Success | Signatures remain |
| SCSI READ | Success | Data readable |
| SCSI WRITE | Success | Silent failure |
| NVMe admin commands | Fail | "Medium not present" (ASC=0x3A) |

Standard Linux disk tools (fdisk, gdisk, blkdiscard, sg_format) all fail to modify the drive despite reporting success.

---

## Hardware Stack

```
+---------------------------------------------+
|  NVMe SSD: Silicon Power 256GB              |
|  Controller: Phison PS5012-E12 (likely)     |
|  State: FTL corrupted, read-only mode       |
+----------------------+----------------------+
                       | M.2 PCIe
+----------------------+----------------------+
|  USB Bridge: ASMedia ASM2362                |
|  VID:PID = 0x174c:0x2362                    |
|  Passthrough: 0xe6 CDB (NVMe tunneling)     |
+----------------------+----------------------+
                       | USB 3.1 Gen 2
+----------------------+----------------------+
|  Linux: UAS driver -> /dev/sdb              |
+---------------------------------------------+
```

---

## Technical Reference

### SMART Critical Warning Bits

The NVMe SMART/Health log contains critical warning flags at byte offset 0:

| Bit | Mask | Meaning |
|-----|------|---------|
| 0 | 0x01 | Available spare capacity below threshold |
| 1 | 0x02 | Temperature exceeded threshold |
| 2 | 0x04 | NVM subsystem reliability degraded |
| **3** | **0x08** | **Media placed in read-only mode** |
| 4 | 0x10 | Volatile memory backup failed |

**Bit 3 (0x08) is our target.** When set, the controller has entered firmware-level protection mode. Per NVMe spec:

> "The media has been placed in read only mode. Vendor specific recovery may be required."

### SCSI Sense Data

When NVMe admin commands fail through the USB bridge:

| Field | Value | Meaning |
|-------|-------|---------|
| Sense Key | 0x02 | NOT READY |
| ASC | 0x3A | MEDIUM NOT PRESENT |
| ASCQ | 0x00 | - |

This indicates the NVMe controller is rejecting commands at firmware level, not the USB bridge.

### ASM2362 Passthrough Protocol

The ASMedia ASM2362 uses a proprietary 16-byte CDB with opcode `0xe6` to tunnel NVMe commands:

```
Byte 0:     0xe6        ASMedia passthrough opcode
Byte 1:     NVMe opcode (0x06=Identify, 0x02=GetLog, etc.)
Byte 2:     Reserved
Byte 3:     CDW10[7:0]
Byte 4-5:   Reserved
Byte 6:     CDW10[23:16]
Byte 7:     CDW10[31:24]
Bytes 8-11: CDW13 (big-endian)
Bytes 12-15: CDW12 (big-endian)
```

**Limitation**: CDW11, CDW14, CDW15 cannot be passed, restricting some admin commands.

### NVMe Opcodes Implemented

| Opcode | Command | Purpose |
|--------|---------|---------|
| 0x02 | Get Log Page | Read SMART, error logs |
| 0x06 | Identify | Controller/namespace info |
| 0x09 | Set Features | Modify controller settings |
| 0x0A | Get Features | Query controller settings |
| 0x80 | Format NVM | Reformat namespace |
| 0x81 | Security Receive | Query security state |
| 0x82 | Security Send | Modify security state |
| 0x84 | Sanitize | Secure erase |

### Write Protection Feature (FID 0x84)

NVMe 1.4+ namespace write protection states:

| Value | State | Persistence |
|-------|-------|-------------|
| 0x00 | No Write Protect | N/A |
| 0x01 | Write Protect | Survives power cycles |
| 0x02 | Write Protect Until Power Cycle | Clears on reboot |
| 0x03 | Permanent Write Protect | **Irreversible** |

### Security Protocols

| Protocol | Purpose |
|----------|---------|
| 0x00 | Discovery - list supported protocols |
| 0xEF | ATA Device Server Password |
| 0x01-0x06 | TCG Opal |

---

## Hypothesis

We believe SMART Critical Warning Bit 3 (0x08) is set, causing:

1. **Read path functional** - FTL read mappings intact
2. **Write path blocked** - FTL refuses to update NAND
3. **Admin commands blocked** - "Medium not present"

Recovery requires a vendor-specific command sequence to clear this protection state.

### Three Unlock Approaches Under Investigation

**Option A: Security Protocol Unlock**
```
1. Security Receive (0x82) - Query security state
   Protocol 0x00: Get supported protocols
   Protocol 0xEF: Get ATA security status

2. Security Send (0x81) - Clear security state
   Protocol 0xEF + SP Specific 0x0001/0x0002

3. Format NVM (0x80) - After unlock succeeds
```

**Option B: Set Features Unlock**
```
1. Get Features (0x0A) FID=0x84 - Query write protect status
2. Set Features (0x09) FID=0x84 CDW11=0 - Clear write protect
3. Format NVM (0x80) - After protection cleared
```

**Option C: Vendor-Specific Phison Command**
```
Unknown opcode sequence to enter "service mode" and clear FTL corruption flag.
Requires capturing SP Toolbox "Secure Erase" operation.
```

---

## Silent Write Failure Evidence

### Test 1: dd to Sector 0
```
$ sudo dd if=/dev/zero of=/dev/sdb bs=512 count=1 conv=fsync oflag=direct
512 bytes copied

$ sudo xxd -l 64 /dev/sdb
00000000: 33c0 8ed0 bc00 7c8e...  # MBR boot code - NOT ZEROS
```

### Test 2: wipefs
```
$ sudo wipefs --all --force /dev/sdb
/dev/sdb: 8 bytes were erased at offset 0x200 (gpt)

$ sudo xxd -s 512 -l 8 /dev/sdb
00000200: 4546 4920 5041 5254  # "EFI PART" still present
```

### Device Characteristics
| Property | Value |
|----------|-------|
| Vendor | SPCC M.2 (Silicon Power) |
| Capacity | 256 GB (500118192 sectors) |
| Sector Size | 512 bytes |
| Connection | USB via UAS driver |
| WP Flag | OFF (reports writable) |
| blockdev --getro | 0 |

---

## Building

Requires Zig 0.13.0 or later.

```bash
zig build
sudo ./zig-out/bin/asm2362-tool probe /dev/sdX
sudo ./zig-out/bin/asm2362-tool identify /dev/sdX
sudo ./zig-out/bin/asm2362-tool smart /dev/sdX --json
```

## Running Tests

```bash
zig build test
zig build test-all
```



---

## Investigation Tracks

**Track A - Windows VM + Frida**: Capture DeviceIoControl calls from SP Toolbox to extract vendor command sequences.

**Track B - Wine + Frida**: Run SP Toolbox under Wine to avoid VM complexity.

**Track C - USB Protocol Capture**: Use usbmon/Wireshark to capture raw SCSI CDBs.

**Track D - Binary Analysis**: Static analysis of SP Toolbox with Ghidra/IDA to find 0xe6 CDB construction.

**Track E - Native M.2**: Bypass USB bridge by installing drive directly in M.2 slot.

---

## Project Structure

```
src/                    Zig tool source
  main.zig             CLI entry point
  scsi/                SG_IO wrapper, sense parsing
  asm2362/             0xe6 passthrough implementation
  nvme/                NVMe command implementations
  frida/               Windows hooks and capture

scripts/
  vm/                  Windows VM management
  analysis/            USB capture, decode, comparison
  setup/               Environment configuration

docs/
  notes/               Research findings
  analysis/            Binary analysis findings
  research/            Unlock sequence hypotheses
  workflows/           Procedure documentation
```

See [docs/INDEX.md](docs/INDEX.md) for documentation navigation.

---

## Key SP Toolbox Methods (RE Target)

| Method | RVA | Purpose |
|--------|-----|---------|
| `DoASMedia_SCSICommand` | 0x13560 | Builds 0xe6 CDB, calls DeviceIoControl |
| `Security_Erase` | 0x16090 | Erase gate logic |
| `do_Erase` | 0x163fc | Actual erase execution |

---

## References

- [NVMe Base Specification 2.0](https://nvmexpress.org/specifications/)
- [NVMe SMART Critical Warning](https://nvmexpress.org/wp-content/uploads/NVM-Express-Base-Specification-2.0e-2024.07.29-Ratified.pdf) - Section 5.14.1.2
- [TCG Opal and NVMe](https://nvmexpress.org/wp-content/uploads/TCGandNVMe_Joint_White_Paper-TCG_Storage_Opal_and_NVMe_FINAL.pdf)
- [nvme-cli](https://github.com/linux-nvme/nvme-cli)
- [sedutil](https://github.com/Drive-Trust-Alliance/sedutil)
