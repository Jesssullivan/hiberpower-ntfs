# Phase 4: Combined Investigation Plan

## Strategy

Three parallel tracks that build on each other:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Investigation Pipeline                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Track C: USB Capture          Track B: Wine + Frida            │
│  ─────────────────────         ──────────────────────           │
│  • Passive observation         • Active hooking                 │
│  • Raw SCSI CDBs               • Win32 API level                │
│  • No software changes         • If SP Toolbox runs             │
│          │                              │                       │
│          └──────────┬───────────────────┘                       │
│                     ▼                                           │
│           Track D: Binary Analysis                              │
│           ────────────────────────                              │
│           • Understand what we captured                         │
│           • Find vendor-specific commands                       │
│           • Extract hidden functionality                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Track C: USB Protocol Capture

**Goal**: See exactly what bytes SP Toolbox sends over USB

**Why first**: Zero setup required, immediate visibility

### Setup

```bash
# Load usbmon kernel module
sudo modprobe usbmon

# Find ASM2362 bus/device
lsusb | grep 174c:2362
# Example output: Bus 001 Device 028

# Start Wireshark on that bus
sudo wireshark -i usbmon1 -k

# Filter for the device (adjust device number)
# Display filter: usb.device_address == 28
```

### What to Capture

1. **Baseline**: Capture while drive is idle
2. **SP Toolbox actions**: Each button click in the tool
3. **Compare**: Look for SCSI CDB patterns (0xe6 = ASM2362 passthrough)

### Key Fields in Wireshark

- `usb.capdata` - Raw USB payload
- `scsi.cdb` - SCSI Command Descriptor Block
- Look for: `e6 XX ...` where XX is NVMe opcode

## Track B: Wine + Frida

**Goal**: Hook SP Toolbox at Win32 API level on Linux

**Why**: Avoids VM complexity, gives API-level insight

### Step 1: Test Wine Compatibility

```bash
# Install Wine if needed
sudo dnf install wine

# Download SP Toolbox installer (from VM or fresh download)
# Try running it
wine "SP ToolBox Setup.exe"

# After install, try the app
wine ~/.wine/drive_c/Program\ Files\ \(x86\)/Silicon\ Power/SP\ ToolBox/SP\ ToolBox.exe
```

### Step 2: If Wine Works - Frida Hooking

```bash
# Install Frida
pip install frida frida-tools

# Spawn with Frida (hooks.js from vm-package)
frida -f wine -l src/frida/hooks.js -- ~/.wine/.../SP\ ToolBox.exe

# Or attach to running process
frida -n "SP ToolBox.exe" -l src/frida/hooks.js
```

### Step 3: Capture Commands

The hooks.js already intercepts:
- `DeviceIoControl` - SCSI passthrough
- `CreateFileW` - Device handle tracking
- Parses ASM2362 0xe6 CDBs

### Wine Limitations

- USB passthrough may not work (device access)
- May need to configure Wine for raw device access
- Some DirectX/UI may fail (but we only need the SCSI layer)

## Track D: Binary Analysis

**Goal**: Understand SP Toolbox internals, find vendor commands

**Why**: Even if Wine fails, we learn what commands exist

### Tools Needed

```bash
# Ghidra (free, NSA-developed)
sudo dnf install ghidra
# Or download from https://ghidra-sre.org/

# Alternative: Radare2/Cutter
sudo dnf install radare2 cutter
```

### Analysis Targets

1. **SP ToolBox.exe** - Main application
2. **Any DLLs** in the install directory (driver interfaces)
3. **Look for**:
   - `DeviceIoControl` imports
   - IOCTL codes (0x4d004, 0x4d014, 0x2d1400)
   - Byte patterns: `e6` followed by NVMe opcodes
   - Strings: "secure erase", "sanitize", "format", "vendor"

### Ghidra Workflow

```
1. Create new project
2. Import SP ToolBox.exe
3. Auto-analyze (accept defaults)
4. Search → For Strings → "erase", "format", "vendor"
5. Search → For Scalars → 0xe6, 0x4d014
6. Find references to DeviceIoControl
7. Trace backwards to understand command construction
```

### Key Questions to Answer

1. Does SP Toolbox have secure erase? (Not just UI, actual implementation)
2. What NVMe opcodes does it send?
3. Are there hidden/debug commands?
4. Does it check for specific drive models before enabling features?

## Combined Workflow

### Day 1: Quick Wins

```bash
# 1. USB Capture setup (10 min)
sudo modprobe usbmon
# Note the bus/device for ASM2362

# 2. Test Wine (15 min)
wine "SP ToolBox.exe"
# Does it launch? Does it see drives?

# 3. Start Ghidra project (30 min)
ghidra &
# Import SP ToolBox.exe, start auto-analysis
```

### Day 2: Deep Dive

Based on Day 1 results:
- If Wine works → Frida hooking
- If Wine fails → Focus on Ghidra + USB capture
- Cross-reference Ghidra findings with USB captures

## Files to Create

```
src/
├── frida/
│   ├── hooks.js           # Already exists - DeviceIoControl hooks
│   └── wine-hooks.js      # Wine-specific adaptations if needed
├── analysis/
│   ├── ghidra-notes.md    # Findings from binary analysis
│   └── usb-captures/      # Wireshark pcap files
└── tools/
    └── cdb-decoder.py     # Parse CDBs from captures
```

## Success Criteria

1. **Identify all NVMe commands** SP Toolbox can send
2. **Find vendor-specific opcodes** (if any)
3. **Understand command gating** - why some features may be disabled
4. **Extract exact CDB sequences** for replay with asm2362-tool

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Wine doesn't run SP Toolbox | Focus on Ghidra + USB capture with real Windows |
| USB capture too low-level | Cross-reference with Ghidra to understand meaning |
| SP Toolbox has no recovery commands | Document findings, consider Phison UPTOOL |
| Ghidra analysis too complex | Start with strings/imports, not full decompilation |
