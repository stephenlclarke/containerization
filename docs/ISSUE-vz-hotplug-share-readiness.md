# VZ pod rootfs mount can race unified-share publication

## I have done the following

- [x] I searched the existing Apple and fork issues and pull requests.
- [x] I reproduced the failure with two sequential containers in one running
  Virtualization.framework pod.

## Steps to reproduce

1. Create and start a `LinuxPod` with the Virtualization.framework backend and
   unified virtiofs.
2. Add, start, stop, and remove a container whose ext4 rootfs is exposed through
   the mutable unified share.
3. Add a second container to the same running pod.
4. Start the second container immediately after its host share is published.

## Current behavior

Updating `VZMultipleDirectoryShare` and returning from the host hotplug call
does not guarantee that the new path is already visible through the guest's
mounted unified share. `LinuxPod.addContainer` immediately asks `vminitd` to
mount the loop-backed rootfs. When publication loses that race, the guest
cannot open the backing file and the second container fails to start with
`ENOENT`.

The failure was observed after the first workload had exited and unmounted
normally. The same VM remained healthy; only the newly published share path was
temporarily absent.

## Expected behavior

- Probe the exact guest rootfs backing path before attempting its loop-backed
  mount.
- Return immediately when the path is already visible.
- Retry only `notFound` readiness failures for a short, bounded period.
- Propagate unrelated guest-agent failures without retrying them.
- Fail closed with a timeout if the path never appears.

## Scope

This is a generic `apple/containerization` VZ pod lifecycle race. It contains no
Container CLI, Compose, or Engine policy. Cloud Hypervisor, boot-time mounts,
and per-tag virtiofs mounts are outside the affected path.

Local fork issue: <https://github.com/stephenlclarke/containerization/issues/38>.
The failure blocks reliable shared-VM reuse tracked by
<https://github.com/stephenlclarke/container/issues/113> and the natural-exit
fix tracked by <https://github.com/stephenlclarke/container/issues/147>.

## Environment

- macOS 26.5.2 (25F84), Apple silicon
- Xcode 26.6 (17F113)
- Swift 6.3.3

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
