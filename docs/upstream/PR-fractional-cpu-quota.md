# Pull request: expose a generic fractional CPU quota primitive

## Summary

- Add optional `LinuxContainer.Configuration.cpuQuotaInMicroseconds`.
- Apply it to the existing OCI Linux CPU resource `quota` while retaining the
  established 100 ms period.
- Preserve the existing integer `cpus`-derived quota when no override is set.

## Apple-shaped boundary

The new field is generic Containerization configuration, expressed in the OCI
CPU quota unit (microseconds). It is independent of Docker, Docker Compose,
or a particular CLI. The sandbox VM remains configured with integral vCPUs;
the cgroup CFS quota controls workload CPU consumption in the Linux guest.

## Code map

- `Sources/Containerization/LinuxContainer.swift` defines the optional,
  documented configuration field and uses it when producing `LinuxCPU`.
- `Tests/ContainerizationTests/LinuxContainerTests.swift` verifies a 25,000
  microsecond quota with the fixed 100,000 microsecond period.

## Validation

Completed locally:

```sh
swift test --disable-automatic-resolution --filter \
  'LinuxContainerTests/runtimeSpecIncludesConfiguredFractionalCPUQuota'
git diff --check
```

The focused unit test passed. Its consumer in the companion `apple/container`
change additionally creates a macOS-hosted Linux container and verifies
`cpu.max` is `25000 100000` for a fractional `0.25` CPU limit.

## Review checklist

- [ ] Replay `f7b45bf` on the intended Apple upstream base.
- [ ] Verify omitted `cpuQuotaInMicroseconds` preserves `cpus * 100000`.
- [ ] Verify an explicit quota appears unchanged in the generated OCI spec.
- [ ] Keep CLI and Compose parsing outside this generic pull request.

## Non-goals

- Docker-specific CLI flags or Compose models.
- VM CPU hotplug or fractional VM vCPU allocation.
- Windows resource behavior.
