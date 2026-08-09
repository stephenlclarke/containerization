# VZ pods cannot add block-rootfs containers after VM boot

## I have done the following

- [x] I have searched the existing issues.
- [x] I reproduced the issue using the local `main`-derived implementation
  branch.

## Steps to reproduce

1. Create and start a `LinuxPod` with the Virtualization.framework backend.
2. Materialize another Linux container whose root filesystem is an ext4 image.
3. Call `addContainer` after the pod VM is already running.
4. Attempt to start that container in the existing pod.

The cross-platform integration fixture is `pod hotplug block rootfs`. The
protected Docker logging-plugin and journald workloads exercise the same path
when they are materialized lazily inside the running Engine Linux sandbox.

## Current behavior

Virtualization.framework cannot add a virtio-block device after VM boot, and
the VZ instance has no runtime hotplug provider. A block-rootfs container added
to an existing pod therefore cannot make its ext4 image visible to the guest.
The rootfs mount fails before the container can start.

The local source branch now exposes the image through unified virtiofs and its
`vminitd` source translates the internal `loop` option into a loop device.
That protocol is not deployable with the currently pinned, published vminit
image, however. The published guest passes `loop` directly to `mount(2)`, so
the kernel rejects the root filesystem before the workload can start.

## Expected behavior

- Add block-rootfs and directory-rootfs containers to a running VZ pod without
  rebooting the VM.
- Expose a block image through the VM's mutable unified virtiofs share and
  attach it to a guest loop device before mounting the rootfs.
- Mount the unified share before any rootfs that depends on it.
- Reference-count shared host directories and preserve read/write widening
  while more than one container uses a share.
- Unmount the guest filesystem before detaching its loop device or withdrawing
  the host share.
- Reject unsafe or non-regular loop backing paths.
- Publish and pin a vminit image containing the matching loop-option protocol
  before enabling the VZ host-side transport in a distributable release.

## Environment

- OS: macOS 26.5.2 (25F84), Apple silicon
- Xcode: 26.6 (17F113)
- Swift: Apple Swift 6.3.3

## Relevant log output

```text
ext4: Unknown parameter 'loop'
failed initial mount ... type=ext4 data=loop
```

The distributable Container certificate now avoids this version-skew hazard by
exporting the already-verified final ext4 snapshot once and hot-plugging the
protected directory as a read-only virtiofs root. The generic block-rootfs
transport still requires the matched vminit publication above.

## Scope and ownership

This is a generic `apple/containerization` VZ pod lifecycle gap. The solution
contains no Docker, Compose, logging-driver, or application policy. The local
Apple-shaped implementation remains on `upstream/engine-linux-sandbox` and
must not be published until all programme development waves are complete and
publication is explicitly authorised.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
