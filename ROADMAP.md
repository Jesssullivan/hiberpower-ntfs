# hiberpower Roadmap

## Phase 1: macOS IOKit Native Support (Milestone #1)

**Goal**: Run all diagnostic commands on macOS via IOKit SCSITaskUserClient.

| Issue | Title | Status |
|-------|-------|--------|
| #3 | Platform abstraction layer | Open |
| #4 | IOKit SCSI passthrough backend | Open |
| #5 | macOS device discovery | Open |
| #6 | macOS CI + test matrix | Open |
| #7 | macOS binary distribution | Open |

**Architecture**: Extract `sg_io.zig` → `src/platform/{scsi,linux,darwin}.zig`. All 4,100+ lines of portable Zig (CDB builders, XRAM logic, SMART parsing) remain untouched.

**Reference**: LTFS IOKit implementation for SCSITaskUserClient pattern.

## Phase 2: Cross-Platform Release Pipeline (v1.0)

- GoReleaser 2.5+ with Zig cross-compilation
- Static musl binaries for Linux (single binary, all distros)
- macOS: dynamic link to IOKit.framework
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

## Future: Scope Expansion

The `hiberpower` name could grow beyond ASM2362 to cover:

- **USB-SATA bridges**: JMicron, ASMedia 1352R diagnostics
- **Standalone NVMe**: Direct NVMe health monitoring (no bridge)
- **Firmware updates**: Bridge + NVMe firmware flash
- **Hibernation analysis**: NTFS hiberfil.sys parsing (original use case)
- **Device lifecycle**: TRIM, secure erase, power state management
- **Additional vendors**: Realtek, JMS578, VL716 bridge support

## Naming

Current: `hiberpower-ntfs` (scoped to NTFS hibernation recovery)
Proposed: `hiberpower` (general USB/NVMe bridge diagnostics suite)

The rename reflects the tool's evolved scope while preserving the project's identity.
