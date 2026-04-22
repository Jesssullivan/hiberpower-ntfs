# USB Link Negotiation Field Report (April 2026)

**Date**: 2026-04-22

## Why This Note Exists

This note captures a third failure class for the recovered ASM2362 + NVMe path.

This repo already documents two distinct states:

- the original controller-protection failure (`Medium not present`, zero/invalid
  capacity, blocked admin path)
- the later Darwin automation / access-policy problem, where recovered media is
  usable but some macOS execution contexts cannot operate on the mounted APFS
  volume

This note records a separate transport problem seen during fresh field retests:

- the bridge advertises USB 3.x capability
- the media reports normal capacity and remains readable
- but the negotiated USB link falls back to **High Speed / 480Mbps**

That should not be confused with the original recovery failure.

## Current Field Findings

### macOS Hosts

Two separate macOS hosts showed the same transport ceiling on direct USB-C
paths:

- bridge fingerprint remained `174c:2362` / `ASM236X series`
- the external disk still mounted normally as APFS
- live USB inspection still reported `UsbLinkSpeed=480000000`
- `Device Speed=2` remained the negotiated state

Interpretation:

- the enclosure is still usable enough to enumerate and mount
- but it is not reaching a healthy SuperSpeed path on either tested Mac

### Linux Host With USB-C to USB-A Path

On a Linux laptop using a dedicated USB-C to USB-A cable connected directly to a
port marked for SuperSpeed:

- `lsusb -t` still placed the ASM2362 on the USB 2.0 tree at `480M`
- the enclosure bound `usb-storage`, not a higher-speed path
- the NVMe still appeared normally as `/dev/sda`

Most important detail:

- `lsusb -v -d 174c:2362` showed that the bridge still advertises:
  - `SuperSpeed (5Gbps)`
  - `SuperSpeedPlus (10Gb/s)`
- but the **negotiated** speed still landed at `High Speed (480Mbps)`

Interpretation:

- the bridge does not currently look like it has collapsed into a permanently
  USB-2-only descriptor personality
- the current failure looks more like link negotiation or signal-path
  degradation than a dead media/controller relapse

## Read-Only Bridge Probes On The 480Mbps Path

Read-only `hiberpower-ntfs` probes on the Linux `480M` path sharpen the
distinction further:

- `asm2362-tool probe /dev/sda`
  - `READY`
  - normal `256060514304`-byte capacity
  - normal SCSI identity (`ASMT 2360 NVME`)
- `asm2362-tool config-read /dev/sda --image=0`
  - succeeded
- `asm2362-tool config-read /dev/sda --image=1`
  - succeeded
- `asm2362-tool xram-probe /dev/sda`
  - succeeded
  - could read XRAM, the live Admin Submission Queue, and PCIe MMIO
- `asm2362-tool identify /dev/sda`
  - failed with `Invalid command`
- `asm2362-tool smart /dev/sda --json`
  - failed with `Invalid command`
- `smartctl -d sntasmedia -i -H /dev/sda`
  - failed with unsupported opcode

Those failures match the later healthy-Linux notes in this repo more closely
than the older `Medium not present` failure class.

Interpretation:

- the bridge is still alive enough for read-only vendor XRAM access
- the media still presents normal capacity
- the current `480Mbps` state does **not** look like a return to the original
  recovery problem

## What This Does Not Prove

This evidence does **not** prove that the cable is good.

It only narrows the explanation:

- it weakens "the bridge is back in the old dead/protected state"
- it weakens "the firmware only exposes a USB-2-only personality now"
- it does **not** eliminate:
  - cable quality or cable class
  - connector wear
  - host port signal path
  - enclosure hardware degradation

## Golden Cable Trifecta

The cleanest next validation step is a known-good reference matrix:

1. one short, known-good `USB-C ↔ USB-C` cable
2. one short, known-good `USB-A ↔ USB-C` cable
3. the same enclosure tested across three host paths:
   - Apple Silicon Mac host A
   - Apple Silicon Mac host B
   - Linux host with USB-A path

Success criterion:

- any test that negotiates at `5000M` or better proves the current path is not
  inherently locked to USB 2.0

Failure criterion:

- if the same enclosure still negotiates only `480Mbps` across all three
  reference paths, the enclosure / bridge hardware becomes the primary suspect

## Relationship To Other Notes

- For the original recovery failure, see
  [hardware-test-results.md](hardware-test-results.md)
- For the post-recovery Darwin automation / policy problem, see
  [darwin-post-recovery-integration.md](darwin-post-recovery-integration.md)
