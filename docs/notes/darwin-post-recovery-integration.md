# Darwin Post-Recovery Integration Notes

**Date**: 2026-04-12

## Why This Note Exists

The original recovery work in this repo was about a controller/bridge/media failure class: a drive behind an ASM2362 bridge that had fallen into a `Medium not present` / zero-capacity protected state and was later recovered via XRAM command injection.

This note records a separate, later problem that showed up after recovery:

- the recovered drive and enclosure are healthy on Linux
- the same enclosure is usable as an APFS target on macOS
- but some macOS execution contexts still cannot access that mounted APFS volume for automation work

That distinction matters. “Recovered drive” is not the same as “operationally usable target on every host and execution model.”

## 2026-04-12 Cross-Platform Findings

### Linux on `yoga`

The recovered enclosure path behaves normally:

- ASM2362 bridge enumerates cleanly as `174c:2362`
- `asm2362-tool probe` reports `READY` with normal capacity
- `blkid` identifies the volume normally
- `fsck.exfat -n` reported a clean filesystem before macOS reformat
- read-only mount succeeded
- small read/write/delete smoke test succeeded

Important nuance:

- `asm2362-tool identify` and `smart` returned `Invalid command`
- `smartctl -d sntasmedia` returned unsupported opcode

That looks like a passthrough limitation on this bridge path, not a return to the earlier protected-state failure.

### macOS on `petting-zoo-mini`

The media and mount path were eventually normalized successfully:

- the external device was reformatted to APFS as `TinylandSSD`
- the volume auto-mounted back to `/Volumes/TinylandSSD` across reboot
- `diskutil enableOwnership` succeeded

But the real automation contexts still failed:

- the first remote context probe showed both `sshd` and one-shot user `launchd` failing SSD writes with `Operation not permitted`
- after `tinyland-cleanup` was moved to a stable launchd path, the failure split became sharper:
  - interactive shell: list/read works, but `xattr` and write/delete time out
  - launchd user agent: list/read works, but `xattr` and write/delete still fail fast with `Operation not permitted`
- the stable cleanup binary is now at `/Users/jsullivan2/.local/bin/tinyland-cleanup` with identifier `dev.tinyland.tinyland-cleanup`
- the stable cleanup binary is now Developer ID signed (`TeamIdentifier=QP994XQKNH`)
- Developer ID signing did not change the SSD access outcome, so the remaining issue is Darwin grant state rather than signing mechanics
- the first direct signed `tinyland-cleanup` probe also exposed a separate Darwin packaging trap:
  - a Developer ID-signed Nix-linked Go build failed at launch because dyld rejected a differently-signed `/nix/store` `libresolv` dependency
  - rebuilding the standalone binary with `CGO_ENABLED=0` removed the `/nix/store` dylib dependency and avoided that launch failure
- a stable signed direct-syscall helper at `~/.local/bin/tinyland-volume-access-probe` sharpened the picture further:
  - `listxattr` succeeds
  - direct directory open and create still time out
  - `sample` on the hanging helper child shows it blocked in `open$NOCANCEL` from `__opendir2`
- the real `tinyland-cleanup` consumer now reproduces the same lower-level stall directly:
  - interactive and one-shot launchd probe modes both time out on directory open and write/delete while `xattr` succeeds
  - `sample` on the real consumer child shows it blocked in `open` from the Go runtime syscall path
- a one-shot local root `LaunchDaemon` on macOS reproduces the same timeout shape and attributes the policy query directly to the final consumer binary
- that rules out remote-session wrapper noise as the main explanation
- an internal APFS control path on the same host passes cleanly in the same consumer contexts
- that means the remaining Darwin issue is specific to the external path rather than the recovered media being generically unusable on macOS
- platform binaries in a local root LaunchDaemon also fail immediately on the external path while passing on the internal control path
- that suggests the external path is provoking both fast system-policy denials for platform binaries and a separate hanging `open` path for the non-platform cleanup consumer
- `crush-dots` now carries a bounded storage-log helper and a local-console runbook for this phase, which is the right place to keep pushing the Darwin-side investigation
- `crush-dots` now also carries a PPPC profile scaffold for the stable `tinyland-cleanup` binary:
  - live identity export
  - a renderer for `com.apple.TCC.configuration-profile-policy`
  - a narrow-first `SystemPolicyRemovableVolumes` example profile
  - this moves the next Darwin tranche onto the supported managed-profile path instead of more shell-only grant attempts

That means the remaining problem is no longer bridge/media recovery. It is a Darwin execution-context access-policy problem.

## Interpretation

This should not be misclassified as a new storage failure.

A later note covers a separate transport-debug lane where the same recovered
enclosure negotiates only `480Mbps` despite still advertising USB 3.x
capability. See
[usb-link-negotiation-field-report-2026-04.md](usb-link-negotiation-field-report-2026-04.md).

What it is:

- recovered media
- healthy Linux read/write path
- healthy APFS mount and reboot persistence on macOS
- unhealthy Darwin automation access from specific contexts

What it is not:

- the original `Medium not present` / zero-capacity controller-protection case
- proof that the bridge or NVMe media is still broken

## Implications For This Repo

`hiberpower-ntfs` should explicitly acknowledge a post-recovery class of work:

- distinguishing bridge passthrough limits from actual dead media
- distinguishing Linux usability from macOS automation usability
- treating Darwin access-policy validation as a separate integration phase after media recovery
- recognizing that stable executable path is necessary but may still leave both a signing/grant-identity problem and a Darwin packaging/linkage problem on macOS

This repo does not need to own the Darwin automation rollout itself, but it should document the boundary clearly enough that future investigation does not regress into “the drive must be broken again.”

## Follow-On Work

- keep Linux-side `asm2362-tool probe` as the quick discriminator between recovered media and the old protected-state failure
- document the macOS side as an access-policy / consumer-context problem
- coordinate with `crush-dots` for the actual launchd / codesign / stable-path rollout work on `petting-zoo-mini`
