# NVMe FTL Corruption Unlock Sequence Research

## Objective

Document the exact command sequence required to unlock a Phison NVMe controller
that has entered read-only protection mode after FTL corruption.

## Current Understanding

### The Protection Mechanism

When the Phison PS5012-E12 (or similar) controller detects FTL corruption:

1. **Read path**: Continues to function (FTL read mappings remain valid)
2. **Write path**: Blocked at firmware level (FTL refuses to update)
3. **Admin path**: Blocked with "Medium not present" (ASC=0x3A)
4. **SMART Warning**: Bit 3 (0x08) set - "Media placed in read-only mode"

### Why Standard Commands Fail

| Command | Via USB Bridge | Result | Reason |
|---------|---------------|--------|--------|
| NVMe Format | 0xe6 + 0x80 | Medium not present | Admin path blocked |
| NVMe Sanitize | 0xe6 + 0x84 | Medium not present | Admin path blocked |
| NVMe Identify | 0xe6 + 0x06 | Medium not present | Admin path blocked |
| SCSI Write | Standard | Silent failure | Write path blocked |
| SCSI Read | Standard | Success | Read path still works |

## Hypothesis: Unlock Sequence

Based on decompilation of SP Toolbox.exe, the unlock may involve:

### Option A: Security Protocol Unlock

```
1. Security Receive (0x82) - Query security state
   - Protocol 0x00: Get supported protocols
   - Protocol 0xEF: Get ATA security status

2. Security Send (0x81) - Clear security state
   - Protocol 0xEF: ATA Device Server Password
   - SP Specific 0x0001: Set password (to known value)
   - Then SP Specific 0x0002: Unlock with password

3. Format NVM (0x80) - After unlock succeeds
   - SES=1 (User Data Erase)
   - LBAF=0 (512-byte sectors)
```

### Option B: Set Features Unlock

```
1. Get Features (0x0A) - Query write protect status
   - FID 0x84: Namespace Write Protect Config

2. Set Features (0x09) - Clear write protect
   - FID 0x84: Namespace Write Protect Config
   - CDW11 = 0: No write protect
   - SV = 1: Save persistently

3. Format NVM (0x80) - After protection cleared
```

### Option C: Vendor-Specific Command

Phison controllers may use proprietary commands not in NVMe spec:

```
1. Unknown vendor command to enter "service mode"
2. Clear FTL corruption flag
3. Allow normal admin commands
```

This would require capturing SP Toolbox "Secure Erase" or "Restore Factory" operation.

## Test Plan

### Phase 1: Query Current State

```bash
# Test Get Features for write protection status
sudo ./zig-out/bin/asm2362-tool get-features 0x84 /dev/sdb

# Test Security Receive for security state
sudo ./zig-out/bin/asm2362-tool security-recv 0x00 /dev/sdb
sudo ./zig-out/bin/asm2362-tool security-recv 0xef /dev/sdb
```

### Phase 2: Capture SP Toolbox Sequence

```bash
# Start USB capture
sudo tshark -i usbmon1 -w captures/sp-secure-erase.pcapng &

# Run SP Toolbox "Secure Erase" via Wine/VM
# ... perform operation ...

# Stop capture and decode
./scripts/decode-usb-capture.py captures/sp-secure-erase.pcapng
```

### Phase 3: Replay and Test

```bash
# Implement replay command for captured sequence
sudo ./zig-out/bin/asm2362-tool replay captures/sp-secure-erase.json

# Test if admin commands now work
sudo ./zig-out/bin/asm2362-tool identify /dev/sdb
```

## Findings Log

### Date: [TBD]

**Tested**: [Command/Sequence]
**Result**: [Success/Failure]
**Details**: [Sense data, observed behavior]

---

## Verification Checklist

When the unlock sequence is discovered:

- [ ] Document exact CDB bytes for each command in sequence
- [ ] Document required timing between commands (if any)
- [ ] Verify Identify Controller succeeds after unlock
- [ ] Verify Format NVM succeeds after unlock
- [ ] Verify write operations succeed after format
- [ ] Test on fresh "Medium not present" state (cold boot)
- [ ] Create automated test in asm2362-tool
- [ ] Update README with success documentation

## References

- NVMe Base Specification 2.0 - Security Send/Receive commands
- ATA Command Set 4 (ACS-4) - Security feature set
- SP Toolbox.exe decompilation - RVA 0x163fc (do_Erase)
- Phison PS5012-E12 programming guide (if obtainable)
