# Issue handoff: LinuxContainer leaks a VM after start failure

## Problem

`LinuxContainer.create()` creates a virtual machine and then starts it before
entering the cleanup-protected setup block. If `VirtualMachineInstance.start()`
throws after allocating runtime resources, the error bypasses the existing
best-effort `stop()` path. A Virtualization.framework VM or its XPC helper can
therefore outlive a failed container creation attempt.

This reproduces the lifecycle gap reported in Apple Containerization issue
[#804](https://github.com/apple/containerization/issues/804).

## Expected behavior

A failed VM start remains the error returned by `create()`, while the same
best-effort cleanup used for later setup failures also attempts to stop the
partially started VM. The failed container remains terminal and a second
`create()` call does not retry the start.

## Scope and ownership

This belongs in `apple/containerization`: it is generic virtual-machine
lifecycle cleanup in `LinuxContainer`. It adds no Docker or Compose vocabulary,
no new public API, and no host-platform policy.

## Proposed fix

Move `vm.start()` into the existing `do` block. Its `catch` already calls
`try? await vm.stop()` before rethrowing the original error, so this one-line
boundary change extends the established cleanup behavior without masking the
start failure.

The Apple-shaped source and unit-test commit is
[`766318bb7d33494838c1896adde1490d8e34c0a4`](https://github.com/stephenlclarke/containerization/commit/766318bb7d33494838c1896adde1490d8e34c0a4).

## Regression coverage

`LinuxContainerTests.createStopsVirtualMachineAfterStartFailure` injects a
recording VM whose `start()` throws. It verifies that start and stop are each
called once, the original error is preserved, the VM becomes stopped, and the
failed container cannot retry creation.

The focused suite and both full test executions passed on Apple silicon macOS:

```console
swift test --filter LinuxContainerTests
make test
make coverage
```

The full test and coverage targets each passed 647 tests in 85 suites.
