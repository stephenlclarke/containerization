# Pull request handoff: synchronize Apple Containerization main

## Summary

Synchronize the fork with Apple Containerization PR
[#809](https://github.com/apple/containerization/pull/809). The signed merge
adopts virtiofs rootfs hotplug for cloud-hypervisor `LinuxPod` instances and
preserves the fork's existing attached-filesystem subpath metadata.

## Apple-shaped boundary

- Takes Apple's implementation and public API unchanged.
- Resolves one conflict at the existing hotplug abstraction boundary.
- Preserves `sourceSubpath` for both block and virtiofs attachments.
- Adds no Docker or Compose vocabulary and no host-platform branch.
- Leaves Virtualization.framework behavior unchanged.

## Code map

- `Sources/Containerization/CHHotplugProvider.swift` adopts Apple's
  block/virtiofs hotplug dispatch and preserves `sourceSubpath` in both
  results.
- `Sources/Containerization/LinuxPod.swift` adopts Apple's virtiofs rootfs
  preparation and hotplug lifecycle.
- `Sources/Containerization/CloudHypervisorClient/*` adopts Apple's virtiofs
  device configuration and client calls.
- `vminitd/Sources/vminitd/Service.swift` adopts Apple's guest PCI rescan
  support.

## Validation

```console
make check
make test
make coverage
```

Verified on Apple silicon macOS:

- Formatting and license validation passed.
- Tests passed 647 tests in 85 suites.
- Coverage passed 647 tests in 85 suites and generated the coverage report.

The nested cloud-hypervisor runtime path requires a Linux KVM environment. It
is outside the locally executable macOS surface and is therefore not claimed
as Mac integration evidence.

## PR template

### Type of change

- [x] Upstream synchronization
- [x] Linux guest runtime feature
- [x] Documentation update
- [ ] New fork-specific API
- [ ] Breaking change

### Motivation and context

The fork should include Linux functionality that can be built and consumed by
the macOS-hosted stack. Taking Apple's commit directly avoids a parallel
implementation. The sole conflict resolution retains an existing fork field
without changing Apple's hotplug design.

### Testing

- [x] Tested locally on macOS
- [x] Full repository test suite passed
- [x] Full coverage target passed
- [x] Formatting and license checks passed
- [x] Documentation updated
- [ ] Linux KVM integration (not a macOS primitive)

## Commit tracking

- `2563ed5736cf57bef2bd4efb507572ad3d494206`
  (`feat: virtiofs rootfs hotplug for LinuxPod on cloud-hypervisor (#809)`;
  Apple upstream)
- `75bdc3dddaf1f8943c49514d68a40cf4fd3fa846`
  (`chore(upstream): merge apple containerization main`; signed fork merge)

No new upstream PR is proposed for this sync because the functional change is
already Apple-owned. This handoff documents the fork-only conflict resolution.

Related issue handoff:
`docs/ISSUE-apple-main-sync-20260723.md`.
