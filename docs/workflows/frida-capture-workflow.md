# Frida Command Capture Workflow

**Purpose**: Capture SCSI/NVMe passthrough commands from SP Toolbox on Windows to understand vendor-specific recovery sequences.

---

## Prerequisites

### Windows Host/VM

1. **Install Python 3.8+** and pip
2. **Install Frida**:
   ```powershell
   pip install frida frida-tools
   ```
3. **Download SP Toolbox** from Silicon Power website
4. **Connect target SSD** via ASM2362 USB bridge

### Linux Analysis Machine

1. **Install jq** for JSON processing:
   ```bash
   sudo dnf install jq  # or apt install jq
   ```

---

## Capture Methods

### Method 1: Spawn SP Toolbox (Recommended)

Captures commands from application start:

```powershell
cd src\frida
python capture.py spawn "C:\Program Files\SP Toolbox\SPToolbox.exe"
```

This will:
1. Launch SP Toolbox in suspended state
2. Inject Frida hooks
3. Resume execution
4. Enter interactive mode

### Method 2: Attach to Running Process

For already-running applications:

```powershell
# By PID
python capture.py attach 1234

# By process name
python capture.py attach -n SPToolbox.exe
```

### Method 3: List Processes

Find the correct process name/PID:

```powershell
python capture.py list
```

---

## Interactive Commands

Once attached, use these commands in the `capture>` prompt:

| Command | Description |
|---------|-------------|
| `stats` | Show capture statistics (total IOCTLs, by type) |
| `devices` | Show tracked device handles and their paths |
| `commands` | Print all captured commands as JSON |
| `save FILE` | Save commands to JSON file |
| `clear` | Clear captured command buffer |
| `quit` | Detach and exit |

---

## Workflow: Capture Secure Erase Sequence

### Step 1: Start Capture

```powershell
python capture.py spawn "C:\Program Files\SP Toolbox\SPToolbox.exe" -o secure_erase_capture.json
```

### Step 2: Navigate SP Toolbox

1. Wait for SP Toolbox to detect drives
2. Select the target ASM2362-connected drive
3. Navigate to **Secure Erase** or **Sanitize** function
4. **Do NOT execute** if you want to preserve data
5. Or execute on a test drive to capture the full sequence

### Step 3: Monitor Capture

In the interactive prompt:

```
capture> stats
{
  "total_ioctls": 47,
  "scsi_pass_through": 12,
  "scsi_pass_through_direct": 28,
  "storage_query_property": 5,
  "storage_protocol_command": 2,
  "device_handles": 3
}

capture> devices
{
  "0x1a4": "\\\\.\\PhysicalDrive2",
  "0x1b8": "\\\\.\\PhysicalDrive0"
}
```

### Step 4: Save and Exit

```
capture> save captured_commands.json
Saved 47 commands to captured_commands.json

capture> quit
```

Or use Ctrl+C - if `-o` was specified, it auto-saves.

---

## Captured Data Format

Each captured command includes:

```json
{
  "timestamp": 1737484800000,
  "handle": "0x1a4",
  "device": "\\\\.\\PhysicalDrive2",
  "ioctl_code": "0x4d014",
  "ioctl_name": "IOCTL_SCSI_PASS_THROUGH_DIRECT",
  "cdb": "e6 06 00 01 00 00 00 00 00 00 00 00 00 00 00 00",
  "cdb_length": 16,
  "data_direction": "read",
  "data_length": 4096,
  "parsed": {
    "type": "ASMedia Passthrough",
    "nvme_opcode": "0x06",
    "nvme_command": "Identify",
    "cdw10": "0x00000001"
  }
}
```

---

## Analyzing Captured Commands

### Filter ASMedia Passthrough Commands

```bash
jq '.[] | select(.cdb | startswith("e6"))' captured_commands.json
```

### Extract NVMe Opcodes

```bash
jq -r '.[] | select(.parsed.type == "ASMedia Passthrough") |
  "\(.parsed.nvme_command) (0x\(.parsed.nvme_opcode))"' captured_commands.json | sort | uniq -c
```

### Find Format/Sanitize Commands

```bash
jq '.[] | select(.parsed.nvme_opcode == "80" or .parsed.nvme_opcode == "84")' captured_commands.json
```

### Generate Command Sequence Timeline

```bash
jq -r '.[] | [.timestamp, .parsed.nvme_command // .ioctl_name] | @tsv' captured_commands.json
```

---

## Expected Command Sequence (Secure Erase)

Based on research, SP Toolbox typically sends:

| Step | NVMe Opcode | Command | Purpose |
|------|-------------|---------|---------|
| 1 | 0x06 | Identify Controller | Get controller capabilities |
| 2 | 0x06 | Identify Namespace | Get namespace info |
| 3 | 0x02 | Get Log Page | SMART data, supported features |
| 4 | 0x0A | Get Features | Check security state |
| 5 | 0x09 | Set Features | Enable write cache, etc. |
| 6 | 0x80 | Format NVM | Secure erase (SES=1 or 2) |
| 7 | — | OR 0x84 Sanitize | Alternative to Format |

---

## Replaying Captured Commands

Once captured, use `asm2362-tool` to replay on Linux:

```bash
# Dry run first
./zig-out/bin/asm2362-tool replay captured_commands.json /dev/sdb --dry-run

# Execute (DESTRUCTIVE)
./zig-out/bin/asm2362-tool replay captured_commands.json /dev/sdb
```

---

## Troubleshooting

### "frida not installed"

```powershell
pip install frida frida-tools
```

### "Process not found"

SP Toolbox may use a different process name. Use `capture.py list` to find it.

### No ASMedia commands captured

- Verify drive is connected via ASM2362 bridge
- SP Toolbox may not support the drive via USB - check if it's detected
- Try running SP Toolbox as Administrator

### Handle mapping missing

If `devices` shows empty, the application may have opened the device before Frida attached. Use spawn mode instead of attach.

### 32-bit vs 64-bit issues

Frida hooks automatically detect pointer size. If seeing garbled data, verify:
- Python architecture matches target (both 64-bit recommended)
- SP Toolbox version (some older versions are 32-bit)

---

## Security Notes

- Frida hooks intercept kernel32.dll DeviceIoControl
- Captured data may include sensitive device info
- Do not share captures publicly without sanitizing serial numbers
- Only use on devices you own or have authorization to test

---

## Files

| File | Purpose |
|------|---------|
| `src/frida/hooks.js` | Frida JavaScript hooks for Windows |
| `src/frida/capture.py` | Python controller script |
| `data/logs/*.json` | Default capture output location |
