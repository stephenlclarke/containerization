# Linux sandbox workloads need complete independent controls

## Problem

`LinuxPod` is the generic multi-workload VM seed, but its per-container
configuration exposes only CPU count, memory limit, mounts, process, and a
pod-wide PID/IPC sharing policy. A caller cannot preserve the resource,
annotation, runtime, or namespace choices already available on
`LinuxContainer`.

This prevents higher-level runtimes from adopting one long-lived Linux
sandbox without losing workload isolation or silently dropping settings. It
also prevents one workload from joining a specific active donor's PID, IPC,
network, cgroup, UTS, or user namespace.

The only pause/resume API is VM-wide. Using it in a multi-workload sandbox
freezes every sibling workload, which cannot implement Docker's independent
container pause semantics.

There is a lifecycle cleanup defect in the same path. Stopping a container
which was created but never started releases its device without first
stopping socket relays, unmounting its root filesystem, or syncing the guest.
The stopped registration also cannot be removed and reused while the pod
remains active.

## Expected behaviour

- A multi-workload Linux VM accepts the same cgroup resource, device,
  annotation, runtime, and user-namespace inputs as a single
  `LinuxContainer` where those settings are workload-scoped.
- PID, IPC, network, cgroup, UTS, and user namespaces can be private, can join
  the sandbox host namespace, or can join a named active workload donor.
- Missing, stopped, and self donors fail before the workload process starts.
- Guest device discovery behaves identically in the single-container and
  multi-workload paths.
- Stopping a created or running workload closes its relays, unmounts its
  rootfs, syncs the guest, and releases its attachments before marking it
  stopped.
- A stopped registration can be removed without stopping unrelated
  workloads or the VM.
- A running workload can be paused and resumed through its own cgroup v2
  freezer while the VM and sibling workloads continue running.
- Pause/resume returns only after the kernel reports the requested freezer
  state, and invalid lifecycle transitions fail without changing host state.
- Existing `LinuxPod` callers and pod-wide PID/IPC sharing remain source
  compatible.

## Reproduction outline

1. Create a `LinuxPod` and add two containers.
2. Attempt to configure memory reservation, swap, CPU shares/cpuset/quota,
   PID limit, block I/O, device rules, annotations, cgroup parent, or an OCI
   runtime per container. The API has no representation for these values.
3. Attempt to make the second container join only the first container's PID
   or network namespace. The API only supports the pod-wide PID/IPC pause
   namespace.
4. Create but do not start a hot-plugged container with socket relays, then
   call `stopContainer`. The old path releases attachments without the guest
   cleanup performed for a running workload.
5. Attempt to remove the stopped registration while keeping the pod active.
   No operation exists.
6. Attempt to pause only the second container. The old API can pause only the
   entire virtual machine, including the first container.

## Scope boundary

This issue covers generic Containerization workload mechanics. It does not
parse Docker or Compose policy, allocate IPAM addresses, create veth
endpoints, or define an Engine lifecycle ledger. Those remain responsibilities
of the higher-level authority and follow-on guest network APIs. Live resource
updates remain a follow-on workload-control operation.
