# Upstream handoff: private Linux sandbox workload endpoints

## Proposed pull request

`feat(network): add private workload endpoints`

This handoff covers the signed Apple-shaped implementation commit
[`34bfb147e39cfd071712bcaff6d953aa0a659f58`](https://github.com/stephenlclarke/containerization/commit/34bfb147e39cfd071712bcaff6d953aa0a659f58).

## Summary

This change adds a bounded, typed, family-neutral endpoint plan to
`LinuxPod.ContainerConfiguration`. A caller supplies already-resolved veth
names, an optional guest bridge, the workload MAC address, addresses, address
scopes, routes, metrics, MTU, and a restricted set of interface sysctls.
Containerization realises that plan without taking ownership of IPAM or
Docker policy.

Before acknowledging the workload PID, vminitd atomically creates every veth
pair and moves its peer into the new process's network namespace. It can
enslave the host side to an existing guest bridge, applies MTU, and brings the
host link up. A partial failure deletes previously created links in reverse
order. Workload deletion removes its owned host links.

After the PID acknowledgement, `vmexec` is already inside the selected OCI
network namespace. It brings up loopback, applies the peer MAC, disables IPv6
router advertisement and autoconfiguration when static IPv6 is present,
writes only allow-listed interface sysctls, adds IPv4 and IPv6 addresses with
their requested scopes, brings the link up, and installs link routes before
default routes. The initial process cannot execute until all steps succeed.

The OCI namespace mapping and pidfd exec-entry mask now include
`CLONE_NEWNET`, fixing both initial and exec process isolation. A new additive
guest capability RPC validates the complete plan before process creation;
older agents use the protocol's default unsupported response and therefore
fail closed.

## Compatibility and security

- The legacy sandbox-host network remains the default when no explicit
  workload network namespace is selected.
- Endpoint ownership requires an explicit private namespace and the `vmexec`
  runtime. Donor namespaces cannot own another endpoint plan.
- A private namespace with an empty plan brings up only loopback, preserving
  IPv6-only and `network_mode: none` semantics without a synthetic IPv4
  address.
- Endpoint and route counts, encoded size, interface names, MTU, and sysctl
  sizes are bounded before transport.
- Sysctls are limited to the selected interface under `net.ipv4.conf`,
  `net.ipv6.conf`, or `net.mpls.conf`.
- The internal OCI annotation is reserved; workload annotations cannot inject
  or replace the plan.
- Existing `VirtualMachineAgent` conformers remain source compatible through
  a default unsupported capability implementation.

## Code map

- `Sources/Containerization/WorkloadNetwork.swift` defines the resolved plan,
  validation limits, and internal annotation transport.
- `Sources/Containerization/LinuxPod.swift` validates ownership, capability,
  namespace, and runtime requirements before process creation.
- `Sources/Containerization/SandboxContext/`,
  `Sources/Containerization/VirtualMachineAgent.swift`, and
  `Sources/Containerization/Vminitd.swift` carry the additive guest
  capability RPC.
- `Sources/ContainerizationNetlink/` adds atomic veth creation, peer namespace
  movement, family-neutral route installation, and address scopes.
- `vminitd/Sources/VminitdCore/ManagedProcess.swift` owns host-side endpoint
  creation, rollback, and cleanup.
- `vminitd/Sources/vmexec/RunCommand.swift` applies namespace-local interface
  configuration before exec.
- `vminitd/Sources/vmexec/ExecCommand.swift` enters the owning network
  namespace for later exec processes.
- `Tests/ContainerizationTests/WorkloadNetworkTests.swift` and
  `Tests/ContainerizationNetlinkTests/NetlinkSessionTest.swift` cover policy,
  IPv6-only round-trip behaviour, injection rejection, scope, and netlink
  packet shape.

## Local macOS validation

```console
swift test --filter WorkloadNetworkTests
swift test --filter NetlinkSessionTest
make check
make test
```

All commands passed on Apple silicon macOS. The endpoint policy suite passed
six tests, the affected netlink suite passed 15 tests, and the consolidated
repository gate passed 700 tests in 88 suites. `make check`, `git diff
--check`, host target compilation, and a target-aware parse of all Linux-only
Swift sources also passed.

A live guest build remains unavailable because the local Container runtime's
dev-image startup can hang and its cleanup command can wait indefinitely. The
recurrence and exact recovery evidence are recorded in
[`stephenlclarke/container#42`](https://github.com/stephenlclarke/container/issues/42).
The installed static Linux SDK also targets Swift 6.3.0 while the active
compiler is Swift 6.3.3. Linux type-checking and a live private-endpoint smoke
test therefore remain upstream CI review items rather than unsupported
claims.

## Follow-on work deliberately excluded

- Engine-owned IPAM allocation, endpoint/network persistence, generation
  fencing, idempotent reconciliation, and rollback across process restarts.
- Docker bridge, host, none, donor, overlay, macvlan, ipvlan, and plugin policy
  adapters.
- Port publication, DNS aliases, embedded DNS, firewall programming, and
  host reachability.
- Cross-sandbox network transport and macOS-side VM attachment management.

These capabilities can build on the resolved endpoint primitive without
moving Docker policy into Containerization.

## Upstream review checklist

- Confirm the typed endpoint and internal annotation boundary is acceptable
  for a generic library.
- Exercise veth creation, bridge attachment, IPv4-only, IPv6-only,
  dual-stack, and empty private plans in a Linux guest.
- Confirm rollback and deletion against real netlink failures and process
  startup failures.
- Verify old-agent capability failure and new-agent success across an image
  upgrade.
- Run the standard macOS and Linux CI lanes on virtualization-capable hosts.
