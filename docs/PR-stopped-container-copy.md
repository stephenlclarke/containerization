# fix(runtime): allow file copies before workload start

## Summary

The four `LinuxContainer.copyIn` and `copyOut` overloads now use the existing VM in `.created` as well as `.started`. This allows file and archive transfers after VM creation and rootfs mounting without starting the initial workload process or changing the container lifecycle state. File copy-out applies guest permission bits even when ownership preservation is disabled. Guest copy-in applies the requested mode after writing, independently of ownership preservation, so umask does not change the requested permissions.

## Why this belongs in Containerization

The guest copy protocol and mounted root filesystem are owned by the SDK's `LinuxContainer`. The SDK `copyIn(mode:)` signature and default remain unchanged (`0644`); callers that want source-mode preservation pass the source mode explicitly. Explicit mode `0000` is encoded as regular-file type bits, so the guest can mask it to zero permissions without changing the raw RPC's legacy zero-means-`0644` behavior. No guest RPC schema or lifecycle transition is added.

`VminitdCore` links the `Containerization` target, so editing the shared SDK source affects the guest build's source closure. This patch also changes guest copy-in mode application, so a Linux guest binary rebuild is required for end-to-end validation.

## Implementation

- `Sources/Containerization/LinuxContainer.swift` adds a narrow state accessor that returns the VM in `.created` or `.started`, preserves the original error from `.errored`, and rejects all other states with the existing invalid-state error. All four copy entry points use it without changing their transfer implementation.
- `Tests/ContainerizationTests/LinuxContainerTests.swift` covers all four overloads after `create()` and after workload start. The created-state fixture verifies the calls reach the VM boundary and do not create a workload process. Additional cases verify `.initialized`, `.stopped`, and `.paused` still reject copies.
- `README.md` documents the created-state copy contract. The issue handoff is `docs/ISSUE-stopped-container-copy.md`.
- File copy-out permissions are preserved without enabling ownership preservation; guest copy-in applies requested permission bits after writing. The unit regressions use real file descriptors and verify copy-out modes `0000`, `0640`, `0664`, and `0755`, plus copy-in modes `0000`, `0640`, `0664`, and `0755`. They check unchanged ownership when preservation is disabled and the guest's legacy RPC zero default.

## Validation

The final focused host `make test` run passed all 68 `LinuxContainerTests`. The Linux guest mode selection passed all four `CopyFileModeTests`, covering legacy/default and explicit-zero mode mapping, real file descriptors, unchanged ownership, and an invalid-descriptor error. Instrumented evidence covers the lifecycle gate (15/15 executable lines), the host mode encoder (3/3), and both guest mode helpers (11/11). Host copy-out metadata handling covered 4/14 lines; the remaining lines are existing ownership/error logging branches, so this is not a whole-transfer or whole-SDK coverage claim. Evidence is retained under `candidate-container-stopped-copy/sdk-boundary/units-v4` and `linux-modes-v2`. The initial Linux selection matched zero cases and failed closed; that harness failure remains in `linux-modes-v1`. No baseline was rebuilt or rerun. A rebuilt guest and end-to-end candidate/Docker proof remain pending.

## Compatibility and risks

Running-container lifecycle mechanics are unchanged, while file copy mode handling is corrected. Copy now also accepts `.created`, a booted VM with a mounted rootfs but no started initial process. `.initialized`, `.stopped`, `.paused`, and `.errored` remain rejected. The lifecycle fixtures stop at the recording VMM's guest-agent/listener boundary, so they do not prove successful bytes-on-disk transfer. The mode tests exercise real host and guest file descriptors. Candidate workloads must still verify persistence, path handling, metadata, and that no workload starts.

## Upstream review checklist

- Confirm all four overloads accept `.created` without starting the initial process.
- Confirm existing `.started` lifecycle and transfer mechanics remain unchanged while modes are corrected.
- Confirm initialized, stopped, paused, and errored states remain rejected.
- Confirm candidate end-to-end copy and Docker parity evidence before publication.

Related issue handoff: `docs/ISSUE-stopped-container-copy.md`.
