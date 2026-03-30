# macOS IOKit SCSI Passthrough — Implementation Notes

## Overview

macOS does not expose Linux-style SG_IO for SCSI passthrough. Instead, the IOKit framework provides `SCSITaskUserClient` for sending arbitrary SCSI CDBs to devices. This document captures the research and design decisions for adding macOS support to hiberpower.

## Apple's Restriction (QA1179)

> "Mac OS X by design does not support sending SCSI or ATA commands from an application to most storage devices unless the developer provides a custom kernel driver."

**Workaround**: Force-unmount all volumes, then claim exclusive access via SCSITaskUserClient. This is the pattern used by LTFS tape drivers and has been proven to work for USB mass storage.

## IOKit Architecture

```
Userspace (hiberpower)
    │
    ▼
SCSITaskDeviceInterface (IOKit plugin)
    │
    ▼
IOSCSIPeripheralDeviceType00 (kernel driver)
    │
    ▼
IOUSBMassStorageDriver
    │
    ▼
ASM236X USB-NVMe Bridge (hardware)
    │
    ▼
NVMe SSD
```

## Implementation Pattern

### 1. Device Discovery

```c
// Find the IOService for a BSD disk name (e.g., "disk4")
CFMutableDictionaryRef match = IOBSDNameMatching(kIOMainPortDefault, 0, "disk4");
io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);

// Walk up the IORegistry to find IOSCSIPeripheralDeviceType00
io_service_t scsi_device = find_parent_of_class(service, "IOSCSIPeripheralDeviceType00");
```

### 2. Exclusive Access

```c
IOCFPlugInInterface **plugin = NULL;
SInt32 score;
IOCreatePlugInInterfaceForService(scsi_device,
    kIOSCSITaskDeviceUserClientTypeID,
    kIOCFPlugInInterfaceID,
    &plugin, &score);

SCSITaskDeviceInterface **device = NULL;
(*plugin)->QueryInterface(plugin,
    CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
    (LPVOID *)&device);

// Must unmount all volumes first!
IOReturn result = (*device)->ObtainExclusiveAccess(device);
```

### 3. Command Execution

```c
SCSITaskInterface **task = (*device)->CreateSCSITask(device);

// Set CDB (works for vendor commands 0xE4, 0xE5, 0xE6, 0xE8)
UInt8 cdb[16] = { 0xE6, ... };
(*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_16Byte);

// Set data transfer
IOVirtualRange range = { .address = (IOVirtualAddress)buffer, .length = size };
(*task)->SetScatterGatherEntries(task, &range, 1, size, kSCSIDataTransfer_FromTargetToInitiator);

(*task)->SetTimeoutDuration(task, 30000);

// Execute
SCSI_Sense_Data sense;
SCSITaskStatus status;
UInt64 transferred;
(*task)->ExecuteTaskSync(task, &sense, &status, &transferred);
```

### 4. Cleanup

```c
(*task)->Release(task);
(*device)->ReleaseExclusiveAccess(device);
(*device)->Release(device);
(*plugin)->Release(plugin);
```

## Zig FFI Strategy

```zig
const c = @cImport({
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("IOKit/IOCFPlugIn.h");
    @cInclude("IOKit/scsi/SCSITaskLib.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});
```

In `build.zig`:
```zig
if (target.os_tag == .macos) {
    exe.linkFramework("IOKit");
    exe.linkFramework("CoreFoundation");
}
```

## Error Mapping

| IOKit Return Code | → SgError |
|-------------------|-----------|
| `kIOReturnSuccess` | (no error) |
| `kIOReturnNotPermitted` | `PermissionDenied` |
| `kIOReturnTimeout` | `Timeout` |
| `kIOReturnNoDevice` | `DeviceNotFound` |
| `kIOReturnExclusiveAccess` | `DeviceOpenFailed` (already locked) |
| SCSI CHECK CONDITION | `CheckCondition` (reuse sense.zig) |

## Permissions

- **Requires sudo/root** for `ObtainExclusiveAccess`
- **Device must be unmounted** before exclusive access
- No SIP restrictions on IOKit SCSI access
- No entitlements required for command-line tools

## References

- [LTFS macOS IOKit](https://github.com/amiaopensource/ltfs/blob/master/ltfs/src/tape_drivers/osx/iokit/iokit_scsi_base.c) — production implementation
- [SCSITaskLib.h](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.2.8.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/scsi-commands/SCSITaskLib.h)
- [SCSITaskUserClient source](https://github.com/aosm/IOSCSIArchitectureModelFamily/blob/master/UserClient/SCSITaskUserClient.cpp)
- [Apple Mass Storage Driver Guide](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/MassStorage/06_LUD_Example/MS_LUD_Example.html)
- [smartmontools os_darwin.cpp](https://www.smartmontools.org/) — IOKit device discovery
- [Apple QA1179](https://developer.apple.com/library/archive/qa/qa1179/_index.html) — SCSI passthrough restrictions
