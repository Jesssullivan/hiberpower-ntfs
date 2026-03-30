# RFC: hiberpower Cross-Platform Distribution

**Status**: Draft
**Author**: Jess Sullivan
**Date**: 2026-03-29

## Motivation

hiberpower is currently distributed as source-only, requiring users to install Zig and build from source. As macOS support is added and the tool's scope expands beyond ASM2362 NTFS recovery, a proper distribution strategy is needed.

## Proposed Name

**`hiberpower`** (dropping `-ntfs` suffix)

Rationale: The tool has evolved from NTFS hibernation file recovery to a general-purpose USB-NVMe bridge diagnostic suite. The shorter name is:
- Easier to type as a CLI command
- Not misleading about scope
- Available on most package registries

## Platform Matrix

| Target | Binary Type | Notes |
|--------|-------------|-------|
| `x86_64-linux-musl` | Static | Single binary for all Linux distros |
| `aarch64-linux-musl` | Static | ARM64 Linux (Raspberry Pi, servers) |
| `x86_64-macos` | Dynamic | Links IOKit.framework |
| `aarch64-macos` | Dynamic | Apple Silicon |

Linux uses musl static linking to eliminate glibc version dependency. macOS requires dynamic linking to IOKit.framework for SCSI passthrough.

## Distribution Channels

### Tier 1: Immediate (v1.0)

**GitHub Releases**
- Cross-compiled binaries for all 4 platforms
- SHA256 checksums with GPG signature
- GoReleaser 2.5+ orchestration (native Zig support)
- Triggered by `git tag v*`

**Homebrew Tap**
```bash
brew tap jesssullivan/hiberpower
brew install hiberpower
```

Formula auto-detects platform (Intel vs Apple Silicon).

### Tier 2: Community (v1.1)

**nixpkgs**
```nix
{ lib, stdenv, fetchFromGitHub, zig }:
stdenv.mkDerivation {
  pname = "hiberpower";
  version = "1.0.0";
  src = fetchFromGitHub { owner = "Jesssullivan"; repo = "hiberpower"; ... };
  nativeBuildInputs = [ zig ];
  buildPhase = "zig build -Doptimize=ReleaseSafe --prefix $out";
  meta.platforms = lib.platforms.unix;
}
```

**AUR (Arch Linux)**
```bash
yay -S hiberpower
```

### Tier 3: Enterprise (v1.2)

**Fedora COPR / RPM**
- RPM spec file in `packaging/rpm/hiberpower.spec`
- Submit to COPR for Fedora/RHEL/Rocky

**Debian PPA / DEB**
- debian/ directory with control, rules, changelog
- Launchpad PPA for Ubuntu

**EPEL**
- For RHEL/CentOS/Rocky enterprise use
- Requires Fedora package review first

### macOS Notarization

CLI binaries cannot be notarized directly. Options:
1. **PKG installer** — `pkgbuild` + `notarytool submit` + `stapler staple`
2. **DMG wrapping** — Less ideal for CLI tools
3. **Skip notarization** — Users get Gatekeeper warning, dismissable for signed binaries

Recommendation: PKG installer for official releases, raw binary in tar.gz for power users.

## CI/CD Pipeline

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ["v*"]
jobs:
  build:
    strategy:
      matrix:
        include:
          - target: x86_64-linux-musl
            runner: ubuntu-latest
          - target: aarch64-linux-musl
            runner: ubuntu-latest
          - target: x86_64-macos
            runner: macos-13
          - target: aarch64-macos
            runner: macos-14
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
      - run: zig build -Dtarget=${{ matrix.target }} -Doptimize=ReleaseSafe
      - uses: actions/upload-artifact@v4

  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
      - run: sha256sum hiberpower-* > checksums.txt
      - uses: softprops/gh-release@v2
```

## Future Scope

The distribution infrastructure should accommodate expansion to:
- Additional bridge chipsets (JMicron, Realtek, VL716)
- Standalone NVMe diagnostics
- Firmware update capabilities
- Windows support (if demand warrants)

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Static musl for Linux | Eliminates glibc version matrix |
| GoReleaser for CI | Native Zig support, single config |
| Homebrew over MacPorts | Larger user base, simpler formula |
| PKG for macOS notarization | Only staple-able format for CLI |
| nixpkgs PR over flake-only | Broader discoverability |
