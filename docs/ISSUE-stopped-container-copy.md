# Issue handoff: copy files before a LinuxContainer workload starts

## Problem

All four `LinuxContainer.copyIn` and `copyOut` overloads require the internal `.started` state. The VM has already booted and its root filesystem is mounted in `.created`, so the guest agent can perform the same safe copy RPCs there without creating or starting the initial workload process. The current guard rejects that valid state and prevents callers from copying into or out of a created container.

## Expected behavior

File and archive copies work while the VM is in `.created` and continue to work in `.started`. They use the existing VM and guest agent without changing container state or starting a process. `.initialized`, `.stopped`, `.paused`, and `.errored` retain their existing rejection behavior; callers must create the VM before copying and must not copy through a paused or discarded runtime.

File `copyOut` applies guest permission bits on the host even when ownership preservation is disabled, including mode `0000`. File `copyIn` honors its explicit `mode` argument (default `0644`), including `0000`. The SDK encodes explicit zero as a regular-file mode; a raw guest RPC value of zero retains its legacy `0644` default. Clients that need host-source mode preservation pass those bits explicitly, while ownership preservation remains opt-in.

## Scope and ownership

This belongs in `apple/containerization`: the state gate and metadata behavior are generic `LinuxContainer` and guest-copy concerns. No guest RPC schema or lifecycle transition is needed. CLI policy that maps host source permissions to the SDK's explicit `copyIn(mode:)` argument belongs at the CLI boundary.

## Proposed fix

Replace the `.started`-only lookup at the four copy entry points with a small internal state accessor that returns the VM for `.created` or `.started`, rethrows `.errored`, and rejects all other states with the existing invalid-state error. Copy transfer code continues to use the same VM, locking, path handling, and archive handling. File copies preserve permission bits independently of whether ownership preservation is requested.

## Regression coverage

`LinuxContainerTests.copyOverloadsAreAvailableAfterCreateWithoutStartingWorkload` calls all four overloads against a created container backed by a recording VM. The recording guest agent and listener stop the transfer at the transport boundary; assertions distinguish those expected errors from the old state rejection and verify that no workload process was created. Companion tests exercise all four overloads in `.started` and assert `.initialized`, `.stopped`, and `.paused` remain rejected.

The mode regressions exercise real file descriptors. They verify that guest copy-out applies `0000`, `0640`, `0664`, and `0755` without changing owner or group when ownership preservation is disabled, and that guest copy-in applies requested modes after writing. The SDK and guest resolver tests also cover explicit `0000` while preserving the raw RPC's legacy zero sentinel.

The focused test plan is:

```console
swift test --filter LinuxContainerTests
```

The final focused host `make test` run passed all 68 `LinuxContainerTests`. The Linux guest mode selection passed all four `CopyFileModeTests`, covering legacy/default and explicit-zero mode mapping, real file descriptors, unchanged ownership, and an invalid-descriptor error. Instrumented evidence covers the lifecycle gate (15/15 executable lines), the host mode encoder (3/3), and both guest mode helpers (11/11). Host copy-out metadata handling covered 4/14 lines; the remaining lines are existing ownership/error logging branches, so this is not a whole-transfer or whole-SDK coverage claim. Evidence is retained under `candidate-container-stopped-copy/sdk-boundary/units-v4` and `linux-modes-v2`. The initial Linux selection matched zero cases and failed closed; that harness failure remains in `linux-modes-v1`. No baseline was rebuilt or rerun. A rebuilt guest and end-to-end candidate/Docker proof remain pending.
