# fix(runtime): allow file copies before workload start

## Summary

The four `LinuxContainer.copyIn` and `copyOut` overloads now use the existing VM in `.created` as well as `.started`. This allows file and archive transfers after VM creation and rootfs mounting without starting the initial workload process or changing the container lifecycle state.

## Why this belongs in Containerization

The guest copy protocol and mounted root filesystem are owned by the SDK's `LinuxContainer`. This change only adjusts which existing lifecycle states may access that VM; it adds no public API, guest protocol, or Docker-specific behavior.

`VminitdCore` links the `Containerization` target, so editing this source file does affect the guest build's source closure. The guest RPC schema and guest copy implementation are unchanged; the dependency graph is not claimed to be identical.

## Implementation

- `Sources/Containerization/LinuxContainer.swift` adds a narrow state
  accessor that returns the VM in `.created` or `.started`, preserves the
  original error from `.errored`, and rejects all other states with the
  existing invalid-state error. All four copy entry points use it without
  changing their transfer implementation.
- `Tests/ContainerizationTests/LinuxContainerTests.swift` covers all four
  overloads after `create()` and after workload start. The created-state
  fixture verifies the calls reach the VM boundary and do not create a
  workload process. Additional cases verify `.initialized`, `.stopped`, and
  `.paused` still reject copies.
- `README.md` documents the created-state copy contract. The issue handoff is `docs/ISSUE-stopped-container-copy.md`.

## Validation

The focused `make test` run with `SWIFT_CONFIGURATION_EXTRA="--enable-code-coverage --jobs 4 --filter LinuxContainerTests"` passed all 66 tests. The new lifecycle accessor has 15/15 executable lines covered; this is scoped coverage, not full SDK coverage. The first run exposed invalid archive handles and paused-state cleanup in the new fixtures. Those fixture errors were fixed, the original failure was retained, and the corrected run passed. Independent full source review found no actionable blocker. Evidence is retained under `candidate-container-stopped-copy/sdk-boundary/units-v1` and `units-v2`. Formatting, Markdown lint and diff checks pass. No baseline was rebuilt or rerun. Live candidate guest transfers and broader checkpoint gates remain pending.

## Compatibility and risks

Running-container copy behavior and transfer details are unchanged. Copy now also accepts `.created`, which represents a booted VM with a mounted rootfs but no started initial process. `.initialized`, `.stopped`, `.paused`, and `.errored` remain rejected. Unit fixtures stop at the recording VMM's guest-agent/listener boundary, so they do not prove successful bytes-on-disk transfer; the scheduled candidate workload must verify persistence, path handling, metadata, and that no workload starts.

## Upstream review checklist

- Confirm all four overloads accept `.created` without starting the initial process.
- Confirm existing `.started` copies remain unchanged.
- Confirm initialized, stopped, paused, and errored states remain rejected.
- Confirm candidate end-to-end copy and Docker parity evidence before publication.

Related issue handoff: `docs/ISSUE-stopped-container-copy.md`.
