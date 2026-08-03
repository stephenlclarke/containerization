# Upstream handoff: production Linux sandbox workload controls

## Proposed pull request

`feat(sandbox): add production workload controls`

This handoff covers the Apple-shaped code commit
[`88fc904eda6223f061f17c3195c872f0232666d0`](https://github.com/stephenlclarke/containerization/commit/88fc904eda6223f061f17c3195c872f0232666d0)
and the independent lifecycle follow-up
[`1105266d0992c47d056a72a6d418cd13f11056af`](https://github.com/stephenlclarke/containerization/commit/1105266d0992c47d056a72a6d418cd13f11056af).

## Summary

This change makes the multi-workload Linux VM usable as a production
workload substrate without removing the source-compatible `LinuxPod` name.
It adds `LinuxSandbox` as the production spelling and expands each workload
with the resource, device, annotation, cgroup-parent, OCI-runtime, and
user-namespace controls already available to `LinuxContainer`.

Every supported namespace now has a typed per-workload selection:

- create a private namespace;
- join the sandbox VM's initial namespace; or
- join the namespace of a named active workload.

Donor IDs resolve to the active init PID immediately before process creation.
Unknown, stopped, and self donors fail before the process starts. Network
donors use Linux's `/proc/<pid>/ns/net` path while retaining OCI's `network`
namespace type.

The stop path now performs guest socket-relay shutdown, rootfs unmount, sync,
and device release for both created and running workloads. A separate
`removeContainer` operation removes a stopped registration without affecting
the VM or sibling workloads. Process identifier and process-table queries are
available per active workload.

`pauseContainer` and `resumeContainer` now freeze only the selected
workload's cgroup. The guest waits for `cgroup.events` to confirm the freezer
transition before acknowledging it, and the host records the paused state
only after that acknowledgement. Stop and whole-sandbox shutdown thaw a
paused workload before terminating it; neither path needs to pause or resume
the VM.

## Compatibility

- Existing `LinuxPod` source continues to compile.
- Existing pod-wide PID/IPC sharing remains the default compatibility policy
  when no per-workload selection is supplied.
- The legacy VM-host network remains the compatibility default until a caller
  supplies an explicit per-workload network namespace and endpoint plan.
- `LinuxContainer` now shares its guest-device resolution implementation with
  the sandbox path; its public behaviour is unchanged.
- Existing `VirtualMachineAgent` conformers remain source compatible through
  default unsupported implementations for the new workload pause operations.

## Code map

- `Sources/Containerization/LinuxPod.swift` adds complete workload resources,
  typed namespace selection and donor resolution, guest-device discovery, OCI
  runtime selection, safe stop/remove, process inspection, and the
  `LinuxSandbox` spelling.
- `Sources/Containerization/LinuxContainer.swift` makes the existing guest
  device resolver reusable by both runtime shapes.
- `Tests/ContainerizationTests/LinuxPodConfigurationTests.swift` covers
  compatibility defaults, independent namespace selection, correct network
  namespace paths, and missing/self donor rejection.
- `Sources/Containerization/SandboxContext/` and
  `Sources/Containerization/Vminitd.swift` carry the generated guest RPC and
  host client operations for workload pause/resume.
- `vminitd/Sources/Cgroup/Cgroup2Manager.swift` and
  `vminitd/Sources/VminitdCore/` implement cgroup v2 freezer convergence and
  the guest service operations.
- `Tests/VminitdCoreTests/Cgroup2ManagerProcessTests.swift` covers kernel-event
  parsing and freezer-file writes on Linux.

## Local macOS validation

```console
swift test --filter LinuxPodConfigurationTests
make check
make test
```

All commands passed on Apple silicon macOS. The focused suite passed six
tests. The repository gate passed 693 tests in 87 suites. `make check` passed
format and licence validation after installing the repository's pinned
Hawkeye binary.

The host-side generated protocol and API compiled in the focused and full
gates. A target-aware parse of the Linux-only implementation passed. A local
guest VM build could not start its dev image and the installed static Linux
SDK did not match the active Swift compiler, so Linux type-checking and the
two Linux-only freezer tests remain CI/upstream validation items. The local
runtime cleanup hang is tracked separately in
[`stephenlclarke/container#42`](https://github.com/stephenlclarke/container/issues/42).

## Follow-on work deliberately excluded

- Dynamic per-workload veth/TAP endpoint creation and network-namespace
  configuration.
- Live resource updates.
- Writable-layer and subpath parity in the multi-workload hot-plug path.
- Authority-owned durable workload identity, generation fencing, donor
  leases, and crash reconciliation.
- Docker, Compose, journald, logging-plugin, or API-socket policy.

Those capabilities can build on this generic substrate without changing its
namespace-selection model.

## Upstream review checklist

- Confirm `LinuxSandbox` is an acceptable source-compatible production name
  while `LinuxPod` remains available.
- Confirm donor lookup at process-start time is the correct generic boundary.
- Review the compatibility defaults before making private network namespaces
  automatic in a later endpoint-plan change.
- Exercise created-but-not-started cleanup with real socket relays and both VZ
  and Cloud Hypervisor hot-plug providers.
- Run the standard macOS and Linux CI lanes, including live pod integration
  tests on a virtualization-capable host.
