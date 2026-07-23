# Upstream handoff: stop a LinuxContainer VM after start failure

## Proposed pull request

`fix(runtime): stop VM when create startup fails`

This handoff covers the Apple-shaped code commit
[`766318bb7d33494838c1896adde1490d8e34c0a4`](https://github.com/stephenlclarke/containerization/commit/766318bb7d33494838c1896adde1490d8e34c0a4).

## Summary

`LinuxContainer.create()` now starts its VM inside the existing
cleanup-protected setup block. If startup throws, creation attempts to stop
the VM and rethrows the original failure.

## Why this belongs in Containerization

The correction is generic VM lifecycle ownership. `LinuxContainer` creates the
VM, so it must release a partially initialized instance when startup fails.
The patch contains no Compose behavior, Docker compatibility vocabulary, new
public API, or platform-specific branch.

## Implementation

- `Sources/Containerization/LinuxContainer.swift` moves `vm.start()` inside
  the existing best-effort cleanup boundary.
- `Tests/ContainerizationTests/LinuxContainerTests.swift` injects a start
  failure and verifies one stop, original-error preservation, and terminal
  container state.

The implementation deliberately reuses the established `try? await vm.stop()`
behavior. A cleanup error cannot replace the more useful startup failure.

## Validation on macOS

```console
swift test --filter LinuxContainerTests
make check
make test
make coverage
```

All commands pass on Apple silicon macOS. The focused suite passed 44 tests;
the full test and coverage targets each passed 647 tests in 85 suites.

## Compatibility and risks

Successful starts are unchanged. Failures during later agent or relay setup
already used this cleanup path and remain unchanged. The only new behavior is
a best-effort stop when `start()` itself throws. Container state remains
terminal after the failed creation attempt.

## Upstream review checklist

- Verify the VM is stopped when `start()` throws.
- Verify the original start error is rethrown even if cleanup fails.
- Verify successful creation remains unchanged.
- Verify a failed container does not retry VM startup.
- Keep Docker and Compose policy out of this lifecycle fix.

Related issue handoff:
`docs/ISSUE-linux-container-start-cleanup.md`.
