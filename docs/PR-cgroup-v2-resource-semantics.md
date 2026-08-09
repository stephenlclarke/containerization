# Upstream handoff: complete cgroup v2 resource semantics

## Proposed pull request

`fix(cgroup): apply v2 resource semantics`

This handoff covers the signed Apple-shaped implementation commit
[`0fb71ab25eac1a8ba2d877da74d5bda077f963cb`](https://github.com/stephenlclarke/containerization/commit/0fb71ab25eac1a8ba2d877da74d5bda077f963cb).

## Summary

This change replaces the partial `applyResources` implementation with a
deterministic, testable cgroup v2 resource plan. The same path serves initial
`vmexec` setup and live resource updates, so both operations now apply the
same semantics.

The planner implements:

- memory maximum, best-effort reservation, OCI memory-plus-swap conversion,
  swap-disabled/unlimited behaviour, and optional current-usage checking;
- CPU weight, independent quota or period updates, burst, idle, and CPU-set
  configuration;
- PIDs maximum;
- BFQ or converted cgroup v2 I/O weights, optional BFQ per-device weights,
  and grouped per-device BPS/IOPS throttles;
- huge-page usage and optional reservation limits;
- RDMA limits; and
- sorted, path-safe OCI `unified` writes applied after typed settings so the
  explicit unified value wins.

All controller names advertised by `cgroup.controllers` are now enabled
rather than dropping names absent from a static enum. This preserves support
for future and configuration-specific controllers used by `unified`.

The implementation also handles CPU quota/burst ordering the same way as the
established OCI cgroup implementation: it tries burst first, defers an
`EINVAL` until after the accompanying quota update, and retries. A short
control-file write is now an error.

## Explicit unsupported behaviour

The previous code reported success for values it could not apply. The new
planner rejects these inputs before any planned write:

- cgroup v2 device rules, until a BPF device controller is implemented;
- kernel and kernel-TCP memory limits;
- swappiness and disabling the OOM killer;
- disabling hierarchical memory accounting;
- realtime CPU controls;
- cgroup v1 network class and interface priority controls;
- block-I/O leaf weights; and
- per-device I/O weights when BFQ is unavailable.

This is intentionally fail-closed. It gives the Engine authority evidence it
can persist and report instead of silently diverging from desired state.

## Compatibility and safety

- Existing supported CPU, memory, CPU-set, and PIDs mappings retain their
  cgroup v2 file formats.
- CPU shares use the current opencontainers logarithmic conversion, including
  the OCI/Docker default mapping of 1024 shares to weight 100.
- Missing `memory.swap.max` is ignored only for unlimited or swap-disabled
  requests, matching kernels built without swap accounting.
- Huge-page reservation files are optional; the standard usage limit remains
  required.
- Unified keys are restricted to one cgroup filename and cannot address
  process-migration, subtree, freeze, kill, thread, or cgroup-type controls.
- Device numbers, huge-page names, weights, CPU idle, quota, PIDs, swap, and
  duplicate throttles are validated before writes.
- Empty resource structures remain no-ops.

## Code map

- `vminitd/Sources/Cgroup/Cgroup2ResourcePlan.swift` validates OCI inputs and
  builds deterministic typed, unified, CPU maximum, and CPU burst operations.
- `vminitd/Sources/Cgroup/Cgroup2Manager.swift` checks current memory usage,
  executes the plan, handles optional kernel files and CPU ordering, retains
  CPU-set parent-memory initialisation, and enables every advertised
  controller.
- `Tests/VminitdCoreTests/Cgroup2ResourcePlanTests.swift` runs cross-platform
  planner coverage for memory, swap, CPU, I/O, BFQ, huge pages, RDMA,
  `unified`, validation, and explicit unsupported behaviour.

## Local macOS validation

```console
swift test --filter Cgroup2ResourcePlanTests
swift build --target Cgroup
make check
make test
```

All commands passed on Apple silicon macOS. The focused planner suite passed
nine tests. The consolidated repository gate passed 709 tests in 89 suites.
`make check`, `git diff --check`, and a target-aware parse of the Linux-only
manager and planner also passed.

The pure planner and Cgroup target compile on macOS. The manager's guarded
Linux syscall path cannot be type-checked with the locally installed static
SDK because that SDK targets Swift 6.3.0 while the active compiler is Swift
6.3.3. A live guest build is also blocked by the local Container runtime
startup/cleanup hang recorded in
[`stephenlclarke/container#42`](https://github.com/stephenlclarke/container/issues/42).
Linux file-write integration therefore remains an upstream CI review item.

## Remaining evidence-backed gap

Cgroup v2 device rules require an ordered `BPF_PROG_TYPE_CGROUP_DEVICE`
program attached to the workload cgroup. This change rejects non-empty device
rules rather than pretending to apply them. A follow-on implementation must
compile OCI ordered allow/deny rules, load and attach the program with the
required guest capabilities, replace it atomically on live update, and test
wildcard type/major/minor/access behaviour against real device opens and
`mknod`.

## Upstream review checklist

- Run planner and Linux-only cgroup tests in the standard Linux lane.
- Exercise memory reservation, finite/unlimited/disabled swap, and
  `checkBeforeUpdate` against a real cgroup v2 filesystem.
- Exercise CPU quota/burst changes in both increase and decrease order.
- Verify BFQ and non-BFQ I/O behaviour on representative kernels.
- Confirm huge-page reservation fallback and RDMA writes on kernels exposing
  those controllers.
- Review the unified-key lifecycle deny-list and explicit unsupported errors.
