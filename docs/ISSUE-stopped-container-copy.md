# Issue handoff: copy files before a LinuxContainer workload starts

## Problem

All four `LinuxContainer.copyIn` and `copyOut` overloads require the internal `.started` state. The VM has already booted and its root filesystem is mounted in `.created`, so the guest agent can perform the same safe copy RPCs there without creating or starting the initial workload process. The current guard rejects that valid state and prevents callers from copying into or out of a created container.

## Expected behavior

File and archive copy operations work while the VM is in `.created` and continue to work in `.started`. They use the already-created VM and guest agent without changing container state or starting a process. `.initialized`, `.stopped`, `.paused`, and `.errored` retain their existing rejection behavior; callers must create the VM before copying and must not copy through a paused or discarded runtime.

## Scope and ownership

This belongs in `apple/containerization`: it is a generic `LinuxContainer` state gate around the existing guest copy protocol. No Docker or Compose policy, public API, guest RPC, or lifecycle transition is needed.

## Proposed fix

Replace the `.started`-only lookup at the four copy entry points with a small internal state accessor that returns the VM for `.created` or `.started`, rethrows `.errored`, and rejects all other states with the existing invalid-state error. Copy transfer code continues to use the same VM, locking, path handling, archive handling, and metadata behavior.

## Regression coverage

`LinuxContainerTests.copyOverloadsAreAvailableAfterCreateWithoutStartingWorkload` calls all four overloads against a created container backed by a recording VM. The recording guest agent and listener intentionally stop the transfer at the transport boundary; assertions distinguish those expected errors from the old state rejection and verify that no workload process was created. Companion tests exercise all four overloads in `.started` and assert `.initialized`, `.stopped`, and `.paused` remain rejected.

The focused test plan is:

```console
swift test --filter LinuxContainerTests
```

The focused `make test` run with `SWIFT_CONFIGURATION_EXTRA="--enable-code-coverage --jobs 4 --filter LinuxContainerTests"` passed all 66 tests. The new lifecycle accessor has 15/15 executable lines covered. The initial fixture failure and corrected run are retained under `candidate-container-stopped-copy/sdk-boundary/units-v1` and `units-v2`; no baseline was rebuilt or rerun. End-to-end guest transfer, Docker parity, and repository-wide checkpoint gates remain pending.
