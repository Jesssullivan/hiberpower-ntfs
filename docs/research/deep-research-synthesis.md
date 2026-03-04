# Deep Research Synthesis: Recovery Path Analysis

Date: 2026-02-28

## Critical Findings That Change Everything

### Finding 1: ASM2362 Only Passes Two Opcodes

The ASM2362's 0xe6 CDB has a **firmware-level opcode whitelist** in its 8051 microcontroller. Only two NVMe admin commands are forwarded:

| Opcode | Command | Status |
|--------|---------|--------|
| 0x02 | Get Log Page | **Works** |
| 0x06 | Identify | **Works** |
| 0x09 | Set Features | **Silently dropped** |
| 0x0A | Get Features | **Silently dropped** |
| 0x80 | Format NVM | **Silently dropped** |
| 0x81 | Security Send | **Silently dropped** |
| 0x82 | Security Receive | **Silently dropped** |
| 0x84 | Sanitize | **Silently dropped** |

This means all our implemented commands beyond probe/identify/smart are dead through USB. The bridge firmware never forwards them to the NVMe controller.

**Source**: cyrozap/usb-to-pcie-re, smartmontools `scsinvme.cpp` (`sntasmedia_device` class)

### Finding 2: XRAM Bypass Exists

The ASM2362 exposes additional vendor SCSI opcodes beyond 0xe6:

| Opcode | Command | Purpose |
|--------|---------|---------|
| 0xE0 | Read Config | Bridge configuration |
| 0xE1 | Write Config | Bridge configuration |
| 0xE2 | Flash Read | SPI flash access |
| 0xE3 | Firmware Write | Flash firmware |
| 0xE4 | **XDATA Read** | Read bridge XRAM (up to 255 bytes) |
| 0xE5 | **XDATA Write** | Write single byte to bridge XRAM |
| 0xE6 | NVMe Admin | NVMe passthrough (whitelisted) |
| 0xE8 | Reset | CPU reset (0x00) or PCIe reset (0x01) |

**Key memory map:**
- `0xB000-0xB1FF`: NVMe Admin Submission Queue (DMA-mapped to 0x00800000)
- `0xB200-0xB7FF`: PCIe controller MMIO registers
- `0xF000-0xFFFF`: NVMe generic data buffer

**Implication**: We can write arbitrary NVMe admin commands directly to the Admin Submission Queue via 0xE5, then trigger a doorbell write to submit them. This bypasses the 0xe6 opcode whitelist entirely.

**Source**: cyrozap/usb-to-pcie-re ASM2x6x/doc/Notes.md

### Finding 3: Phison Reinitial Tool Supports This Exact Failure

The Phison PS5012 Reinitial Tool (ECFM22.6) from usbdev.ru:
- Explicitly supports ASM2362/4 USB bridges
- Designed for drives with SMART attribute #0 = 8 (read-only mode)
- Also handles 0/2MB capacity detection failures
- Requires drive to be "under firmware" (not ROM mode)
- **Destroys all data** -- full reinitialization

VLO's modified version adds broader bridge support.

**Source**: usbdev.ru/files/phison/ps5012reinitialtool/

### Finding 4: "Medium Not Present" is Bridge-Generated

The SCSI error "NOT READY / Medium not present" (ASC=0x3A) is a **SCSI concept that does not exist in NVMe**. The ASM2362 generates it when the NVMe controller fails to respond as expected during the bridge's initialization.

On native M.2 PCIe:
- Admin commands (Identify, SMART, Error Log) should succeed
- Proper NVMe error codes returned instead of SCSI translations
- Controller reset available (CC.EN toggle, PCIe FLR)
- Format/Sanitize commands can be attempted with real error feedback

### Finding 5: Bit 3 Cannot Be Cleared by Standard Commands

SMART Critical Warning Bit 3 reflects current firmware state persisted in the controller's NAND service area. It is NOT a register the host can write to.

- No standard NVMe Set Features command clears it
- Power cycling does not clear it
- Feature 0x84 (Namespace Write Protection) is a completely separate mechanism
- **One documented success**: `nvme format --ses=1` on a KingSpec (likely Phison-based) drive

### Finding 6: Wine is a Dead End

Wine does NOT implement `IOCTL_SCSI_PASS_THROUGH_DIRECT` (0x4d014). SP Toolbox's .NET GUI may launch but all device operations return `STATUS_NOT_SUPPORTED`. No SSD vendor tool works under Wine for direct hardware access.

---

## Revised Priority Stack

### Priority 1: Phison Reinitial Tool (Highest Probability)

**Why first**: Pre-built solution designed for exactly our failure mode, supports our USB bridge, already exists.

**Steps**:
1. Download Reinitial Tool (ECFM22.6) from usbdev.ru
2. Download VLO's E8/E12/E13/E16 modified version
3. Download Phison NVMe Flash ID2 diagnostic tool
4. Run Flash ID2 to identify exact NAND type
5. Download matching firmware from usbdev.ru PS5012 firmware library
6. Run Reinitial Tool on Windows with ASM2362 connected
7. If "Get info" detects the drive, select Reinitial + matching firmware

