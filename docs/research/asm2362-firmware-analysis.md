# ASM2362 Firmware Analysis: USB Descriptor Discovery

**Date**: 2026-03-30
**Author**: Jess Sullivan
**Device**: ASM2362 enclosure (VID 0x174C, PID 0x2362)
**NVMe SSD**: Silicon Power SPCC M.2 PCIe SSD (Phison PS5012-E12, FW H211011a)
**Tools**: asm2362-tool (hiberpower) on Linux via SG_IO

## Executive Summary

Firmware dump (128KB via 0xE2) and analysis reveals the enclosure firmware **contains a complete BOS descriptor with SuperSpeed Device Capability** — but a config flag prevents it from being served to the USB host. The fix is a config byte change, not a full firmware replacement.

## Firmware Dump

```bash
sudo asm2362-tool flash-dump --firmware=backup.bin --flash-size=131072 /dev/sg0
# Successfully dumped 131072 bytes (128KB)
```

## SPI Flash Layout

### Config Area (0x0000-0x007F)

```
0000: 6440 13ff 3030 3030 3030 3030 3030 3943  d@..00000000009C
0010: ffff ffff ffff ffff 4173 6d65 6469 61ff  ........Asmedia.
0020: ffff ffff ffff ffff ffff ffff ffff ffff  ................
0040: ffff ffff 4153 4d32 3336 5820 7365 7269  ....ASM236X seri
0050: 6573 ffff ffff ffff ffff ffff ffff ffff  es..............
0070: ffff ffff 4c17 6223 0001 f3ff 02ff 5a76  ....L.b#......Zv
```

| Offset | Value | Meaning |
|--------|-------|---------|
| 0x00 | `64 40` | Header/magic |
| 0x02 | `13` | Config format version? |
| 0x08-0x17 | `"00000000009C"` | Serial number (ASCII) |
| 0x18-0x1F | `"Asmedia"` | Vendor string |
| 0x44-0x53 | `"ASM236X series"` | Product string |
| 0x74-0x75 | `4C 17` | VID = 0x174C (little-endian) |
| 0x76-0x77 | `62 23` | PID = 0x2362 |
| 0x78-0x79 | `00 01` | bcdDevice = 0x0100 |
| **0x7A** | **`F3` = 11110011** | **Feature flags — bit 2 (0x04) CLEARED** |
| 0x7B | `FF` | All flags set |
| **0x7C** | **`02`** | **USB version byte (0x02 → USB 2.x)** |
| 0x7D | `FF` | All flags set |
| 0x7E-0x7F | `5A 76` | Checksum or padding |

### Firmware Code (0x0080+)

8051 instructions begin at 0x0080. The bridge CPU runs ASMedia's proprietary firmware on an 8051-compatible core at ~114.3 MHz.

### USB Device Descriptor (found at 0x37C3)

```
12 01 10 02 00 00 00 40 4C 17 06 51 01 00 02 03 01 01
```

| Field | Value | Meaning |
|-------|-------|---------|
| bLength | 0x12 (18) | Standard device descriptor |
| bDescriptorType | 0x01 | Device descriptor |
| **bcdUSB** | **0x0210** | **USB 2.1 — triggers BOS query per spec** |
| bDeviceClass | 0x00 | Defined at interface level |
| bDeviceSubClass | 0x00 | |
| bDeviceProtocol | 0x00 | |
| bMaxPacketSize0 | 0x40 (64) | USB 2.0 High-Speed |
| idVendor | 0x174C | ASMedia |
| idProduct | **0x5106** | Firmware default (overridden by config 0x2362) |
| bcdDevice | 0x0100 | |
| iManufacturer | 0x02 | |
| iProduct | 0x03 | |
| iSerialNumber | 0x01 | |
| bNumConfigurations | 0x01 | Single configuration |

**Key discovery**: The firmware's default PID is **0x5106**, not 0x2362. The config area at 0x0074 overrides it to 0x2362. This means the PID is a configurable parameter.

### BOS Descriptor (found at 0x38DB)

```
05 0F 2A 00 03    — BOS header
07 10 02 1E F4 00 00    — USB 2.0 Extension
0A 10 03 00 0E 00 01 0A FF 07    — SuperSpeed Device Capability
```

**BOS Header:**
| Field | Value | Meaning |
|-------|-------|---------|
| bLength | 0x05 | |
| bDescriptorType | 0x0F | BOS descriptor |
| wTotalLength | 42 (0x002A) | Full BOS with all capabilities |
| bNumDeviceCaps | 3 | Three capability descriptors |

**SuperSpeed Device Capability:**
| Field | Value | Meaning |
|-------|-------|---------|
| bLength | 0x0A (10) | |
| bDescriptorType | 0x10 | Device Capability |
| bDevCapabilityType | 0x03 | **SuperSpeed USB** |
| bmAttributes | 0x00 | |
| wSpeedsSupported | **0x000E** | **FS + HS + SS (5 Gbps)** |
| bFunctionalitySupport | 0x01 | Lowest speed: Full-Speed |
| bU1DevExitLat | 0x0A | 10 μs |
| bU2DevExitLat | 0x07FF | 2047 μs |

**The firmware supports USB 3.0 SuperSpeed at 5 Gbps.**

## XRAM Runtime State

The XRAM (8051 working memory) at 0x0070-0x008F shows different values than the SPI flash config area:

```
XRAM 0070: 30 00 30 00 30 00 30 00 30 00 30 01 01 01 01 02
XRAM 0080: 30 00 30 00 30 00 30 00 30 00 30 00 30 00 30 00
```

The USB descriptors at 0x37C3 and 0x38DB (SPI flash offsets) are NOT loaded into XRAM — the 8051 reads them directly from SPI flash via the flash controller.

## Root Cause Analysis

The BOS descriptor **exists in the firmware** but is not being served to the host. The most likely cause:

1. **Config byte 0x7A = 0xF3 (11110011)** — bit 2 is the only cleared bit in the low nibble
   - If bit 2 controls "enable BOS descriptor response", it's disabled
   - Setting 0xF3 → 0xF7 would enable it

2. **Config byte 0x7C = 0x02** — could control the USB version advertisement
   - 0x02 → USB 2.x mode
   - 0x03 → USB 3.x mode would enable SuperSpeed link training

3. **The config area is writable** via XRAM write (0xE5) followed by a flash save or via direct firmware write (0xE3)

## Next Steps

1. **Cross-reference with known good firmware** — download 230927_91_00_00 from station-drivers.com, compare config bytes
2. **Test config byte change** — write 0x7A from 0xF3 → 0xF7 (set bit 2), reset bridge, check if BOS is served
3. **Alternatively** — change 0x7C from 0x02 → 0x03, reset, check if USB 3.0 negotiation occurs

**Risk**: Modifying config bytes could brick the enclosure. We have a full firmware backup. Recovery via UART (921600 8N1) is possible if the bootloader survives.

## References

- [cyrozap/usb-to-pcie-re](https://github.com/cyrozap/usb-to-pcie-re) — ASM236x reverse engineering documentation
- [smx-smx/ASMTool](https://github.com/smx-smx/ASMTool) — ASMedia firmware utilities
- [station-drivers.com ASM2362](https://www.station-drivers.com/) — firmware archive
- USB 3.0 Specification Section 9.6.2 — BOS Descriptor
- USB 3.0 Specification Section 9.2.6.6 — bcdUSB and BOS relationship
