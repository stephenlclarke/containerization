# Upstream handoff: avoid reentering the current user namespace in vmexec

## Proposed pull request

`fix(vmexec): avoid reentering the current user namespace`

This handoff covers the Apple-shaped code commit
[`fe896b6a5a57c1298a72e8efc96d314b8130083c`](https://github.com/stephenlclarke/containerization/commit/fe896b6a5a57c1298a72e8efc96d314b8130083c).

## Summary

`vmexec exec` now omits `CLONE_NEWUSER` only when its target process already
uses vmexec's user namespace. Linux rejects reentry to the current user
namespace with `EINVAL`; the remaining namespace joins are still required and
remain unchanged.

## Why this belongs in Containerization

The correction is a generic Linux guest namespace-entry rule. It has no
Docker or Compose vocabulary, no host-specific branch, no new public API, and
no effect on default isolation. A distinct target user namespace is still
entered exactly as before.

## Implementation

| Path | Change |
| --- | --- |
| `vminitd/Sources/vmexec/ExecCommand.swift` | Compares the target and current user namespace identities before the pidfd `setns` call. |
| `vminitd/Sources/VminitdCore/LinuxNamespaceEntry.swift` | Provides the small, platform-neutral flag-planning boundary. |
| `Tests/VminitdCoreTests/LinuxNamespaceEntryTests.swift` | Covers same-namespace and distinct-namespace flag plans, including preservation of every non-user flag. |

Namespace identity is the `/proc` namespace object's device/inode pair. If the
objects match, the code clears only `CLONE_NEWUSER`; cgroup, IPC, PID, UTS, and
mount namespace flags remain in the same call. If they differ, the original
complete flag set is retained.

## Validation on macOS

```console
make swift-fmt-check
swift test --filter LinuxNamespaceEntryTests \
  --disable-automatic-resolution -Xswiftc -warnings-as-errors
make -C vminitd
```

All commands pass. The focused tests exercise both planner branches and the
rebuilt output is a static ARM64 Linux `vmexec` executable.

Downstream macOS guest integration, using an image rebuilt from this checkout,
also passes these independently executed regressions:

```console
ComposeRuntimeTests.ComposeRuntimeSmokeTests/
runtimePrivilegedServiceRestoresGuestReadonlyPaths
ComposeRuntimeTests.ComposeRuntimeSmokeTests/
runtimeHostUserNamespaceRetainsGuestIdentityMapping
ComposeRuntimeTests.ComposeRuntimeSmokeTests/
runtimePrivateUserNamespaceHasIdentityMappedGuestNamespace
```

The downstream layer owns its higher-level configuration vocabulary; it is not
introduced in this upstream patch.

## Compatibility and risks

Workloads with a distinct user namespace keep the existing behavior. Workloads
sharing the current namespace no longer request the Linux-invalid reentry, but
continue to enter every other requested target namespace. Namespace lookup
failures retain normal `vmexec` errno reporting rather than silently weakening
isolation.

## Upstream review checklist

* Confirm device/inode identity is the preferred namespace comparison in the
  guest environment.
* Verify a same-user-namespace target retains all non-user namespace entries.
* Verify a distinct user-namespace target retains `CLONE_NEWUSER`.
* Run the standard macOS source and Linux guest integration checks.
* Keep higher-level orchestration policy and Docker/Compose compatibility out
  of scope.

Related issue handoff:
`docs/ISSUE-vmexec-current-user-namespace.md`.