**Risk**: Tool may fail if drive doesn't respond to the tool's initial probe.
**Data**: All data destroyed.

### Priority 2: Native M.2 PCIe Connection

**Why second**: Eliminates all bridge limitations, gives real diagnostics, enables progressive recovery attempts.

**Steps**:
1. Remove SSD from USB enclosure
2. Check Yoga laptop M.2 slot availability (may need second slot or USB live boot)
3. Install nvme-cli if not present
4. Power down, insert drive, boot
5. Confirm detection: `nvme list`
6. Read SMART: `nvme smart-log /dev/nvme0` -- confirm bit 3
7. Try controller reset: `nvme reset /dev/nvme0`
8. Try format with secure erase: `nvme format /dev/nvme0 --namespace-id=1 --ses=1`
9. Try sanitize block erase: `nvme sanitize /dev/nvme0 --sanact=2`
10. Try sanitize exit failure mode: `nvme sanitize /dev/nvme0 --sanact=1`
11. Try namespace delete/recreate
12. Try PCIe FLR: `echo 1 > /sys/bus/pci/devices/.../reset`

**Risk**: Need to handle boot drive logistics. Drive may still refuse commands.
**Data**: Format/sanitize destroy data.

### Priority 3: XRAM Queue Injection via ASM2362

**Why third**: Novel attack vector that could work through USB, but requires careful implementation.

**Steps**:
1. Implement 0xE4 (XRAM Read) to dump current Admin Submission Queue state
2. Implement 0xE5 (XRAM Write) to craft NVMe admin commands in queue memory
3. Understand doorbell mechanism for queue submission
4. Craft and submit Format NVM command bypassing 0xe6 whitelist
5. Verify via 0xE6 Identify/GetLog if state changed

**Risk**: Could brick the bridge controller if writes go wrong. Experimental.
**Data**: Depends on command submitted.

### Priority 4: SP Toolbox Frida Capture (On Real Windows)

**Why fourth**: Captures the exact vendor command sequence, but requires Windows setup.

**Steps**:
1. Set up real Windows (not Wine, not VM initially) with SP Toolbox
2. Attach Frida using existing hooks.js
3. Run SP Toolbox Secure Erase on a test drive (or this drive if expendable)
4. Capture full DeviceIoControl sequence
5. Analyze CDBs -- look for 0xE4/0xE5 XRAM commands, not just 0xe6
6. Replay captured sequence from Linux

**Risk**: Need Windows installation with USB passthrough working.
**Alternative**: Run on bare-metal Windows with the drive connected.

### Priority 5: PC-3000 Professional Recovery

**Why last resort**: Expensive ($300-1500) but PS5012 IS now on the supported list.

**Where**: Rossmann Group (documented E12 capability)
**What they do**: Inject firmware loader to SRAM, bypass corrupted SLC cache, rebuild FTL from TLC metadata.

---

## Abandoned Tracks

| Track | Status | Reason |
|-------|--------|--------|
| Wine + Frida | **DEAD** | Wine lacks SCSI passthrough IOCTL support |
| Standard NVMe Set Features to clear bit 3 | **DEAD** | Bit 3 is autonomous firmware state, not host-writable |
| Feature 0x84 write protection clearing | **DEAD** | Separate mechanism from firmware read-only |
| 0xe6 passthrough for Format/Sanitize | **DEAD** | Bridge firmware whitelist blocks all but 0x02/0x06 |

---

## Key Resources

| Resource | URL |
|----------|-----|
| Phison PS5012 Reinitial Tool | https://www.usbdev.ru/files/phison/ps5012reinitialtool/ |
| VLO E12 Reinitial Tool | https://www.usbdev.ru/files/phison/pse8e12e13e16reinitialbyvlo/ |
| PS5012 Firmware Library | https://www.usbdev.ru/files/phison/ps5012fw/ |
| Phison NVMe Flash ID2 | https://www.usbdev.ru/files/phison/phisonnvmeflashid2/ |
| cyrozap ASM2362 RE | https://github.com/cyrozap/usb-to-pcie-re |
| smartmontools ASMedia code | https://github.com/smartmontools/smartmontools/blob/master/smartmontools/scsinvme.cpp |
| ASMTool firmware dumper | https://github.com/smx-smx/ASMTool |
| ASM2362 firmware archive | https://www.station-drivers.com/index.php/en-us/component/remository/Drivers/Asmedia/ASM-2362-NVMe-USB-3.1-Controller/ |
| Rossmann SSD Recovery | https://rossmanngroup.com/services/ssd-data-recovery |
| PC-3000 Phison Utility | https://blog.acelab.eu.com/pc-3000-ssd-phison-utility.html |

---

## ASM2362 Hardware Details (From RE)

- CPU: 8051-compatible core at ~114.3 MHz
- XRAM: 64KB mapped memory space
- UART: 921600 8N1, 3.3V (RX pin 63, TX pin 62)
- Flash: SPI interface for firmware storage
- PCIe: Gen3 x2 lanes to NVMe device
- **No firmware signature verification** -- arbitrary code can be loaded
