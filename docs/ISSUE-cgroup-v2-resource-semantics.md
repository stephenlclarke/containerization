# Cgroup v2 resource updates silently ignore OCI fields

## Problem

`Cgroup2Manager.applyResources` accepts a complete OCI `LinuxResources`
value, but applies only memory maximum, a paired CPU quota and period, CPU
shares, CPU sets, and the PIDs maximum. It silently ignores memory
reservation and swap, CPU burst and idle, block I/O, huge pages, RDMA,
`unified`, device rules, and every non-convertible cgroup v1 field.

This makes both initial `vmexec` setup and the live
`UpdateContainerResources` RPC report success while the requested kernel
state differs from the OCI configuration. A higher-level runtime cannot
reconcile desired state when the guest does not distinguish an applied value
from a dropped one.

The OCI runtime specification requires unknown `unified` cgroup v2 settings
to be written and requires an error when a v1 setting cannot be converted.
Its memory `swap` value is memory plus swap, while cgroup v2's
`memory.swap.max` is swap-only. The conversion must therefore subtract a
finite memory limit and reject an ambiguous finite swap request without one.

## Expected behaviour

- `memory.reservation` maps to `memory.low`.
- OCI memory-plus-swap maps to swap-only `memory.swap.max`, including
  unlimited and swap-disabled values.
- `checkBeforeUpdate` rejects a finite limit below `memory.current` before
  writing `memory.max`.
- CPU quota and period work when either optional field is supplied; CPU burst
  and idle map to `cpu.max.burst` and `cpu.idle`.
- CPU burst updates tolerate the kernel ordering constraint when quota and
  burst change together.
- Block I/O weight maps to BFQ when present or to converted `io.weight`; BPS
  and IOPS throttles map deterministically to `io.max`.
- Huge-page limits update both standard and reservation limits when the
  latter exists.
- RDMA limits and safe OCI `unified` values are applied deterministically.
- Every controller exposed by the running kernel is enabled for descendants,
  including controllers newer than the library's static enum.
- Short cgroup control-file writes fail instead of being reported as
  successful.
- Values without a faithful cgroup v2 implementation fail explicitly instead
  of being ignored.

## Reproduction outline

1. Start a `vmexec` workload with `memory.reservation`, memory-plus-swap, CPU
   burst, block I/O throttling, or a `unified` value.
2. Read `memory.low`, `memory.swap.max`, `cpu.max.burst`, `io.max`, or the
   selected unified file in its cgroup.
3. Observe that the old implementation leaves each file unchanged despite
   reporting successful process setup.
4. Send a live resource update containing a device ACL, swappiness, realtime
   CPU, or another cgroup v1-only field.
5. Observe that the old implementation reports success even though no kernel
   control is changed.

## Evidence and semantics

- The [OCI Linux runtime specification](https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md)
  defines memory swap as memory plus swap, requires ordered device rules, and
  requires unknown `unified` values to be written or rejected.
- The [Linux cgroup v2 documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
  defines `memory.low`, swap-only `memory.swap.max`, `io.weight`, and
  `io.max`.
- The [opencontainers/cgroups memory implementation](https://github.com/opencontainers/cgroups/blob/main/fs2/memory.go)
  provides the established memory-plus-swap conversion and absent-swap-file
  compatibility behaviour.
- The [opencontainers/cgroups I/O implementation](https://github.com/opencontainers/cgroups/blob/main/fs2/io.go)
  documents BFQ preference, weight conversion, and `io.max` mappings.

## Scope boundary

This issue covers complete cgroup v2 application for fields that have a
faithful filesystem mapping, plus explicit failure for fields that do not.
Cgroup v2 device ACLs require a BPF device controller and remain a separately
evidenced implementation gap. Durable desired-state revisions, rollback after
a partial kernel update, read-back, and crash reconciliation remain the
higher-level Engine authority's responsibility.
