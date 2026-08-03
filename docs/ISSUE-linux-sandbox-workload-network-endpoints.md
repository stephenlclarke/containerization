# Linux sandbox workloads need private network endpoints

## Problem

`LinuxPod` can select a private or donor network namespace for a workload,
but it cannot create a veth endpoint, move the peer into that namespace, or
configure family-neutral addresses and routes before the process executes.
The `vmexec` namespace setup also omits the OCI network namespace flag, and
exec processes do not enter their owning workload's network namespace.

Consequently, a higher-level runtime cannot safely realise Docker-style
per-workload attachments inside one long-lived Linux VM. Falling back to the
sandbox host namespace weakens isolation, while configuring an endpoint after
start exposes the workload to a partially configured network.

The existing guest interface RPCs are not sufficient for this path. They
address interfaces in the guest's initial namespace, require legacy
interface shapes, and cannot provide an atomic host-peer/namespace-peer
lifecycle.

## Expected behaviour

- A workload can supply a bounded, fully resolved veth endpoint plan when it
  creates a private network namespace.
- The host side of each pair can join an existing guest bridge while the peer
  is moved atomically into the workload namespace.
- Interface names, MAC addresses, MTU, sysctls, IPv4-only, IPv6-only,
  dual-stack addresses, address scope, routes, default routes, and metrics
  are applied before the initial workload process executes.
- An empty private plan brings up loopback and implements an isolated
  `network_mode: none` namespace without inventing an IPv4 address.
- Endpoint creation rolls back already-created host links on failure, and
  workload removal cleans up owned links.
- Exec processes enter the owning workload's network namespace.
- Namespace donors do not receive a second independently owned endpoint.
- A caller cannot inject or replace the runtime's internal endpoint-plan
  annotation.
- Older guest agents fail closed before process creation when they cannot
  validate the endpoint-plan protocol.
- Existing callers that do not request an explicit workload network
  namespace retain the legacy sandbox-host network.

## Reproduction outline

1. Create a `LinuxPod` with a workload using an OCI private network namespace.
2. Attempt to provide a veth peer, MAC address, IPv6-only address, route,
   metric, MTU, or interface-scoped sysctl. The old API has no endpoint-plan
   representation.
3. Start the workload and observe that `vmexec` does not include
   `CLONE_NEWNET` in its OCI namespace mapping.
4. Exec another process in the workload and observe that its pidfd namespace
   entry mask also omits `CLONE_NEWNET`.
5. Attempt to configure the interface with the old guest RPCs. They operate
   outside the workload namespace and cannot make process start conditional
   on complete endpoint configuration.

## Scope boundary

This issue covers generic Containerization mechanics for a resolved
per-workload endpoint plan. It does not allocate addresses, select Docker
network drivers, persist network or endpoint ownership, publish ports,
program DNS policy, or reconcile an Engine ledger. Those remain higher-level
authority responsibilities.
