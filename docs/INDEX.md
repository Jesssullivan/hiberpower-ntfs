# Documentation Index

This directory contains research notes, analysis, and workflow documentation for the ASM2362 NVMe recovery project.

## Research Notes (`notes/`)

| Document | Description |
|----------|-------------|
| [debug-session-summary.md](notes/debug-session-summary.md) | Hardware stack identification, ASM2362 bridge detection |
| [diagnosis-findings.md](notes/diagnosis-findings.md) | Silent write failure evidence, test methodology |
| [hardware-test-results.md](notes/hardware-test-results.md) | asm2362-tool probe/identify command outputs |
| [linux-kernel-investigation.md](notes/linux-kernel-investigation.md) | Linux block layer, USB storage, SCSI translation analysis |
| [literature-review.md](notes/literature-review.md) | Academic papers, CVEs, and recovery tools survey |
| [lowlevel-tools-guide.md](notes/lowlevel-tools-guide.md) | sg_io, nvme-cli, hdparm usage reference |
| [ntfs-hibernate-research.md](notes/ntfs-hibernate-research.md) | Windows hibernation mechanisms and corruption patterns |
| [nvme-protocol-analysis.md](notes/nvme-protocol-analysis.md) | NVMe spec analysis, write protection states, admin commands |
| [phase3-research-summary.md](notes/phase3-research-summary.md) | SP Toolbox reverse engineering, Frida hook development |
| [qemu-reproduction-setup.md](notes/qemu-reproduction-setup.md) | VM environment for reproducing corruption |
| [vm-setup-status.md](notes/vm-setup-status.md) | Windows VM configuration status |

## Analysis (`analysis/`)

| Document | Description |
|----------|-------------|
| [sp-toolbox-binary-analysis.md](analysis/sp-toolbox-binary-analysis.md) | Decompilation findings from SP Toolbox V4.1.2 |

## Research (`research/`)

| Document | Description |
|----------|-------------|
| [deep-research-synthesis.md](research/deep-research-synthesis.md) | **START HERE** - Feb 2026 research synthesis, priority stack, key findings |
| [unlock-sequence.md](research/unlock-sequence.md) | Hypothesized unlock command sequences for Phison controllers |

## Workflows (`workflows/`)

| Document | Description |
|----------|-------------|
| [frida-capture-workflow.md](workflows/frida-capture-workflow.md) | Procedure for capturing vendor commands via Frida |

## Planning

| Document | Description |
|----------|-------------|
| [PHASE4-INVESTIGATION-PLAN.md](PHASE4-INVESTIGATION-PLAN.md) | Current investigation tracks (Wine, VM, USB capture, binary RE) |

## Technical Paper (`paper/`)

| Document | Description |
|----------|-------------|
| [recovery-paper.tex](paper/recovery-paper.tex) | LaTeX technical reference paper: "Recovering Write-Protected NVMe SSDs via USB Bridge XRAM Command Injection" |
| [references.bib](paper/references.bib) | BibTeX references for the paper |

## Blog Posts (`blog/`)

| Document | Description |
|----------|-------------|
| [recovery-journey.mdx](blog/recovery-journey.mdx) | **The Journey** -- Narrative blog post covering the full recovery story from discovery to success |
| [xram-injection-guide.mdx](blog/xram-injection-guide.mdx) | **Technical Deep Dive** -- Complete reference guide for ASM2362 XRAM injection technique |

## Archive (`archive/`)

| Document | Description |
|----------|-------------|
| [dead-ends-e6-whitelist.md](archive/dead-ends-e6-whitelist.md) | **Why Format/Sanitize fail through 0xe6** — whitelist analysis, evidence, XRAM replacement |
| [format.zig.txt](archive/format.zig.txt) | Archived: NVMe Format NVM via 0xe6 passthrough (dead, blocked by whitelist) |
| [sanitize.zig.txt](archive/sanitize.zig.txt) | Archived: NVMe Sanitize via 0xe6 passthrough (dead, blocked by whitelist) |
| [original-project-charter.md](archive/original-project-charter.md) | Original PROJECT.md with initial research objectives |
