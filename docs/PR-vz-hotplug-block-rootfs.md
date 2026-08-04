# Upstream handoff: hotplug block root filesystems into VZ pods

## Proposed pull request

`feat(virtualization): hotplug block roots through unified virtiofs`

## Summary

- Add a VZ hotplug provider backed by one mutable
  `VZMultipleDirectoryShare`.
- Expose runtime ext4 images through that share and mount them with guest loop
  devices.
- Mount newly exposed virtiofs content before a dependent root filesystem.
- Reference-count runtime shares and integrate their mount registry with the
  existing `VZVirtualMachineInstance` surface.
- Exercise block-rootfs hotplug on both VZ and Cloud Hypervisor integration
  lanes.

## Motivation and context

VZ cannot attach a virtio-block device after VM boot, but `LinuxPod` supports
adding containers to an already running VM. Lazy protected services and other
pod workloads use ext4 rootfs images, so the VZ backend needs a safe runtime
transport for those images rather than requiring a VM restart.

The VM already owns a unified virtiofs device. Updating its multiple-directory
share makes an image visible without adding hardware. The guest can then bind
that regular file to a loop device and mount the ext4 filesystem through the
existing agent protocol.

Related issue handoff: `docs/ISSUE-vz-hotplug-block-rootfs.md`.

## Implementation

- `Sources/Containerization/VZHotplugProvider.swift`
  - owns the mutable directory share, runtime rootfs/additional-share
    references, read/write widening, and mount registry;
  - validates regular block images and directory roots;
  - converts a VZ block attachment into a guest path plus the `loop` mount
    option.
- `Sources/Containerization/VZVirtualMachineInstance.swift`
  - installs the provider and routes mount registry access through it.
- `Sources/Containerization/LinuxPod.swift`
  - mounts new unified/per-tag virtiofs content before a dependent rootfs.
- `vminitd/Sources/VminitdCore/LoopbackDevice.swift`
  - validates and attaches regular files below `/run/virtiofs` to bounded Linux
    loop devices.
- `vminitd/Sources/VminitdCore/Server+GRPC.swift`
  - interprets the internal `loop` mount option, removes it before `mount(2)`,
    and detaches the device only after successful unmount.
- `Sources/Integration/PodTests.swift` and `Sources/Integration/Suite.swift`
  - make block-rootfs pod hotplug a cross-platform integration contract.

## Testing

Focused matched-stack evidence on this Apple-silicon Mac:

- the Container package compiled against this exact edit-mode dependency;
- the protected Docker plugin and journald workloads both started successfully
  inside an already running VZ Engine sandbox;
- sandbox generation 27 recorded one successful start operation for each
  service, with no retry mutation loop;
- the subsequent two-stream logging workload completed and its provider
  lifecycle closed `complete` with no active writer, reader, cleanup, or
  pending-removal residue.

The live integration command remains:

```console
swift run containerization-integration --filter "pod hotplug block rootfs"
```

Repository-wide validation is intentionally batched with the next immutable
multi-slice checkpoint.

## Compatibility and risks

Cloud Hypervisor retains its native block-device hotplug path. Boot-time VZ
mounts are unchanged. Runtime VZ block images now travel through the existing
private unified virtiofs device and a guest loop device; arbitrary paths and
non-regular backing objects are rejected.

Share state is reference-counted so one container cannot withdraw a directory
still used by another. A writable reference widens the shared directory only
for the lifetime of that reference. Guest unmount remains bounded and must
succeed before loop detachment.

## Publication state

The Apple-shaped source, integration coverage, and handoff remain local on
`upstream/engine-linux-sandbox`. Do not create an Apple issue, pull request,
comment, branch, or push until all programme development waves are complete and
publication is explicitly authorised.
