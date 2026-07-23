# Upstream sync: virtiofs rootfs hotplug for LinuxPod

## Context

Apple commit
[`2563ed5736cf57bef2bd4efb507572ad3d494206`](https://github.com/apple/containerization/commit/2563ed5736cf57bef2bd4efb507572ad3d494206)
adds virtiofs rootfs hotplug for `LinuxPod` when cloud-hypervisor is the
virtual machine monitor. The fork was one Apple commit behind and retained a
macOS Compose-facing `sourceSubpath` value in both attached-filesystem paths.

## Required behavior

- Adopt Apple's virtiofs hotplug implementation and guest PCI rescan.
- Preserve the fork's existing `sourceSubpath` propagation for block and
  virtiofs filesystems.
- Avoid introducing Docker, Compose, or host-platform policy into the
  Containerization API.
- Keep the cloud-hypervisor feature available to Linux guests without claiming
  that its nested-runtime path was exercised on macOS.

## Resolution

The signed merge commit
[`75bdc3dddaf1f8943c49514d68a40cf4fd3fa846`](https://github.com/stephenlclarke/containerization/commit/75bdc3dddaf1f8943c49514d68a40cf4fd3fa846)
adopts Apple main. Its only conflict was in
`Sources/Containerization/CHHotplugProvider.swift`: the resolution keeps
Apple's new `.virtioblk` and `.virtiofs` dispatch while retaining the fork's
`sourceSubpath` field in both returned `AttachedFilesystem` values.

No upstream correction is required for Apple's source. The matching PR
handoff records the conflict boundary so future Apple syncs can reproduce the
same minimal resolution.

## Validation

```console
make check
make test
make coverage
```

Observed results on Apple silicon macOS:

- Formatting and license validation passed.
- The full test target passed 647 tests in 85 suites.
- The coverage target passed the same 647 tests in 85 suites and generated
  `code-coverage-report`.

The Linux cloud-hypervisor nested-runtime integration target is not a macOS
primitive and was not represented as locally executed evidence. The complete
source and unit-test graph did compile and pass on macOS.

## Commit tracking

- `2563ed5736cf57bef2bd4efb507572ad3d494206`
  (`feat: virtiofs rootfs hotplug for LinuxPod on cloud-hypervisor (#809)`;
  Apple upstream)
- `75bdc3dddaf1f8943c49514d68a40cf4fd3fa846`
  (`chore(upstream): merge apple containerization main`; signed fork merge)
