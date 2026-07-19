# Upstream handoff: typed pod namespace sharing

## Proposed pull request

`feat(pod): add typed shared namespace policy`

This handoff covers the Apple-shaped code commit
[`89aa0eb6fb451875b73e4f4322a735b740e3cc2a`](https://github.com/stephenlclarke/containerization/commit/89aa0eb6fb451875b73e4f4322a735b740e3cc2a).

## Summary

`LinuxPod.Configuration` gains a typed `NamespaceSharing` `OptionSet` for the
two namespace types a pod can safely share between its workloads today:

* `.process` for a shared PID namespace.
* `.interprocessCommunication` for a shared IPC namespace.

The existing `shareProcessNamespace` property remains a source-compatible
computed bridge to `.process`. The implementation creates the internal pause
workload whenever either namespace is selected, then has each workload join the
pause workload's selected namespace through its OCI namespace path. The pause
workload keeps those namespaces alive while an individual workload restarts.

## Why this belongs in Containerization

This is a generic, opt-in pod capability. It does not accept Docker, Compose,
or host-platform vocabulary, and it does not change default isolation. The
configuration is deliberately extensible without growing more Boolean flags.

The change does not expose a Docker Compose `pid` or `ipc` adapter. A pod
currently has one VM-level network configuration, whereas Docker's
service/container namespace-sharing modes preserve per-container network
semantics. That higher-level mapping must wait for durable multi-workload
sandboxes with separate network attachments.

## Code map

| Path | Change |
| --- | --- |
| `Sources/Containerization/LinuxPod.swift` | Adds `Configuration.NamespaceSharing`, retains the compatibility property, and centralizes OCI namespace construction in `containerNamespaces`. |
| `Tests/ContainerizationTests/LinuxPodConfigurationTests.swift` | Covers defaults, independent policy selection, compatibility bridging, and every private/shared namespace-path branch. |
| `Sources/Integration/PodTests.swift` | Adds live Linux guest coverage proving two workloads observe the same IPC namespace. |
| `Sources/Integration/Suite.swift` | Registers the IPC integration test. |

## Validation performed locally on macOS

```console
swift format lint --strict --configuration .swift-format-nolint \
  Sources/Containerization/LinuxPod.swift \
  Sources/Integration/PodTests.swift \
  Sources/Integration/Suite.swift \
  Tests/ContainerizationTests/LinuxPodConfigurationTests.swift
swift test --filter LinuxPodConfigurationTests
make coverage
make init
./bin/containerization-integration --filter 'pod shared PID namespace' --max-concurrency 1
./bin/containerization-integration --filter 'pod shared IPC namespace' --max-concurrency 1
./bin/containerization-integration --filter 'pod useInit with shared PID namespace' --max-concurrency 1
```

All commands passed. The coverage report records all branches in
`containerNamespaces`, including no sharing, PID-only, IPC-only, and both
namespace selections. The three guest tests passed against the freshly built,
signed integration binary and initfs.

The repository-wide `make swift-fmt-check` currently reports a pre-existing
formatting issue in `vminitd/Sources/vmexec/RunCommand.swift`; this change's
four files pass strict formatting independently.

## Upstream review checklist

* Confirm the existing experimental `LinuxPod` surface remains the appropriate
  API location for shared PID and IPC namespaces.
* Confirm preserving `shareProcessNamespace` without a deprecation warning is
  preferable while clients migrate to the typed policy.
* Verify the new public API documentation aligns with the project's API
  stability policy.
* Run the standard macOS CI, including the integration suite on supported hosts.
* Do not add Docker Compose service/container namespace modes as part of this
  pull request; their network isolation contract is intentionally out of scope.
