# Linux sandbox lifecycle has no public observation API

## Problem

`LinuxPod`, also exposed as `LinuxSandbox`, owns the authoritative VM and
workload lifecycle state but does not expose it. A higher-level Engine runtime
can request a workload operation, but after a lost reply it cannot determine
whether the operation was applied, was absent, or left the sandbox in a state
that requires recovery.

Inferring state from `listContainers()` is insufficient. Presence does not
distinguish a registered workload from one whose resources are created, whose
process is running or paused, or whose previous operation failed. Exposing the
underlying VM, guest-agent handle, or raw error would leak implementation
details and invite callers to bypass the lifecycle authority.

## Expected behaviour

- A side-effect-free operation returns the sandbox identity and lifecycle
  state.
- Every registered workload is reported with its immutable ID, lifecycle
  state, and active init process ID when present.
- Workloads are ordered deterministically so observations can be persisted,
  hashed, and compared across process restarts.
- Error states are reported as requiring recovery without exposing raw
  implementation errors or mutable runtime objects.
- The observation is `Codable`, `Equatable`, and `Sendable` so it can cross a
  service boundary and participate in lost-response reconciliation.
- Existing `LinuxPod` and `LinuxSandbox` callers remain source compatible.

## Reproduction outline

1. Create a `LinuxSandbox`, register a workload, and submit a start request
   through a service boundary.
2. Lose the service reply after the runtime may have applied the request.
3. Attempt to determine whether retrying the request is safe.
4. Observe that the public API can list an ID but cannot distinguish
   registered, created, running, paused, stopped, or errored state.

## Scope boundary

This issue covers typed, side-effect-free observation of the in-memory
Containerization authority. Durable request/receipt storage, generation
fencing, retry policy, and rollback remain responsibilities of the
higher-level Engine authority. Restoring a sandbox after its owning helper
process exits is also separate recovery work.
