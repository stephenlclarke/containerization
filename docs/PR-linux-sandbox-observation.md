# Upstream handoff: observable Linux sandbox lifecycle

## Proposed pull request

`feat(sandbox): expose workload observations`

This handoff covers signed local implementation commit
`8465b1fdafef6c88d44ae1daabdba31639f96894`. It is intentionally retained on
the local `upstream/engine-linux-sandbox` branch until the full parity
programme is ready for coordinated upstream publication.

## Summary

This change adds a public, side-effect-free snapshot to `LinuxPod` and its
production `LinuxSandbox` spelling. The snapshot reports:

- the immutable sandbox ID;
- whether the sandbox is absent, running, or requires recovery; and
- each registered workload's deterministic ID, lifecycle state, and active
  init process ID when available.

Internal errored phases map to an explicit `recoveryRequired` state. The
public model deliberately exposes no virtual-machine object, guest-agent
handle, mutable container registration, or raw error. Its value types are
`Codable`, `Equatable`, and `Sendable`, allowing a runtime helper to return an
exact observation across XPC and allowing the Engine authority to reconcile
a request whose response was lost.

Workloads are sorted by immutable ID before return. The ordering is therefore
stable despite dictionary insertion order and safe for durable comparisons.

## Compatibility

- Existing lifecycle methods and compatibility defaults are unchanged.
- Existing `LinuxPod` callers require no changes.
- `snapshot()` takes the existing state lock and performs no VM, guest, file,
  network, or process operation.
- The API reports the current in-memory authority only; it does not claim
  durable recovery after the helper process itself exits.

## Code map

- `Sources/Containerization/LinuxPod.swift` adds the public snapshot state
  and value types, the internal lifecycle mapping, and `snapshot()`.
- `Tests/ContainerizationTests/LinuxPodConfigurationTests.swift` covers an
  absent sandbox, deterministic workload ordering, registered state, absent
  process IDs, Codable round-trip, and removal from subsequent observations.

## Local macOS validation

```console
swift test --filter LinuxPodConfigurationTests
make check
make test
```

All commands passed on the development Apple silicon Mac. The focused suite
passed seven tests. The single full repository gate passed 710 tests in 89
suites. Format, licence, and diff checks also passed.

## Follow-on work deliberately excluded

- XPC routes and a client adapter implementing the Engine runtime boundary.
- Durable request and effect receipts in the Engine authority.
- Helper-process restart and sandbox reconstruction.
- Docker REST API, API socket, Compose policy, and migration gating.

Those layers can consume this observation without reaching into
Containerization internals.

## Upstream review checklist

- Confirm that `recoveryRequired` is the appropriate stable public spelling
  for an internal errored phase.
- Confirm the init process ID is sufficient for higher-level namespace donor
  and reconciliation diagnostics.
- Exercise snapshots across create, start, pause, resume, stop, and recovery
  transitions in the virtualization-capable integration lane.
- Review the API alongside the production workload controls described in
  `PR-linux-sandbox-workload-controls.md`.
