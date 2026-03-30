# hiberpower Roadmap

## Phase 0: Firmware Management (HIGHEST PRIORITY)

**Goal**: Read, validate, and write ASM2362 SPI flash firmware via Linux SCSI vendor commands. This is the immediate priority — we discovered that a common class of ASM2362 enclosures ship with firmware that only exposes USB 2.1 descriptors (no BOS/SuperSpeed capability), permanently limiting them to USB 2.0 speeds and causing I/O failures on macOS.

| Issue | Title | Status |
|-------|-------|--------|
| #16 | Add 0xE2 (flash read) and 0xE3 (firmware write) commands | **In Progress** |
| #17 | BOS descriptor decode/validation tool | Open |

### Key Discovery (2026-03-30)

The root cause of the macOS EINTR bug is **not** an OS driver issue — it's the enclosure firmware:
- `bcdUSB=0x0210` (USB 2.1) with no BOS SuperSpeed Device Capability descriptor
- Device never attempts USB 3.x link training → stuck at 480 Mbps
- macOS I/O subsystem times out at USB 2.0 speeds → returns EINTR
- Linux works because its USB stack has different timeout behavior
- Full analysis: `docs/research/macos-apfs-bot-eintr.md`

### Firmware Flash Workflow

```
0xE2 (Flash Read)  → dump current firmware as backup
0xE0 (Read Config) → read bridge configuration (descriptor tables)
0xE3 (Firmware Write) → flash updated firmware with BOS/SS capability
0xE8 (Reset) → reboot bridge with new firmware
```

All via SCSI vendor commands — no Windows or MPTool required.

## Phase 1: macOS IOKit Native Support (Milestone #1)

**Status**: Platform abstraction complete (#3, #9), IOKit backend implemented (#4, #10). Runtime testing confirmed `kIOReturnUnsupported` for SCSITaskUserClient on storage devices (Apple QA1179). **Deprioritized** — the real fix for macOS compatibility is firmware (Phase 0), not a driver workaround.

| Issue | Title | Status |
|-------|-------|--------|
| #3 | Platform abstraction layer | **Merged** (PR #9) |
| #4 | IOKit SCSI passthrough backend | **Merged** (PR #10) — blocked by QA1179 |
| #5 | macOS device discovery | Open (deprioritized) |
| #6 | macOS CI + test matrix | Open |
| #7 | macOS binary distribution | Open |
| #13 | USB BOT approach investigation | Closed — all userspace paths blocked |

**Future path**: DriverKit DEXT if firmware fix is insufficient. Requires Apple developer entitlements.

## Phase 2: Cross-Platform Release Pipeline (v1.0)

- GoReleaser 2.5+ with Zig cross-compilation
- Static musl binaries for Linux (single binary, all distros)
- macOS: dynamic link to IOKit.framework (for future DEXT support)
- GitHub Releases with SHA256 checksums + GPG signatures
- Homebrew tap: `jesssullivan/hiberpower`

## Phase 3: Package Manager Distribution (v1.1)

- nixpkgs contribution (Zig build derivation)
- AUR PKGBUILD
- macOS notarized PKG installer

## Phase 4: Expanded Distro Coverage (v1.2)

- Fedora COPR / RPM spec
- Debian PPA / DEB packaging
- EPEL for RHEL/Rocky

## Chassis Redesign

Given the firmware discovery, a redesigned enclosure chassis should:

1. **Ship with verified firmware** — BOS descriptor with SuperSpeed Device Capability confirmed
2. **Enable UAS** — `bInterfaceProtocol=0x62` alongside BOT for concurrent command queuing
3. **Thermal management** — ASM2362 + NVMe throttle under sustained write at full USB 3.1 Gen 2 speed
4. **Cable quality** — bundle USB 3.2 Gen 2 certified cable (not USB 2.0 charging cable)
5. **Test matrix** — verify enumeration on macOS (M1-M4), Linux, Windows at SuperSpeed
6. **Firmware update path** — document how end-users can reflash via asm2362-tool

## Future: Scope Expansion

The `hiberpower` name grows beyond ASM2362 recovery:

- **Firmware management**: Read/write/validate bridge SPI flash (Phase 0)
- **USB descriptor validation**: BOS, SuperSpeed capability, UAS detection
- **USB-SATA bridges**: JMicron, ASMedia 1352R diagnostics
- **Standalone NVMe**: Direct NVMe health monitoring (no bridge)
- **Hibernation analysis**: NTFS hiberfil.sys parsing (original use case)
- **Device lifecycle**: TRIM, secure erase, power state management
- **Additional vendors**: Realtek, JMS578, VL716 bridge support

## Naming

Current: `hiberpower-ntfs` (scoped to NTFS hibernation recovery)
Proposed: `hiberpower` (general USB/NVMe bridge diagnostics + firmware management suite)
