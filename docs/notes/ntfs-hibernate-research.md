# NTFS Hibernation and Fast Startup: Mechanisms for Persistent Drive Corruption

**Research Date:** 2026-01-21
**Focus:** Windows hibernation mechanisms that can corrupt NVMe drives to resist Linux reformatting

---

## Table of Contents

1. [Windows Hibernation File (hiberfil.sys)](#1-windows-hibernation-file-hiberfilsys)
2. [Fast Startup (Hybrid Shutdown)](#2-fast-startup-hybrid-shutdown)
3. [NTFS Metadata Structures During Hibernate](#3-ntfs-metadata-structures-during-hibernate)
4. [Volume Dirty Bit Mechanism](#4-volume-dirty-bit-mechanism)
5. [NTFS Metadata Persistence After Partition Deletion](#5-ntfs-metadata-persistence-after-partition-deletion)
6. [Why ntfs-3g Refuses to Mount Hibernated Volumes](#6-why-ntfs-3g-refuses-to-mount-hibernated-volumes)
7. [Power Loss During Hibernate Write](#7-power-loss-during-hibernate-write)
8. [Persistent Corruption Scenarios](#8-persistent-corruption-scenarios)
9. [Recovery and Mitigation](#9-recovery-and-mitigation)
10. [Sources](#10-sources)

---

## 1. Windows Hibernation File (hiberfil.sys)

### Overview

When Windows hibernates, it saves the entire contents of RAM to a file called `hiberfil.sys` located in the root of the system volume. This allows the system to resume exactly where it left off, with all applications and data intact.

### File Structure

The hibernation file has a proprietary Microsoft format with the following characteristics:

| Component | Description |
|-----------|-------------|
| **Header (PO_MEMORY_IMAGE)** | First 4096 bytes containing memory image information |
| **Signature** | "HIBR" for exploitable hibernation, "RSTR" when resuming, "wake" as alternate |
| **Compression** | LZ77+ Huffman XPRESS algorithm (Microsoft proprietary) |
| **Page Size** | 4096 bytes per page |
| **Key Fields** | `FirstBootRestorePage`, `FirstKernelRestorePage` for restoration sets |

### Header Signatures and Their Meaning

| Signature | State | Implications |
|-----------|-------|--------------|
| `HIBR` | System hibernated | Volume in frozen state; unsafe to modify |
| `RSTR` | Resume in progress | System actively restoring from hibernation |
| `wake` | Alternate valid state | System was in sleep/wake cycle |
| `0x00...` | Zeroed/empty | Hibernation enabled but not active; safe |

### File Size

The hiberfil.sys file is typically 40-75% of installed RAM. For systems with Fast Startup enabled, a reduced hibernation file (hiberfiletype reduced) stores only kernel session data.

### Interaction with NTFS Metadata

When hibernation occurs:

1. Windows sets a hibernation flag within hiberfil.sys
2. The NTFS driver's metadata cache is preserved in the hibernation image
3. All pending $LogFile transactions are frozen mid-state
4. $MFT entries reflect the hibernated moment, not current disk state

---

## 2. Fast Startup (Hybrid Shutdown)

### What Fast Startup Actually Does

Introduced in Windows 8 and **enabled by default** in Windows 10/11, Fast Startup performs a "hybrid shutdown":

1. User session is logged off (applications closed)
2. Kernel session is hibernated (not shut down)
3. Kernel image and loaded drivers written to hiberfil.sys
4. System powers off

On next boot, Windows restores the kernel image rather than performing full initialization, dramatically reducing boot time.

### Critical Implication

**A "Shutdown" is NOT a shutdown when Fast Startup is enabled.** The system is hibernated, and the NTFS volume remains in a frozen state with:

- Dirty bit set to ON
- Hibernation flag active
- NTFS metadata cache preserved
- $LogFile journal in incomplete state

### Why This Causes Problems

| Action | Result with Fast Startup |
|--------|--------------------------|
| Shutdown from Start Menu | Hybrid hibernation (volume locked) |
| Restart | True cold boot (volume unlocked) |
| Hold Shift + Shutdown | True shutdown (volume unlocked) |
| Sleep/Hibernate explicitly | Full hibernation (volume locked) |

### Filesystem State After Hybrid Shutdown

```
Volume State: HIBERNATED
  - hiberfil.sys: Contains HIBR signature
  - $Volume dirty bit: SET (0x01)
  - $MFT: Cached state preserved
  - $LogFile: Uncommitted transactions frozen
  - $Bitmap: May not reflect actual allocation
```

---

## 3. NTFS Metadata Structures During Hibernate

### Critical NTFS Metafiles

| Metafile | Purpose | Hibernate Impact |
|----------|---------|------------------|
| `$MFT` | Master File Table - all file/directory records | Cached state frozen; external changes invisible |
| `$MFTMirr` | Backup of first 4 MFT entries | Synced with $MFT at hibernate time |
| `$LogFile` | Transaction journal | Incomplete transactions preserved |
| `$Volume` | Volume metadata, dirty bit | Dirty bit remains set |
| `$Bitmap` | Cluster allocation bitmap | May not reflect actual allocation |
| `$AttrDef` | Attribute definitions | Static, less affected |
| `$Secure` | Security descriptors | Cached ACLs preserved |

### The Metadata Cache Problem

Windows maintains an in-memory metadata cache for NTFS that includes:

- File names and timestamps
- Directory structures
- List of unallocated MFT records
- Pending allocation changes

**This cache is NOT invalidated on resume.** When Windows resumes from hibernation, it assumes the disk state matches its cached state.

### $LogFile (Transaction Journal)

The $LogFile ensures NTFS consistency through write-ahead logging:

1. Before any metadata change, the intended change is logged
2. The actual change is made to disk
3. The log entry is marked complete

During hibernation, this journal may contain:
- Uncommitted transactions (started but not completed)
- Redo records (changes to be applied)
- Undo records (rollback information)

If the volume is modified externally, the journal becomes inconsistent with actual disk state.

### $MFT Consistency

The Master File Table contains:
- File record segments (1024 bytes each typically)
- Standard information (timestamps, attributes)
- File names (short and long)
- Data run information (file location on disk)

Changes made to the volume while Windows is hibernated will:
1. Not be visible to Windows after resume
2. Potentially be overwritten when Windows flushes its cache
3. Cause $MFT/$MFTMirr mismatches

---

## 4. Volume Dirty Bit Mechanism

### Location and Structure

The dirty bit is stored in the `$Volume` metafile. Its exact offset varies by volume, but follows a consistent pattern:

**Locating the dirty bit:**
- Search for hex pattern: `03 01 ... 80 00 00 00 18` (13 bytes)
- Usually within first two sectors of the volume
- For FAT32: offset 0x41 (value 0x01 = dirty)

### States

| Value | Meaning |
|-------|---------|
| 0x00 | Clean - volume properly unmounted |
| 0x01 | Dirty - volume not properly unmounted |

### What Sets the Dirty Bit

1. System crash or power loss
2. Hibernation (including Fast Startup hybrid shutdown)
3. Ungraceful shutdown (power button hold, battery removal)
4. Pending Windows updates
5. Scheduled chkdsk operations
6. Hardware errors detected by NTFS driver

### Clearing the Dirty Bit

The **only** proper way to clear the dirty bit:

```cmd
chkdsk /r [volume]    # Full repair
chkdsk /f [volume]    # Fix errors
```

The following do NOT clear the dirty bit:
- `CHKNTFS` (only schedules/skips chkdsk)
- Simple reboot
- Hibernate/resume cycle

### Fast Startup and Persistent Dirty Bit

With Fast Startup enabled:

1. Every "shutdown" sets the dirty bit
2. The bit remains set until true shutdown + chkdsk
3. Restart clears it (true cold boot)
4. Linux sees dirty bit and refuses read-write mount

---

## 5. NTFS Metadata Persistence After Partition Deletion

### What Survives Partition Deletion

| Operation | Data Preserved | Metadata Preserved |
|-----------|---------------|-------------------|
| Delete partition (fdisk/gdisk) | Yes | Yes (until overwritten) |
| Quick format | Yes | Index cleared, data intact |
| Full format | No (zeros written) | No |
| MBR to GPT conversion | Depends on tool | Usually preserved |
| wipefs | Yes | Signatures removed |
| dd if=/dev/zero | No | No |

### Why NTFS Metadata Can Persist

1. **Partition table is separate from filesystem**: Deleting a partition only removes the entry from MBR/GPT; actual data remains
2. **Quick format only clears indexes**: File data and most metadata structures remain until overwritten
3. **$MFT records are reused slowly**: Deleted file metadata persists until the MFT entry is needed
4. **NTFS backup boot sector**: Located at last sector of partition, survives many operations

### MFT Recovery Window

The $MFT backup copy exists in the middle of the volume, allowing recovery tools to:
- Reconstruct corrupted primary MFT
- Find deleted file records
- Recover partition structure information

### SSD TRIM Complications

On SSDs with TRIM enabled:
- Deleted data is actively erased for wear leveling
- Recovery is significantly harder or impossible
- However, metadata in active areas may still persist

---

## 6. Why ntfs-3g Refuses to Mount Hibernated Volumes

### The Error Message

```
Windows is hibernated, refused to mount.
Failed to mount '/dev/sdXn': Operation not permitted
The NTFS partition is in an unsafe state.
Please resume and shutdown Windows fully (no hibernation or fast restarting).
Falling back to read-only mount because the NTFS partition is in an unsafe state.
```

Exit code: 14 (hibernation detected)

### Detection Mechanism

ntfs-3g checks for:

1. **hiberfil.sys signature**: Looks for HIBR/wake/RSTR signatures
2. **Volume dirty bit**: Checks $Volume metafile
3. **$LogFile state**: Examines journal for uncommitted transactions

### Why Read-Write Mount is Dangerous

If ntfs-3g mounted a hibernated volume read-write:

1. Changes would be invisible to Windows after resume
2. Windows would overwrite those changes with cached data
3. $MFT inconsistencies would cause filesystem corruption
4. $LogFile replay could corrupt new data
5. $Bitmap mismatches could cause data loss

### Real-World Corruption Example

```
Scenario: File renamed on hibernated volume via Linux

1. Linux renames /docs/report.txt to /docs/final-report.txt
2. Windows resumes from hibernation
3. Windows cache still shows /docs/report.txt
4. Windows flushes cache on shutdown
5. File appears as report.txt, final-report.txt is lost
6. Next boot: potential NTFS_FILE_SYSTEM blue screen
```

### Mount Options

| Option | Effect | Risk Level |
|--------|--------|------------|
| `ro` | Read-only mount | Safe |
| `remove_hiberfile` | Deletes hiberfil.sys, allows r/w | HIGH - loses saved session |
| `force` (ntfs3 kernel driver) | Forces mount | VERY HIGH |

---

## 7. Power Loss During Hibernate Write

### The Hibernate Write Process

1. Kernel freezes processes and drivers
2. Memory contents compressed (XPRESS algorithm)
3. Compressed data written to hiberfil.sys
4. hiberfil.sys header updated with HIBR signature
5. $MFT entry for hiberfil.sys updated
6. System signals power-off to hardware

### Vulnerable Points for Power Loss

| Stage | Power Loss Consequence |
|-------|----------------------|
| During memory compression | Partial hiberfil.sys, corrupted header |
| During hiberfil.sys write | Incomplete file, potential $MFT corruption |
| During header update | Invalid signature, resume failure |
| Before $MFT sync | hiberfil.sys orphaned or size mismatch |
| During NTFS journal flush | $LogFile corruption |

### NVMe-Specific Vulnerabilities

Consumer NVMe SSDs lack enterprise power-loss protection (PLP). During unexpected power loss:

1. **DRAM cache loss**: Data in SSD's DRAM buffer never reaches NAND
2. **FTL corruption**: Flash Translation Layer mapping may be corrupted
3. **Firmware corruption**: Active firmware modules may be damaged
4. **Partial writes**: 4KB page written partially (torn write)

### SSD Power Loss Test Results

| SSD Model | Data Loss on Power Loss | Notes |
|-----------|------------------------|-------|
| SK Hynix Gold P31 | Yes | Lost data even after DRAM flush |
| Sabrent Rocket | Yes | Similar behavior |
| Samsung 970 Evo Plus | No | Better power loss handling |
| WD Red SN700 | No | Enterprise-class protection |

### Resulting Corruption States

Power loss during hibernate can leave:

1. **hiberfil.sys with invalid header**: Cannot resume, but file still marks volume
2. **Partial $MFT update**: File system sees inconsistent state
3. **$LogFile with incomplete transactions**: Redo/undo mismatch
4. **$Bitmap inconsistency**: Allocated clusters marked free or vice versa
5. **GPT header corruption**: If power lost during partition table update

---

## 8. Persistent Corruption Scenarios

### Scenario 1: Fast Startup + Dual Boot Modification

```
1. Windows shuts down with Fast Startup (hybrid hibernate)
2. User boots Linux, mounts NTFS with remove_hiberfile
3. Creates/modifies files on the volume
4. Boots back to Windows
5. Windows resumes with stale metadata cache
6. Corrupted filesystem, potential blue screen
7. Even after chkdsk, some corruption may persist
```

**Persistence mechanism**: Windows overwrites Linux changes with cached state

### Scenario 2: Power Loss During Hibernate + Failed Resume

```
1. User initiates hibernate
2. Power lost during hiberfil.sys write
3. hiberfil.sys is corrupted but dirty bit is set
4. Resume fails, Windows boots fresh but $LogFile is corrupted
5. chkdsk runs but cannot fully repair
6. Linux sees dirty volume, refuses mount
7. Partition deletion doesn't clear embedded metadata
```

**Persistence mechanism**: Corrupted $LogFile and $MFT prevent clean state

### Scenario 3: NVMe FTL Corruption

```
1. Power loss during hibernate write
2. NVMe DRAM cache lost, FTL partially corrupted
3. Some LBAs return stale/wrong data
4. hiberfil.sys appears intact but contains corrupted pages
5. $MFT reads return inconsistent data
6. Filesystem tools see different data on each read
7. Formatting fails because write verification fails
```

**Persistence mechanism**: Hardware-level corruption below filesystem

### Scenario 4: Repeated Hibernate/Force-Mount Cycles

```
1. Windows hibernates
2. Linux force-mounts and writes
3. Windows resumes, corrupts filesystem
4. User force-mounts in Linux again
5. Writes compound corruption
6. $MFT and $MFTMirr now both corrupted
7. Backup boot sector also overwritten
8. Recovery tools cannot find valid NTFS structures
```

**Persistence mechanism**: Destruction of all redundant metadata copies

### Scenario 5: GPT + NTFS Double Corruption

```
1. Power loss during hibernate affects both:
   - NTFS metadata in corrupted state
   - GPT backup header not updated
2. gdisk sees GPT header mismatch
3. Attempting partition deletion fails
4. Creating new partition leaves ghost NTFS signatures
5. New filesystem inherits corrupted structures
6. wipefs required before new filesystem usable
```

**Persistence mechanism**: GPT and NTFS metadata corruption interact

### Scenario 6: Firmware-Level SSD Brick

```
1. Power loss during hibernate write
2. SSD firmware caught mid-update of FTL
3. SSD reports wrong capacity (0 GB or 8 MB)
4. BIOS/UEFI may not detect drive
5. No partition table visible
6. Drive requires power cycling recovery or RMA
```

**Persistence mechanism**: SSD firmware corruption, not filesystem

---

## 9. Recovery and Mitigation

### Preventing the Problem

**Disable Fast Startup in Windows:**

```
Control Panel > Power Options > Choose what power buttons do
> Change settings that are currently unavailable
> Uncheck "Turn on fast startup"
```

Or via command line:
```cmd
powercfg /h off
```

**Ensure true shutdown:**
```cmd
shutdown /s /t 0        # Normal shutdown (still hybrid if Fast Startup on)
shutdown /p             # Force immediate power off (true shutdown)
shutdown /r /t 0        # Restart (always true cold boot)
```

### Recovery Procedures

**From Windows (if bootable):**
```cmd
chkdsk C: /r           # Full repair
chkdsk C: /f           # Fix errors only
sfc /scannow           # System file check
DISM /Online /Cleanup-Image /RestoreHealth
```

**From Linux:**
```bash
# Safe read-only mount
sudo mount -t ntfs-3g -o ro /dev/sdXn /mnt

# Clear hibernate file (DESTRUCTIVE - loses session)
sudo ntfs-3g -o remove_hiberfile /dev/sdXn /mnt

# Fix NTFS and clear journal
sudo ntfsfix /dev/sdXn

# Clear dirty bit and empty journal
sudo ntfsfix -d /dev/sdXn
```

### Nuclear Options for Persistent Corruption

If standard recovery fails:

```bash
# 1. Remove all filesystem signatures
sudo wipefs --all --force /dev/sdXn

# 2. If partition table also corrupted
sudo sgdisk --zap-all /dev/sdX

# 3. For complete drive reset
sudo dd if=/dev/zero of=/dev/sdX bs=1M count=100 status=progress
sudo dd if=/dev/zero of=/dev/sdX bs=1M seek=$(($(blockdev --getsize64 /dev/sdX)/1048576 - 100)) status=progress

# 4. For NVMe secure erase (if supported)
sudo nvme format /dev/nvmeXn1 --ses=1
```

### SSD Power Cycle Recovery

For firmware-corrupted SSDs:

1. Boot to BIOS/UEFI
2. Let system sit at BIOS screen for 30 minutes
3. Power off for 30 seconds
4. Repeat several times
5. Try PSU power cycling (flip switch or unplug)

This can sometimes recover SSDs with power-loss-corrupted firmware.

---

## 10. Sources

### Hibernation and Fast Startup
- [Manjaro Wiki - How to mount Windows NTFS filesystem due to hibernation](https://wiki.manjaro.org/index.php/How_to_mount_Windows_(NTFS)_filesystem_due_to_hibernation)
- [FOG Project Wiki - Windows Dirty Bit](https://wiki.fogproject.org/wiki/index.php?title=Windows_Dirty_Bit)
- [Windows Forum - Understanding Windows Fast Startup](https://windowsforum.com/threads/understanding-windows-fast-startup-pros-cons-and-when-to-disable.397729/)
- [Magnet Forensics - Hiberfil.sys Forensics](https://www.magnetforensics.com/blog/when-windows-takes-a-nap-and-leaves-you-evidence-inside-hiberfil-sys/)

### hiberfil.sys File Format
- [libhibr - Windows Hibernation File Format Documentation](https://github.com/libyal/libhibr/blob/main/documentation/Windows%20Hibernation%20File%20(hiberfil.sys)%20format.asciidoc)
- [Forensicxlab - Modern Windows Hibernation File Analysis](https://www.forensicxlab.com/blog/hibernation)
- [Andrea Fortuna - How to Read Windows Hibernation File](https://andreafortuna.org/2019/05/15/how-to-read-windows-hibernation-file-hiberfil-sys-to-extract-forensic-data/)

### NTFS Metadata and Journaling
- [DFIR Notes - Master File Table, $LogFile, and $UsnJrnl Forensics](https://mahmoud-shaker.gitbook.io/dfir-notes/master-file-table-mft-ntfs-usdlogfile-and-usdusnjrnl-forensics)
- [My DFIR Blog - Hibernation and NTFS](https://dfir.ru/2019/01/08/hibernation-and-ntfs/)
- [My DFIR Blog - How the $LogFile Works](https://dfir.ru/2019/02/16/how-the-logfile-works/)
- [Wikipedia - NTFS](https://en.wikipedia.org/wiki/NTFS)

### NTFS-3G and Linux Mount Issues
- [OSTechNix - Fix NTFS Partition Is In An Unsafe State Error](https://ostechnix.com/fix-ntfs-partition-is-in-an-unsafe-state-error-in-linux/)
- [Ubuntu Launchpad - Bug #1008117 (Nautilus hibernation mount)](https://bugs.launchpad.net/ubuntu/+source/ntfs-3g/+bug/1008117)
- [Red Hat Bugzilla - Unable to mount NTFS in rw mode](https://bugzilla.redhat.com/show_bug.cgi?id=1988745)

### Dirty Bit Mechanism
- [Microsoft Support - NTFS volume flagged as dirty after restart](https://support.microsoft.com/en-us/topic/an-ntfs-volume-is-flagged-as-dirty-after-each-restart-and-chkdsk-can-find-no-issues-in-windows-8-1-and-windows-server-2012-r2-eabdde85-331f-0cf5-fc90-2408967abdd4)
- [Top Password Blog - How to Clear or Set Dirty Bit](https://www.top-password.com/blog/how-to-manually-clear-or-set-dirty-bit-on-windows-volume/)
- [Microsoft Learn - chkdsk Command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk)

### NVMe Power Loss and Corruption
- [Stellar Info - Consumer NVMe SSDs Prone to Data Loss](https://www.stellarinfo.com/article/consumer-NVMe-SSDs-prone-to-data-loss-in-power-outage.php)
- [Tom's Hardware - NVMe SSDs Data Loss During Power Outage](https://www.tomshardware.com/news/sk-hynix-sabrent-rocket-ssds-data-loss)
- [ATP Inc - Power-Loss Protection for SSDs](https://www.atpinc.com/blog/why-do-ssds-need-power-loss-protection)
- [NVM Express - How SSDs Fail](https://nvmexpress.org/how-ssds-fail-nvme-ssd-management-error-reporting-and-logging-capabilities/)
- [Datarecovery.com - SSD Firmware Corruption](https://datarecovery.com/rd/ssd-firmware-corruption/)

### Partition Table Recovery
- [Rod Smith - Repairing GPT Disks](https://www.rodsbooks.com/gdisk/repairing.html)
- [Arch Wiki - GPT fdisk](https://wiki.archlinux.org/title/GPT_fdisk)
- [Man7.org - wipefs Manual](https://man7.org/linux/man-pages/man8/wipefs.8.html)

### Recovery Tools and Techniques
- [Linux Mint Forums - Cannot format partition](https://forums.linuxmint.com/viewtopic.php?t=403045)
- [Rescuezilla - Handling Hibernated NTFS Partitions](https://github.com/rescuezilla/rescuezilla/issues/254)
- [EaseUS - NVMe SSD Not Detected Recovery](https://www.easeus.com/data-recovery-solution/nvme-ssd-not-detected.html)
- [DFarq - Fix Dead SSD Power Cycle Method](https://dfarq.homeip.net/fix-dead-ssd/)

---

## Summary

Windows hibernation and Fast Startup can cause persistent NVMe corruption through multiple mechanisms:

1. **Metadata cache preservation** - Windows caches NTFS metadata and doesn't invalidate on resume
2. **Dirty bit persistence** - Fast Startup sets dirty bit on every "shutdown"
3. **$LogFile frozen state** - Uncommitted journal transactions cause inconsistency
4. **Power loss vulnerability** - Consumer NVMe SSDs lack power-loss protection
5. **Signature persistence** - NTFS metadata survives partition deletion
6. **FTL corruption** - SSD firmware corruption can make drive unresponsive

The combination of these factors can create scenarios where an NVMe drive resists normal reformatting attempts, requiring low-level tools like wipefs, sgdisk --zap-all, or secure erase to fully reset the drive state.
