---
title: "From Bricked to Recovered: The Story of Hacking an NVMe SSD Back to Life"
date: "2026-03-04"
description: "How I recovered a write-protected NVMe SSD by reverse engineering a USB bridge chip and injecting commands directly into its memory — no professional tools needed."
tags: ["nvme", "ssd-recovery", "reverse-engineering", "usb-bridge", "zig"]
published: true
category: "hardware"
source_repo: "Jesssullivan/hiberpower-ntfs"
source_path: "docs/blog/recovery-journey.md"
publish_to: "blog"
---

# From Bricked to Recovered: The Story of Hacking an NVMe SSD Back to Life

It started with the most insidious kind of bug: a disk that lies to you.

I was doing routine cleanup on a Lenovo Yoga laptop running Rocky Linux 10. A 256GB Silicon Power NVMe SSD sat in a USB enclosure, connected via USB 3.1. I needed to wipe it and repurpose it. Simple enough. I have done this a thousand times.

```bash
$ sudo dd if=/dev/zero of=/dev/sdb bs=512 count=1 conv=fsync oflag=direct
512 bytes copied, 0.000313659 s, 1.6 MB/s
```

Success. Or so `dd` told me.

I read back sector zero to confirm the wipe:

```bash
$ sudo xxd -l 64 /dev/sdb
00000000: 33c0 8ed0 bc00 7c8e...  # MBR boot code - NOT ZEROS
```

The MBR was still there. Every byte intact. Untouched. I blinked, ran it again. Same result. Tried `wipefs`:

```bash
$ sudo wipefs --all --force /dev/sdb
/dev/sdb: 8 bytes were erased at offset 0x200 (gpt)
/dev/sdb: 2 bytes were erased at offset 0x1fe (PMBR)
```

Two messages confirming erasure. Read it back:

```bash
$ sudo xxd -s 512 -l 8 /dev/sdb
00000200: 4546 4920 5041 5254  # "EFI PART" still present
```

The GPT header was still there. The MBR magic number `0x55AA` still at offset `0x1FE`. Every signature, every partition entry, every byte -- unchanged.

I sat there for a long moment. In twenty years of working with Linux, I have never seen this. Tools do not lie. `dd` does not lie. If it says it wrote data, it wrote data.

Unless the disk itself is the liar.

---

## Act 1: The Mystery

### When Your Tools Report Success and Nothing Changes

I went through every diagnostic I knew. `blockdev --getro` returned 0 -- the kernel said the device was writable. The SCSI mode pages reported WP=0. Every single indicator a Linux system provides said this drive was read-write and healthy.

But nothing I wrote to it stuck.

I tried `fdisk`, `gdisk`, `blkdiscard`, `sg_format`, `sg_sanitize`, `sg_write_same`. Some of these tools had the decency to fail with actual errors. But the ones that reported success were the terrifying ones -- they were lying, or more precisely, they were being lied to.

The definitive test is embarrassingly simple: write a known pattern, read it back, compare. I wrote zeros to sector 2 (a GPT partition entry containing "Microsoft" in UTF-16), read it back, and found the partition entry byte-for-byte identical to what was there before:

```
BEFORE dd:
00000430: 0000 0000 0000 0000 4d00 6900 6300 7200  ........M.i.c.r.

$ sudo dd if=/dev/zero of=/dev/sdb bs=512 count=1 seek=2 conv=fsync oflag=direct
512 bytes copied, 0.00578528 s, 88.5 kB/s

AFTER dd:
00000430: 0000 0000 0000 0000 4d00 6900 6300 7200  ........M.i.c.r.
```

This is "silent write failure." The drive accepts write commands at the SCSI protocol level, returns Good status, and quietly drops them on the floor. No errors in `dmesg`, no SCSI check conditions, no I/O failures. Every standard Linux disk tool -- from `dd` to `parted` to `mkfs` -- would report success while accomplishing nothing.

### The Error Trail

The tools that failed openly were more instructive. `smartctl -d sntasmedia -i /dev/sdb` returned:

```
Read NVMe Identify Controller failed: scsi error no medium present
```

`sg_sanitize` returned SCSI sense data with a pattern that became depressingly familiar:

| Field | Value | Meaning |
|-------|-------|---------|
| Sense Key | 0x02 | NOT READY |
| ASC | 0x3A | MEDIUM NOT PRESENT |
| ASCQ | 0x00 | -- |

"Medium not present." Like an empty CD-ROM tray. But this was a soldered-down NVMe SSD. There was no media to remove.

And in `dmesg`, the kernel was not happy either:

```
sd 1:0:0:0: [sdb] Media removed, stopped polling
sd 1:0:0:0: [sdb] tag#5 uas_eh_abort_handler 0 uas-tag 1 inflight: CMD
sd 1:0:0:0: [sdb] tag#5 CDB: Read(10) 28 00 00 00 00 00 00 00 01 00
usb 1-2.3: reset high-speed USB device number 23 using xhci_hcd
```

### Understanding the Stack

To understand what was happening -- and more importantly, why every tool lied to me about it -- you need to understand the hardware stack:

```mermaid
graph TB
    subgraph host ["Linux Host"]
        LINUX["UAS / usb-storage driver<br/>/dev/sdb"]
    end
    subgraph bridge ["USB Bridge: ASMedia ASM2362"]
        BRIDGE["8051 CPU @ 114 MHz<br/>64KB XRAM<br/>VID:PID 174c:2362<br/><b>Opcode whitelist here</b>"]
    end
    subgraph ssd ["NVMe SSD: Silicon Power 256GB"]
        SSD["Phison PS5012-E12 controller<br/>FTL corrupted → read-only mode<br/>SMART Critical Warning bit 3"]
    end
    LINUX -->|"USB 3.1 Gen 2<br/>SCSI commands"| BRIDGE
    BRIDGE -->|"M.2 PCIe Gen3 x2<br/>NVMe commands (filtered!)"| SSD

    style bridge fill:#ff6b6b22,stroke:#ff6b6b
    style ssd fill:#ffa50022,stroke:#ffa500
```

