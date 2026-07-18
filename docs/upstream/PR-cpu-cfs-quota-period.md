# Pull request: support CPU CFS quota and period

## Summary

- Add optional CFS CPU period configuration to `LinuxContainer.Configuration`.
- Preserve the existing CPU-count-derived `100000` microsecond quota and period
  when neither explicit CFS value is supplied.
- Allow an explicit period without a quota, which produces an OCI CPU resource
  with an unlimited quota and the requested period.
- Keep this a generic OCI/macOS Linux-guest runtime primitive with no Docker
  or Compose types.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Optional generic CFS quota and period primitives in `LinuxContainer.Configuration`. |
| `apple/container` | Separate consumer that exposes generic CLI flags and persists configuration. |
| `container-compose` | Separate consumer that maps Compose fields to those generic flags. |

The implementation changes the runtime-spec projection only. It does not
change VM CPU allocation, host scheduling, networking, or any non-macOS
platform path.

## Code map

- `Sources/Containerization/LinuxContainer.swift` adds
  `cpuPeriodInMicroseconds`, carries it through the public initializer, and
  projects the optional quota/period pair to OCI `LinuxCPU` resources.
- `Tests/ContainerizationTests/LinuxContainerTests.swift` covers explicit
  quota+period, the existing fractional quota behavior, and period-only
  unlimited-quota semantics.

## Validation

```sh
swift test --disable-automatic-resolution --filter \
  'LinuxContainerTests/(runtimeSpecIncludesConfiguredFractionalCPUQuota|runtimeSpecIncludesConfiguredCPUQuotaAndPeriod|runtimeSpecRetainsUnlimitedQuotaForConfiguredCPUPeriod)'
git diff --check
```

The focused unit suite passed all three tests locally. Downstream Container
integration then created a macOS-hosted Linux container with a `50000`
microsecond quota and `200000` microsecond period and asserted guest cgroup v2
`cpu.max` is exactly `50000 200000`.

## Review checklist

- [ ] Replay `e540824` after the fractional-CPU primitive (`f7b45bf`).
- [ ] Verify no CFS override leaves the existing CPU-count-derived `100000`
  microsecond period and quota behavior unchanged.
- [ ] Verify a quota and period produce exactly those OCI CPU resource values.
- [ ] Verify period-only projection keeps `LinuxCPU.quota == nil`.
- [ ] Keep Docker CLI and Compose policy out of this generic runtime change.

## Non-goals

- CPU realtime scheduling and cpuset controls.
- Windows resource controls.
- VM CPU hotplug, host CPU affinity, or host scheduler changes.
