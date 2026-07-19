# Issue handoff: vmexec cannot reenter its current user namespace

## Problem

`vmexec exec` opens a pidfd for a workload's init process and enters its
namespaces with a single `setns` call. The requested flags always included
`CLONE_NEWUSER`.

Linux rejects an attempt to reenter the caller's current user namespace with
`EINVAL`. This occurs when the target workload uses the same user namespace as
`vmexec`, even though the process must still join the target's cgroup, IPC,
PID, UTS, and mount namespaces before running the OCI process.

## Expected behavior

Execution against a workload sharing vmexec's user namespace succeeds while
preserving entry to every other requested namespace. A distinct target user
namespace remains part of the `setns` request, preserving its isolation.

## Scope and ownership

This belongs in `apple/containerization`: it is generic Linux namespace-entry
behavior in the guest execution utility. It adds no Docker or Compose
vocabulary, no host-platform policy, and no public configuration surface.

## Proposed fix

Compare `/proc/self/ns/user` with `/proc/<pid>/ns/user` by device and inode.
When they identify the same namespace, remove only `CLONE_NEWUSER` from the
pidfd `setns` flags. Keep all other requested flags unchanged.

The Apple-shaped source and unit-test commit is
[`fe896b6a5a57c1298a72e8efc96d314b8130083c`](https://github.com/stephenlclarke/containerization/commit/fe896b6a5a57c1298a72e8efc96d314b8130083c).

## Regression coverage

`Tests/VminitdCoreTests/LinuxNamespaceEntryTests.swift` covers both flag
plans: retaining `CLONE_NEWUSER` for a distinct target and removing only that
flag for the current namespace. Downstream guest integration also exercises
privileged, shared-user-namespace, and private-user-namespace execution paths
against a freshly built `vmexec` image on macOS.
