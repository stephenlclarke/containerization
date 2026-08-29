# Release gate rejects valid VZ pod lifecycle operations

## I have done the following

- [x] I have searched the existing issues.
- [x] I reproduced the issue using `main` at `59ce8dafa11841f47287e3c29d1e8fe6d976236c`.

## Steps to reproduce

Build the host integration executable and matching vminit artifacts from the
same source revision. Run the `pod stop container idempotency`,
`pod NBD volume persistence`, and `pod hotplug block rootfs` integration
contracts on the Virtualization.framework backend.

## Current behavior

An already-exited managed process has its PID cleared before a repeated stop.
`ManagedProcess.kill` checks the PID before the exit status, so idempotent stop
and NBD cleanup fail with `process PID is required`. Checking only those state
fields would still leave a race between `wait4` reaping and exit-state
publication, during which a repeated signal could observe `ESRCH` or a reused
PID.

Runtime VZ rootfs shares are mounted at `/run/runtime-virtiofs-*`, while the
guest loop-device validator accepts only `/run/virtiofs/*`. A valid hotplugged
ext4 root therefore fails with
`loop backing file must be a normalized path below /run/virtiofs`. Merely
allowing that prefix would also trust unreserved look-alike directories and
intermediate symlink escapes.

The 0.14.0 release gate consequently completed 175 of 180 Containerization
integration contracts, skipped two, and failed these three.

## Expected behavior

- Managed process signaling uses a race-free process handle, and killing an
  already-exited process is an idempotent no-op.
- Loop-backed rootfs paths are accepted only when normalized, below either the
  stable unified virtiofs root or one of the 64 reserved runtime virtiofs
  device roots, and backed by the matching active virtiofs mount.
- Descriptor-relative resolution rejects traversal, intermediate symlinks,
  mount crossings, prefix siblings, and unrelated guest paths.
- All three focused integration contracts pass against one exact host/guest
  source revision.

## Environment

- OS: macOS 26, Apple silicon
- Xcode: 26
- Swift: Apple Swift 6.3

## Relevant log output

```text
process PID is required
invalidArgument: "loop backing file must be a normalized path below /run/virtiofs"
```

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