Three layers of hardware. Three layers of firmware. Three layers of potential misunderstanding. The NVMe SSD at the bottom speaks PCIe/NVMe. The ASMedia ASM2362 USB bridge in the middle translates between NVMe and USB/SCSI. Linux at the top talks SCSI to what it thinks is a normal USB mass storage device.

Every command I sent had to traverse this entire stack. Every response had to travel back up. And as I was about to discover, the middle layer had opinions about which commands deserved to be forwarded and which deserved to be silently swallowed.

### The Root Cause

I traced the origin to a Windows hibernate event weeks earlier. This laptop had been running Windows with the SSD as a secondary drive. During hibernation, Windows suspends writes to all volumes and dumps system state to disk. If power is lost during that process -- a battery death, an accidental unplug -- the NVMe controller's Flash Translation Layer (FTL) can be left in an inconsistent state.

The FTL is the firmware component that maps logical block addresses (the addresses your OS uses) to physical NAND flash locations (the actual cells on the silicon). It is the controller's internal bookkeeping. When it gets corrupted, the controller cannot safely write new data without risking overwriting valid data it can no longer track. So it does the responsible thing: it enters read-only mode.

This is documented in the NVMe specification as SMART/Health Critical Warning Bit 3 (mask 0x08):

> "The media has been placed in read only mode. Vendor specific recovery may be required."

That last sentence is doing a tremendous amount of heavy lifting. "Vendor specific recovery" means there is no standard way to fix this. Every NVMe controller manufacturer implements their own recovery mechanism, and most of them do not publish the details.

### Why This Matters

This exact failure mode affects a staggering number of consumer NVMe SSDs. Academic research from UC San Diego documented 50-75% bit error rates during power-loss events on consumer drives. A study by Ohio State and HP Labs found that 13 out of 15 consumer SSDs lost data in power fault testing. Enterprise SSDs have supercapacitors to flush pending writes during power loss. Consumer SSDs do not.

If your consumer NVMe SSD loses power during a write-heavy operation -- a Windows hibernate, a database commit, a large file copy -- there is a meaningful chance your FTL will corrupt and your drive will enter this silent read-only mode. Professional data recovery for NVMe SSDs runs $300 to $1,500 or more, and even professionals sometimes cannot help if the FTL is truly destroyed.

I decided to see if I could do it myself. I had a $15 USB enclosure, a Linux box, and time.

---

## Act 2: The Rabbit Hole

### Building the Tool

I needed to send raw SCSI commands and inspect the results at the byte level. Existing tools like `sg_raw` and `nvme-cli` got me started, but I quickly hit limitations. I needed custom CDB construction, hex-level introspection of sense data, and eventually direct memory manipulation of the bridge chip. No existing tool combined all of those capabilities.

I chose Zig. Not because it was trendy, but because the problem demanded it. I needed direct control over memory layout with `packed struct` for exact binary protocol matching. I needed the ability to reason about endianness at the byte level -- NVMe uses little-endian internally, the ASM2362's PCIe TLP registers use big-endian, and SCSI CDBs are big-endian. I needed zero runtime overhead for timing-sensitive hardware interactions. And I needed `comptime` for building CDBs with compile-time-known layouts.

The first module was `sg_io.zig` -- a thin wrapper around Linux's SG_IO ioctl interface. SG_IO lets you send raw SCSI commands to any device managed by the kernel's SCSI subsystem. You fill in an `sg_io_hdr` structure with your Command Descriptor Block (CDB), a data buffer, a sense buffer for error information, and a transfer direction flag. Then you call `ioctl(fd, SG_IO, &hdr)` and the kernel sends your exact bytes to the device.

The second module was `passthrough.zig` -- the ASMedia ASM2362's proprietary 0xe6 CDB format. This 16-byte CDB tunnels NVMe admin commands through the USB bridge:

```
Byte 0:     0xe6         # ASMedia passthrough opcode
Byte 1:     NVMe opcode  # (0x06=Identify, 0x02=GetLog, etc.)
Byte 3:     CDW10[7:0]   # NVMe Command Dword 10, low byte
Byte 6:     CDW10[23:16]
Byte 7:     CDW10[31:24]
Bytes 8-11: CDW13        # Big-endian
Bytes 12-15: CDW12       # Big-endian
```

I implemented all eight NVMe opcodes that I had found in USB traffic captures of SP Toolbox, Silicon Power's vendor utility: Identify (0x06), Get Log Page (0x02), Format NVM (0x80), Sanitize (0x84), Set Features (0x09), Get Features (0x0A), Security Send (0x82), and Security Receive (0x81).

### First Breakthrough: The Diagnostic Commands Work

The `probe` and `identify` commands worked. On the broken drive, I got the "Medium not present" error -- but I already knew the NVMe controller was in protection mode. More importantly, when I tested against a healthy drive, I could query the NVMe controller through the USB bridge and get back valid Identify Controller data:

```
VID:      0x1E4B (Phison Electronics)
Model:    SPCC M.2 PCIe SSD
Firmware: H211011a
Serial:   00000000000000001387
OACS:     0x00
```

VID 0x1E4B confirmed the controller: Phison PS5012-E12, one of the most common NVMe controllers in consumer SSDs. OACS (Optional Admin Command Support) was 0x00, meaning the controller's own Identify data claimed it did not support Format NVM or Security commands through this interface. An ominous sign.

