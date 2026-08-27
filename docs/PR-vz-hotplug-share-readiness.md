# Upstream handoff: wait for VZ unified-share rootfs publication

## Proposed pull request

`fix(virtualization): wait for hotplugged VZ rootfs`

## Summary

- Probe the newly published rootfs backing path from the guest before mounting
  it through a loop device.
- Retry only transient `notFound` responses, with a one-second upper bound and
  no delay on the already-ready path.
- Preserve the original error for timeout diagnosis and immediately propagate
  every non-readiness failure.
- Cover immediate visibility, delayed visibility, bounded exhaustion, and
  non-retryable failures with focused unit tests.

## Motivation and context

`VZMultipleDirectoryShare` updates are asynchronous from the guest filesystem's
point of view. A host hotplug call can complete before the newly published path
appears below `/run/virtiofs`. `LinuxPod.addContainer` previously mounted the
loop-backed rootfs immediately, so a second sequential workload in an existing
VZ pod could fail with `ENOENT` even though the share update itself succeeded.

Issue handoff: `docs/ISSUE-vz-hotplug-share-readiness.md` and
<https://github.com/stephenlclarke/containerization/issues/38>.

Related work:

- <https://github.com/stephenlclarke/container/issues/113> tracks the explicit
  shared-VM isolation contract that exposed this race.
- <https://github.com/stephenlclarke/container/issues/147> fixes terminal output
  and cleanup for naturally exiting shared workloads.
- <https://github.com/apple/containerization/issues/767> and
  <https://github.com/apple/containerization/pull/809> concern broader hotplug
  capabilities; no existing Apple report described this unified-share
  visibility race.

## Implementation

`LinuxPod.addContainer` performs the readiness probe only when a runtime rootfs
uses VZ's unified virtiofs transport. `Vminitd.stat` maps an absent guest path to
`ContainerizationError.notFound`; the bounded helper retries only that code.
The common already-visible path incurs one stat RPC and no sleep. Other agent
or transport errors remain immediate failures.

## Focused validation

```console
swift test --filter 'LinuxPodConfigurationTests.guestPathReadiness'
```

Result: four tests passed. Swift formatting lint and `git diff --check` also
passed. The matched-stack runtime certificate is performed in the consuming
Container pull request because that is where the sequential shared workloads
and exact guest artifact are assembled.

## Compatibility and risk

Cloud Hypervisor and boot-time rootfs mounts are unchanged. VZ per-tag
virtiofs mounts are unchanged. The retry is bounded to 50 probes spaced by 20
milliseconds and is entered only after the initial guest stat reports
`notFound`; persistent absence fails closed after about one second.

## Publication state

This document is a local fork handoff. Do not open or update an Apple issue or
pull request without explicit publication authorization.