The SMART data, when I could read it from a reference check, painted a picture of a drive that had lived a hard life: 270 unsafe shutdowns, 292 media integrity errors, only 1% available spare capacity. The hibernate power loss was the final straw.

### First Disappointment: Recovery Commands Go Nowhere

With diagnostics working, the plan was straightforward: send a Format NVM or Sanitize command through the 0xe6 passthrough to wipe the corrupted FTL and force the controller to rebuild it from scratch. Data would be lost, but the drive would be functional again.

I sent Format NVM (opcode 0x80). SCSI status: Good. No errors. Duration: 2 milliseconds.

That was suspicious. A real NVMe format on a 256GB drive takes minutes, not milliseconds.

I checked the drive state. Nothing changed. Sent it again. Same result -- instant "success," zero effect. Tried Sanitize. Same thing. Set Features to clear write protection. Security Send with ATA password protocols. Every single command: SCSI Good status, zero measurable effect on the drive.

I spent two full days debugging my CDB construction. Checked every byte position. Verified endianness. Compared my implementation byte-for-byte against the smartmontools `sntasmedia_device` class. My CDBs were correct. The problem was not in my code.

### The Eureka Moment

Then I found [cyrozap's USB-to-PCIe reverse engineering repository](https://github.com/cyrozap/usb-to-pcie-re). This was the work of someone who had fully decompiled the ASM2362's 8051 firmware and documented its internals. And buried in the notes was the answer that reframed everything:

**The ASM2362 has an opcode whitelist.**

The bridge's 8051 microcontroller firmware parses byte 1 of the 0xe6 CDB -- the NVMe opcode -- and checks it against an internal allowlist. Exactly two NVMe admin opcodes are forwarded to the NVMe controller. Everything else is silently dropped:

| NVMe Opcode | Command | Passes Through? |
|-------------|---------|-----------------|
| 0x02 | Get Log Page | **Yes** |
| 0x06 | Identify | **Yes** |
| 0x09 | Set Features | **Silently dropped** |
| 0x0A | Get Features | **Silently dropped** |
| 0x80 | Format NVM | **Silently dropped** |
| 0x81 | Security Receive | **Silently dropped** |
| 0x82 | Security Send | **Silently dropped** |
| 0x84 | Sanitize | **Silently dropped** |

Six of my eight commands were being swallowed by the bridge firmware. The bridge returned SCSI Good status because from its perspective the SCSI transaction completed successfully -- it just never forwarded the NVMe command to the actual drive. The "Medium not present" error I was getting for some commands was the bridge's catch-all SCSI error for "I do not know what to do with this NVMe opcode."

The bridge was not transparent. It had opinions about which commands I was allowed to send. And it expressed those opinions by lying.

### The Catalog of Dead Ends

With the 0xe6 path closed off, I took stock of everything that had failed:

**Wine + SP Toolbox**: Silicon Power's vendor recovery tool (SP Toolbox) is a .NET Windows application. Wine does not implement `IOCTL_SCSI_PASS_THROUGH_DIRECT` -- the Windows equivalent of Linux's SG_IO. The GUI launches, the device list populates, but every device operation returns `STATUS_NOT_SUPPORTED`. No SSD vendor tool works under Wine for direct hardware access.

**Set Features 0x84 (Namespace Write Protection)**: The NVMe spec defines a Write Protection feature (Feature ID 0x84) that the host can toggle. I initially thought this was how the controller locked the drive. It is not. SMART Critical Warning Bit 3 reflects autonomous firmware state stored in the controller's NAND service area. Feature 0x84 is a completely separate mechanism -- host-initiated namespace write protection, defined in NVMe 1.4+. Clearing it would not affect firmware-level read-only mode.

**0xe6 passthrough for all recovery commands**: Format NVM, Sanitize, Security Send, Security Receive, Set Features, Get Features -- all silently dropped by the whitelist. The bridge only permits diagnostic reads. You can look at the drive through this interface, but you cannot touch it.

Each dead end cost a day or more. The 0xe6 passthrough implementation alone was several hundred lines of carefully constructed Zig code -- format.zig and sanitize.zig, complete with unit tests and proper error handling. Perfectly correct code for commands that could never reach the drive. I archived them and moved on.

---

## Act 3: The Breakthrough

### The Vendor Commands Nobody Talks About

Cyrozap's reverse engineering revealed that the ASM2362 does not just have the 0xe6 command. It exposes an entire family of vendor-specific SCSI opcodes:

| Opcode | Command | Purpose |
|--------|---------|---------|
| 0xE0 | Read Config | 128 bytes of bridge configuration |
| 0xE1 | Write Config | Modify bridge configuration |
| 0xE2 | Flash Read | Read SPI flash contents |
| 0xE3 | Firmware Write | Flash new firmware |
| 0xE4 | **XDATA Read** | Read 1-255 bytes from bridge XRAM |
| 0xE5 | **XDATA Write** | Write a single byte to bridge XRAM |
| 0xE6 | NVMe Admin | NVMe passthrough (whitelisted) |
| 0xE8 | **Reset** | CPU reset or PCIe link reset |

The 0xE4 and 0xE5 commands provide direct read and write access to the ASM2362's internal XRAM -- the 64KB memory space of the 8051 microcontroller. This is the chip's working memory. Its scratch pad. Its brain.

And here is the critical detail: the NVMe Admin Submission Queue lives in that XRAM, at addresses 0xB000 through 0xB1FF. This is the ring buffer where the bridge CPU stages NVMe commands before pushing them across the PCIe bus to the NVMe controller.

The theory formed immediately. The 0xe6 handler parses your NVMe command, checks the opcode against its whitelist, and only builds a queue entry for approved commands. But what if I skipped the 0xe6 handler entirely? What if I wrote the NVMe Submission Queue Entry directly into XRAM using 0xE5? The bytes would land in the queue *after* any filtering. The bridge firmware would never know a non-whitelisted command had been inserted. It would just see a queue entry appear and push it to the controller.

I would be writing NVMe commands directly into the bridge chip's brain.

### The UAS Obstacle

The first 0xE4 read command failed before it reached the bridge. Linux returned `errno -75` (`EOVERFLOW`) with `host_status=0x07` (`DID_ERROR`). The command was rejected at the USB transport layer.

The culprit was UAS -- USB Attached SCSI protocol. The Linux kernel had loaded the `uas` driver for the ASM2362, which uses USB stream endpoints for command queuing and higher throughput. UAS is the modern, high-performance USB storage driver. It is also pickier about CDB formats.

The ASM2362's vendor commands use non-standard CDB sizes (6 bytes for 0xE4/0xE5, 12 bytes for 0xE8) and non-standard data transfer patterns. UAS expects standard SCSI command structures and chokes on the vendor deviations.

```mermaid
flowchart TD
    START["Vendor SCSI command<br/>(0xE4 / 0xE5 / 0xE8)"] --> CHECK{Which USB<br/>driver?}
    CHECK -->|"UAS<br/>(default)"| UAS["UAS driver rejects<br/>non-standard CDB"]
    UAS --> FAIL["DID_ERROR<br/>errno -75 EOVERFLOW"]
    CHECK -->|"usb-storage<br/>(BOT mode)"| BOT["BOT passes CDB<br/>without inspection"]
    BOT --> OK["Command reaches<br/>ASM2362 bridge"]

    SWITCH["modprobe usb-storage<br/>quirks=174c:2362:u"] -.->|"Switch driver"| BOT

    style FAIL fill:#ff6b6b22,stroke:#ff6b6b
    style OK fill:#51cf6622,stroke:#51cf66
    style SWITCH fill:#4ecdc422,stroke:#4ecdc4
```

The fix was to force the device into BOT mode -- Bulk-Only Transport, the older, simpler USB Mass Storage protocol. BOT is dumber but more permissive. It passes CDBs through without scrutinizing their format:

```bash
sudo bash -c '
  echo "1-3" > /sys/bus/usb/drivers/usb/unbind
  rmmod uas
  rmmod usb_storage
  modprobe usb-storage quirks=174c:2362:u
  echo "1-3" > /sys/bus/usb/drivers/usb/bind
'
```

The `quirks=174c:2362:u` flag tells the `usb-storage` module to ignore UAS capability for this specific USB VID:PID combination. The device re-enumerated as `/dev/sdc`. I verified the driver binding -- `readlink` on the sysfs driver path now pointed to `usb-storage` instead of `uas`.

### First XRAM Read

With BOT mode active, I sent my first 0xE4 read:

```
CDB: E4 40 00 B0 00 00
     ^  ^  ^  ^  ^  ^
     |  |  |  |  |  +-- padding
     |  |  |  |  +-- address low byte: 0x00
     |  |  |  +-- address high byte: 0xB0 (address = 0xB000)
     |  |  +-- padding
     |  +-- length: 64 bytes
     +-- opcode: XDATA Read
```

And back came 64 bytes of real data from inside the bridge chip's memory. The first NVMe Submission Queue Entry, left there by the bridge firmware during power-on initialization:

```
B000: 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
B010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
B020: 00 00 00 00 00 00 00 00 06 00 00 00 00 00 00 00  |................|
B030: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
```

Opcode 0x09 at byte 0: Set Features. The bridge firmware's own initialization command, sitting in the queue like a fossil in amber. I dumped all 512 bytes of the Admin SQ and found four populated entries:

```
[0] 0xB000: OPC=0x09 (Set Features)     CID=0  CDW10=0x00000006
[1] 0xB040: OPC=0x09 (Set Features)     CID=1  CDW10=0x00000007
[2] 0xB080: OPC=0x05 (Create I/O CQ)    CID=2
[3] 0xB0C0: OPC=0x01 (Create I/O SQ)    CID=3
[4] 0xB100: (empty)
[5] 0xB140: (empty)
[6] 0xB180: (empty)
[7] 0xB1C0: (empty)
```

The firmware had initialized four commands during boot: two Set Features calls (configuring Number of Queues and Interrupt Coalescing), then Create I/O Completion Queue and Create I/O Submission Queue. The standard NVMe controller initialization sequence, frozen in XRAM.

I was reading the bridge chip's brain. Now I needed to write to it.

### The CDB Format Bug

This part cost me half a day. My initial 0xE5 write CDB had the byte positions wrong. I had guessed the layout based on the 0xe6 format, which was wrong:

```
My initial guess:  E5 [00] [value] [addr_hi] [addr_lo] [00]   # WRONG
Actual format:     E5 [value] [00] [addr_hi] [addr_lo] [00]   # CORRECT
```

Byte 1 is the value to write, not byte 2. The data byte is embedded directly in the CDB -- there is no data transfer phase at all. The 0xE5 command is a 6-byte CDB where the payload is inside the command itself. This is unusual for SCSI (most write commands have a separate data-out phase), but it makes sense for single-byte writes.

Getting this wrong meant writing the wrong value to the wrong address. In XRAM. On a chip with no memory protection and no firmware signature verification. If I had written garbage to the wrong MMIO register, I could have bricked the bridge controller itself -- turning a recoverable SSD problem into a dead USB enclosure.

After correcting the CDB format from cyrozap's Python reference implementation, I wrote 0x42 to address 0xB100 (the first byte of slot 4), read it back via 0xE4, and got 0x42. First confirmed XRAM write. Byte-level control of the bridge chip's internal memory, over USB, from Linux.

---

## Act 4: The Injection

### Writing an NVMe Command, One Byte at a Time

An NVMe Submission Queue Entry is a 64-byte little-endian structure defined by the NVMe Base Specification. For a Sanitize Block Erase, the critical fields are:

```zig
pub fn craftSanitizeEntry(sanact: u3, command_id: u16) NvmeSqEntry {
    return .{
        .cdw0 = @as(u32, 0x84) | (@as(u32, command_id) << 16),
        .nsid = 0,             // Sanitize operates on entire controller
        .cdw10 = @as(u32, sanact),  // 2 = Block Erase
    };
}
```

CDW0 packs the opcode (0x84 for Sanitize) in the low byte and a 16-bit Command ID in the high word. CDW10 contains the Sanitize Action -- 2 for Block Erase, which erases all user data blocks at the NAND level. NSID is 0 because Sanitize applies to the whole controller, not individual namespaces. All other fields (PRP pointers, metadata, CDW11-CDW15) are zero -- Sanitize does not transfer data.

The entry serializes to 64 bytes. I wrote it to the Admin SQ using 0xE5 -- one SCSI command per byte, 64 individual write operations, each followed by a read-back verification. That is 128 SCSI round-trips through the USB stack to inject one NVMe command. At roughly 80ms per round-trip, the full write-and-verify took about five seconds.

```bash
$ sudo ./zig-out/bin/asm2362-tool inject \
    --inject-cmd=sanitize-block --dry-run /dev/sdc

Phase 1: Reading Admin SQ state...
Phase 2: Finding SQ slot...
  Using slot 4 at XRAM 0xB100
Phase 3: Writing 64 bytes to XRAM...
Phase 4: Verifying...
  All 64 bytes verified.
Phase 5: SKIPPED (dry-run) -- doorbell NOT rung
```

Every byte was in place. The NVMe command was sitting in queue memory, correctly formatted, fully verified. But it was just data in RAM. The NVMe controller did not know it was there.

### The Doorbell Problem

NVMe uses a producer-consumer model for command submission. The host writes commands to the Submission Queue in memory, then writes a new "tail" pointer to a hardware register called the Submission Queue Tail Doorbell. This doorbell tells the controller: "I have added entries up to this index in the queue. Please process them."

On native PCIe, the doorbell is a memory-mapped I/O register at a fixed offset from the controller's BAR0 (Base Address Register 0). For the Admin SQ, the doorbell lives at BAR0 + 0x1000.

But I was not on native PCIe. I was going through a USB bridge. The NVMe controller's MMIO registers are on the PCIe side of the bridge, not the USB side. I could not just write to BAR0 + 0x1000 from Linux.

Cyrozap's reverse engineering came through once more. The ASM2362 has a PCIe TLP (Transaction Layer Packet) engine accessible through XRAM registers at 0xB200-0xB296. This engine can construct and transmit arbitrary PCIe transactions across the bridge's PCIe port. By writing the right values to the TLP header registers, data register, and control/status register, I could synthesize a PCIe memory write -- a doorbell ring -- from the USB side.

```mermaid
sequenceDiagram
    participant Host as Linux Host
    participant Bridge as ASM2362 Bridge<br/>(XRAM)
    participant TLP as TLP Engine<br/>(0xB200)
    participant NVMe as NVMe Controller

    Note over Host,NVMe: XRAM Injection Sequence

    Host->>Bridge: 0xE4: Read Admin SQ (0xB000)
    Bridge-->>Host: Current queue state (4 entries)

    Host->>Bridge: 0xE5: Write 64 bytes to slot 0
    Note right of Bridge: 64 individual byte writes<br/>each verified via 0xE4

    Host->>Bridge: 0xE4: Full readback verify
    Bridge-->>Host: All 64 bytes match

    Host->>TLP: Write new tail value to 0xB220
    Host->>TLP: Write TLP header to 0xB210
    Host->>TLP: Trigger (0x0F → 0xB254)
    TLP->>NVMe: PCIe Memory Write TLP<br/>(BAR0 + 0x1000 = doorbell)
    Note right of NVMe: Controller processes<br/>injected command

    Host->>Bridge: 0xE4: Read Admin CQ (0xBC00)
    Bridge-->>Host: CID=0x4242, Status=Success
```

The sequence, ported from cyrozap's Python `pcie_gen_req()` function into Zig:

```
1. Read BAR0 via PCIe Config Read (bus=1, dev=0, fn=0, offset=0x10)
2. Compute doorbell address: BAR0 + 0x1000
3. Write new tail value (big-endian u32) to XRAM 0xB220
4. Write TLP header (3 x big-endian u32) to XRAM 0xB210:
   - 0x40000001 (Memory Write, 1 DW payload)
   - Byte-enable mask
   - Target address (doorbell, masked to 4-byte boundary)
5. Write 0x01 to XRAM 0xB296 (clear timeout flag)
6. Write 0x0F to XRAM 0xB254 (trigger TLP generation)
7. Poll XRAM 0xB296 bit 2 (wait for ready)
8. Write 0x04 to XRAM 0xB296 (send the TLP)
```

Each step required multiple 0xE5 writes (four bytes per u32, one SCSI command per byte). The full doorbell sequence was about 50 SCSI commands. But a posted memory write TLP has a beautiful property: the USB connection stays alive. Unlike a PCIe reset, which disconnects USB and forces device re-enumeration, a posted write is fire-and-forget. The NVMe controller processes it, and I can immediately read back results.

BAR0 came back as `0x00D00000`. Admin SQ Tail Doorbell address: `0x00D01000`.

### First Live Attempt -- And Silence

I started conservatively. Format NVM before Sanitize. Slot 4 (the first empty slot). Tail value 5 (one past the new entry). The `--force` flag to enable the doorbell:

```bash
$ sudo ./zig-out/bin/asm2362-tool inject \
    --inject-cmd=format --slot=4 --tail=5 --force /dev/sdc
```

The doorbell write succeeded. The USB connection stayed alive. No disconnects, no kernel errors. That alone was a minor victory -- earlier experiments using the 0xE8 PCIe reset as a crude doorbell substitute had crashed the USB link every time.

But the NVMe controller did not process the command. No completion entry appeared in the Completion Queue. The drive state was unchanged.

I tried different slots. Different tail values. Multiple commands in a row. Format, then Sanitize, then Set Features. All correctly written to XRAM, all verified byte-for-byte. The doorbell rang successfully each time. And nothing happened.

### The Admin CQ Discovery

The breakthrough came from looking at the Completion Queue -- or rather, from looking at the *right* Completion Queue. I had been reading the Admin CQ at XRAM 0xB800, which is where I expected it based on the memory map layout. But 0xB800 turned out to be the I/O Completion Queue. The Admin CQ was at 0xBC00.

When I read the correct address, the picture clarified instantly:

```bash
$ sudo ./zig-out/bin/asm2362-tool admin-cq /dev/sdc

Admin Completion Queue (0xBC00, 8 entries)
=============================================

  [0] SQHD=4 SQID=0 CID=0x0003 P=1 SCT=0 SC=0x00 DNR=0 (Success)
  [1] SQHD=3 SQID=0 CID=0x0002 P=1 SCT=0 SC=0x00 DNR=0 (Success)
  [2] SQHD=2 SQID=0 CID=0x0001 P=1 SCT=0 SC=0x00 DNR=0 (Success)
  [3] SQHD=1 SQID=0 CID=0x0000 P=1 SCT=0 SC=0x00 DNR=0 (Success)
  [4] (empty)
  [5] (empty)
  [6] (empty)
  [7] (empty)
```

Four completions. CIDs 0 through 3, matching the four firmware-initialized commands. And the critical field: **SQHD (Submission Queue Head) was 4**. The controller had consumed exactly 4 entries and stopped.

The queue depth was 4, not 8.

The XRAM had 512 bytes allocated for the Admin SQ -- room for 8 entries of 64 bytes each. But the bridge firmware had configured the NVMe controller with a queue size of 4 during initialization. Slots 4 through 7 existed in XRAM memory, but they were outside the controller's configured queue boundary. My carefully crafted, perfectly verified NVMe commands were sitting in memory that the controller would never read.

It was a classic off-by-one-class bug. Not in my code, but in my assumptions about the hardware. I had inferred queue depth from buffer size. The buffer was 8 entries. The queue was 4.

---

## Act 5: The Recovery

### The Winning Command

Armed with the correct queue depth, I reformulated everything. Slot 0 instead of slot 4. Tail value 1 instead of 5. Sanitize Block Erase with SANACT=2 (not Format NVM, which had proven ineffective even when correctly delivered). And a distinctive Command ID -- 0x4242 -- so I could unmistakably identify the completion entry:

```bash
$ sudo ./zig-out/bin/asm2362-tool inject \
    --inject-cmd=sanitize-block \
    --slot=0 --tail=1 --cid=0x4242 \
    --force /dev/sdc

  XRAM INJECTION -- EXPERIMENTAL
  Command: Sanitize Block Erase (0x84, SANACT=2)
  OPC=0x84, NSID=0x00000000, CDW10=0x00000002, CID=0x4242
  Explicit slot: 0
  Explicit tail: 1

Phase 1: Reading Admin SQ state...
Phase 2: Finding SQ slot...
  Using explicit slot 0
Phase 3: Writing 64 bytes to XRAM...
Phase 4: Verifying...
  All 64 bytes verified.
Phase 5: Ringing doorbell with tail=1...
  BAR0 = 0x00D00000
  Doorbell addr = 0x00D01000, writing tail = 1
  Doorbell rung successfully (USB alive)

Injection result:
  Slot used: 0
  Bytes written: 64
  Verified: true
  Doorbell rung: true
```

I held my breath and read the Admin CQ:

```
  [0] SQHD=1 SQID=0 CID=0x4242 P=1 SCT=0 SC=0x00 DNR=0 (Success)
```

**CID 0x4242. Phase bit 1. Status code 0x00. Success.**

The NVMe controller had accepted and was executing the Sanitize Block Erase command. Not a silent drop. Not a firmware refusal. Not a whitelist rejection. The command had been injected into the queue below the firmware's filtering layer, the doorbell had been rung via a synthesized PCIe memory write, and the NVMe controller had processed it.

### Watching the Sanitize

I tried running Identify Controller to check the drive state. The response came back as all zeros. This was expected -- during an active sanitize operation, the NVMe specification says the controller may return empty Identify data and should report "Sanitize In Progress" for most admin commands.

The sanitize was running. The USB link stayed alive throughout. No disconnects, no kernel errors, no UAS abort handlers. The bridge was peacefully unaware that a non-whitelisted command was being executed on the other side of its PCIe bus.

For a 256GB drive, Block Erase is relatively fast -- it operates at the NAND erase-block level, which is a bulk physical operation. After about a minute, I needed to force the controller to re-initialize with fresh state. I sent a CPU reset:

```bash
$ sudo ./zig-out/bin/asm2362-tool reset --reset-type=0 /dev/sdc
```

The USB device dropped and re-enumerated. I switched back to BOT mode (the reset had caused the kernel to reload UAS), then ran Identify again:

```bash
$ sudo ./zig-out/bin/asm2362-tool identify /dev/sdc
```

Full Identify Controller data came back. Not "Medium not present." Not zeros. Real, valid data:

```
VID:      0x1E4B (Phison)
Model:    SPCC M.2 PCIe SSD
Serial:   00000000000000001387
Firmware: H211011a
```

The controller was alive. The FTL had been rebuilt from scratch. The firmware protection mode was gone.

### The Moment of Truth

I wrote a test string to the drive:

```bash
$ echo "HIBERPOWER WRITE TEST" | sudo dd of=/dev/sdc bs=512 conv=fsync
$ sudo xxd -l 32 /dev/sdc
00000000: 4849 4245 5250 4f57 4552 2057 5249 5445  HIBERPOWER WRITE
00000010: 2054 4553 540a 0000 0000 0000 0000 0000   TEST...........
```

It was there. I read it back and the data matched. For the first time in weeks, this drive had accepted a write and actually committed it to NAND.

I ran a more rigorous test -- 1MB of random data, written and read back with comparison:

```bash
$ sudo dd if=/dev/urandom of=/dev/sdc bs=1M count=1 conv=fsync oflag=direct
1048576 bytes (1.0 MB) copied, 0.0592 s, 17.7 MB/s

$ sudo dd if=/dev/sdc of=/tmp/readback bs=1M count=1 iflag=direct
$ cmp /dev/urandom_seed /tmp/readback
# (no output -- files identical)
```

17.7 MB/s write throughput. Full read-back verification. Every byte correct.

I checked the Sanitize Status log (NVMe Log Page 0x81):

```
SSTAT:  0x0001  (Most Recent Sanitize: Completed Successfully)
SCDW10: 0x00000002  (Sanitize Action: Block Erase)
```

The sanitize had completed successfully. Block Erase. The FTL was clean.

### Formatting for Use

The drive was blank -- 256GB of erased NAND. I formatted it:

```bash
$ sudo mkfs.vfat -F 32 -n RECOVERED /dev/sdc
mkfs.fat 4.2 (2021-01-31)
```

A 239GB FAT32 volume, labeled "RECOVERED." I copied files to it, unmounted, remounted, verified the files. Everything worked. The drive was recovered.

---

## What We Learned

Six weeks of work distilled into eight lessons. Some obvious in hindsight, some genuinely surprising.

### 1. USB Bridges Are Not Transparent

This is the most important takeaway for anyone debugging storage issues on USB-attached drives. You are not talking to the drive. You are talking to a bridge chip that has its own 8051 CPU, its own firmware, and its own opinions about which commands deserve to be forwarded. The ASM2362 silently drops six of eight NVMe admin opcodes while returning SCSI Good status. It generates SCSI error codes ("Medium not present") for a protocol concept (removable media) that does not exist in NVMe.

If your tool reports success but nothing changes, consider the possibility that a middleman is lying to you.

### 2. Silent Failures Are the Worst Debugging Experience

An error message, even a bad one, at least tells you something went wrong. When `dd` reports "512 bytes copied" and the bytes were never copied, you have entered a reality distortion field. You start questioning your tools, your kernel, your understanding of how block devices work. The problem is in none of those places. It is in the firmware of a bridge chip that decided your command was not worth forwarding.

Loud failures are gifts. Silent ones are traps.

### 3. "Medium Not Present" Is a SCSI Lie

ASC 0x3A means "MEDIUM NOT PRESENT" in SCSI terminology. It was designed for removable media -- CD-ROM drives with empty trays, tape drives with no cartridge. NVMe SSDs have no concept of removable media. The ASM2362 generates this error when the NVMe controller does not respond as expected during initialization, or when it receives an opcode it does not recognize. The medium IS present. The bridge just cannot (or will not) talk to it through the requested channel.

If you see "Medium not present" on a fixed-media device, the error is probably being generated by a translation layer, not by the storage device itself.

### 4. XRAM Is the Real Attack Surface

The 0xe6 passthrough is the "official" API for NVMe commands through the bridge. It is also the filtered, sanitized, whitelisted API. The 0xE4/0xE5 vendor commands provide raw access to the bridge's internal working memory -- no filtering, no whitelist, no firmware opinions.

The NVMe Admin Submission Queue is just a data structure in that XRAM. Write the right 64 bytes to the right address and you have injected an arbitrary NVMe admin command. The bridge firmware does not know it happened. The NVMe controller does not care how the command got there.

### 5. NVMe Queue Depths Vary

I assumed the Admin SQ had 8 entries because the XRAM buffer was 512 bytes (8 times 64 bytes). The actual queue depth was 4. The firmware configured a 4-entry queue during initialization, and the extra XRAM was unused padding. Commands written to slots 4-7 were in valid memory but outside the controller's queue boundary.

Always read the Completion Queue to determine actual queue depth. The SQHD (Submission Queue Head) field in CQ entries tells you exactly how many entries the controller has consumed.

### 6. BOT Mode vs. UAS Mode Matters for Vendor Commands

Modern USB storage devices negotiate UAS for better performance. UAS is faster but stricter about command formats. The ASM2362's vendor SCSI commands (0xE4, 0xE5, 0xE8) use non-standard CDB sizes and transfer patterns that UAS cannot handle. You must force the device into Bulk-Only Transport mode with `modprobe usb-storage quirks=174c:2362:u` for vendor commands to work.

Standard SCSI commands (INQUIRY, READ, WRITE) work fine under either protocol. The vendor commands are the ones that need BOT.

### 7. Sanitize Block Erase Is More Powerful Than Format NVM

I tried Format NVM (opcode 0x80) first. Even when correctly injected and accepted by the controller (the CQ showed success), it did not clear the FTL corruption. Sanitize Block Erase (opcode 0x84, SANACT=2) did.

The difference: Format NVM performs a logical format of individual namespaces -- it reinitializes the namespace metadata but does not necessarily erase the underlying NAND or rebuild the FTL. Sanitize Block Erase performs a physical erase of all NAND blocks across the entire controller, forcing a complete FTL rebuild from scratch.

For firmware-level write protection caused by FTL corruption, Sanitize is the right tool. Format is insufficient.

### 8. The Entire Recovery Was Done Through USB

No M.2 slot required. No soldering. No opening the laptop case. No borrowing a desktop with a spare NVMe slot. The USB bridge that was filtering my commands also provided the attack surface (XRAM access via 0xE4/0xE5) to bypass its own filtering, and the mechanism (PCIe TLP engine at 0xB200) to ring the NVMe doorbell without resetting the USB link.

Sometimes the obstacle is the path. The $15 USB enclosure that caused all the problems also contained all the tools needed to solve them.

---

## What This Means for You

If you have a "bricked" NVMe SSD in a USB enclosure -- one that reads but does not write, or reports "Medium not present," or shows zero capacity -- it might be recoverable using this technique. The prerequisites:

1. **Your USB enclosure uses an ASMedia ASM236x bridge chip.** Check with `lsusb` for VID `174c`. The ASM2362 (PID `2362`) is the most common in M.2 NVMe enclosures, but the entire ASM236x family uses the same vendor SCSI commands.

2. **The bridge firmware supports 0xE4/0xE5 vendor commands.** All known ASM236x firmware versions do, but always test with a safe read-only probe first.

3. **The failure is FTL corruption, not physical NAND damage.** If the NAND cells themselves are worn out or physically damaged, no software command can help. But if the controller entered read-only mode due to FTL corruption -- the most common failure after power loss -- a Sanitize Block Erase can reset it.

4. **You do not need the data.** Sanitize Block Erase destroys everything. This is a drive recovery technique, not a data recovery technique. The goal is to make the hardware functional again, not to retrieve the old contents.

Professional NVMe recovery costs $300 to $1,500 and typically requires specialized hardware like the PC-3000 SSD. This approach costs time and a willingness to read firmware documentation. The tool is open source: approximately 4,000 lines of Zig with 35 unit tests.

---

## Technical Appendix

### The Winning Command Sequence

Three commands. That is all it takes once you know the right parameters:

```bash
# 1. Switch to BOT mode (required for vendor SCSI commands)
sudo bash -c '
  echo "<port>" > /sys/bus/usb/drivers/usb/unbind
  rmmod uas; rmmod usb_storage
  modprobe usb-storage quirks=174c:2362:u
  echo "<port>" > /sys/bus/usb/drivers/usb/bind
'

# 2. Inject Sanitize Block Erase into Admin SQ slot 0
sudo asm2362-tool inject \
    --inject-cmd=sanitize-block \
    --slot=0 --tail=1 --cid=0x4242 \
    --force /dev/sdX

# 3. CPU reset to force NVMe re-initialization
sudo asm2362-tool reset --reset-type=0 /dev/sdX
```

### How to Switch to BOT Mode

Find your USB port number with `lsusb -t` or check `dmesg` for the ASM2362 enumeration. The port ID (e.g., "1-3") is the USB topology address. The `quirks` parameter format is `VID:PID:flags` where `u` means "ignore UAS, use BOT."

Verify the switch worked:

```bash
$ readlink /sys/devices/.../1-3:1.0/driver
# Should show: usb-storage (not uas)
```

### Key XRAM Addresses

| Address Range | Size | Contents |
|---------------|------|----------|
| 0x07F0 | 6B | Firmware version string |
| 0xA000-0xAFFF | 4KB | NVMe I/O Submission Queue |
| 0xB000-0xB1FF | 512B | NVMe Admin Submission Queue (8 slots, depth may be less) |
| 0xB200-0xB296 | ~150B | PCIe TLP engine registers |
| 0xBC00-0xBC7F | 128B | NVMe Admin Completion Queue |
| 0xF000-0xFFFF | 4KB | NVMe data buffer |

### References

- [cyrozap/usb-to-pcie-re](https://github.com/cyrozap/usb-to-pcie-re) -- ASM2362 firmware reverse engineering, the foundation this work is built on
- [NVMe Base Specification 2.0](https://nvmexpress.org/specifications/) -- SMART Critical Warning, Sanitize command, SQ/CQ structure
- [smartmontools](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/scsinvme.cpp) -- Reference `sntasmedia_device` 0xe6 implementation
- [smx-smx/ASMTool](https://github.com/smx-smx/ASMTool) -- ASMedia firmware dumper
- [Phison PS5012 Recovery Tools](https://www.usbdev.ru/files/phison/ps5012reinitialtool/) -- Vendor-specific recovery for Phison controllers

---

## Research Paper

The full technical paper covers the NVMe specification details, XRAM memory layout, PCIe TLP doorbell mechanism, and complete injection workflow in IEEE conference format.

<iframe
  src="/papers/recovery-paper.pdf"
  class="w-full rounded-lg"
  style="height: 85vh; min-height: 600px; border: 1px solid #e5e7eb;"
  title="XRAM Injection: Recovering Write-Protected NVMe SSDs Through USB Bridge Memory Manipulation"
></iframe>

<a href="/papers/recovery-paper.pdf" download class="inline-block mt-4 text-sm underline">Download PDF</a>

---

*This post documents a recovery performed in January through March 2026. The drive was a 256GB Silicon Power NVMe SSD with a Phison PS5012-E12 controller that entered firmware read-only mode after a Windows hibernate power loss event. Total cost of recovery: $0 and six weeks of evenings. The drive is currently formatted and in active use as removable storage.*
