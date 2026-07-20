<!-- markdownlint-disable MD033 -->
<h1>
  <img alt="Containerization logo" src="./assets/Containerization-Logo.png" width="70" valign="middle">
  &nbsp;Containerization
</h1>
<!-- markdownlint-enable MD033 -->

The Containerization package allows applications to use Linux containers.
Containerization is written in [Swift](https://www.swift.org) and uses [Virtualization.framework](https://developer.apple.com/documentation/virtualization) on Apple silicon.

> **Looking for command line binaries for running containers?**\
> They are available in the dedicated [apple/container](https://github.com/apple/container) repository.

The `stephenlclarke` fork is the runtime library pinned by the matched
[`container`](https://github.com/stephenlclarke/container) and
[`container-compose`](https://github.com/stephenlclarke/container-compose)
packages. Users install the runtime/plugin stack rather than this library
directly; the canonical repository roles, current pins, and release policy live
in `container-compose`'s [README](https://github.com/stephenlclarke/container-compose#project-repositories),
[STATUS.md](https://github.com/stephenlclarke/container-compose/blob/main/STATUS.md),
and [BRANCHES.md](https://github.com/stephenlclarke/container-compose/blob/main/BRANCHES.md).

Containerization provides APIs to:

- [Manage OCI images](./Sources/ContainerizationOCI/).
- [Interact with remote registries](./Sources/ContainerizationOCI/Client/).
- [Create and populate ext4 file systems](./Sources/ContainerizationEXT4/).
- [Interact with the Netlink socket family](./Sources/ContainerizationNetlink/).
- [Create an optimized Linux kernel for fast boot times](./kernel/).
- [Spawn lightweight virtual machines and manage the runtime environment](./Sources/Containerization/LinuxContainer.swift).
- Configure OCI Linux runtime controls such as device cgroup rules and
  pre-resolved device nodes for generated runtime specs.
- Attach an optional virtio-gpu device to Virtualization.framework-backed
  container VMs. A guest kernel with the matching Linux DRM driver exposes the
  render node; this is paravirtual graphics-device support, not proof of
  hardware-accelerated rendering and not vendor GPU passthrough. Integration
  smoke tests skip with a clear capability result when the selected guest
  kernel does not expose `/dev/dri/renderD128`; unit tests still cover the
  graphics configuration contract independently of the guest kernel artifact.
- [Spawn and interact with containerized processes](./Sources/Containerization/LinuxProcess.swift).
- Use Rosetta 2 for running linux/amd64 containers on Apple silicon.

Please view the [API documentation](https://apple.github.io/containerization/documentation/) for information on the Swift packages that Containerization provides.

## Design

Containerization executes each Linux container inside of its own lightweight virtual machine. Clients can create dedicated IP addresses for every container to remove the need for individual port forwarding. Containers achieve sub-second start times using an optimized [Linux kernel configuration](/kernel) and a minimal root filesystem with a lightweight init system.

[vminitd](/vminitd) is a small init system, which is a subproject within Containerization.
`vminitd` is spawned as the initial process inside of the virtual machine and provides a GRPC API over vsock.
The API allows the runtime environment to be configured and containerized processes to be launched.
`vminitd` provides I/O, signals, and events to the calling process when a process is run.

## Backends

Containerization abstracts the VMM behind the `VirtualMachineManager` /
`VirtualMachineInstance` protocols and ships two implementations:

- **macOS — Virtualization.framework** (`VZVirtualMachineManager`). The shipping path on Apple silicon. Uses Apple's `Virtualization` framework directly; no extra binaries required.
- **Linux — cloud-hypervisor + KVM** (`CHVirtualMachineManager`). One `cloud-hypervisor` subprocess per VM, controlled over its REST-on-UDS API by the standalone [`CloudHypervisor`](./Sources/CloudHypervisor) Swift package. Block storage uses virtio-blk, shared directories use virtio-fs (one `virtiofsd` per share), networking uses TAP, and the guest agent is reached over cloud-hypervisor's hybrid vsock — same `vminitd` contract as the macOS path, so guest-side semantics are unchanged.

The Linux backend requires:

- `cloud-hypervisor` and `virtiofsd` on the host. Both are looked up on `PATH` by default; `CHVirtualMachineManager.init` accepts explicit URLs to override. `virtiofsd` is resolved lazily — a VM that uses only block-device mounts can run without it installed at all. Recent stable releases of each are recommended (smoke testing pins specific versions).
- KVM access (`/dev/kvm` readable + writable by the calling user).
- Pre-staged TAP / bridge / NAT plumbing if the container needs networking. `TAPInterface` consumes an existing TAP device by name; bringing it up, attaching it to a bridge, and configuring NAT or routing is the caller's responsibility.

The integration test suite (`make linux-integration`) runs inside an apple/container Linux VM with nested virt enabled (`container run --virtualization`). The kata kernel fetched by `make fetch-default-kernel` does not enable KVM, so the integration suite uses the in-repo kernel at `kernel/vmlinux-arm64` (or `kernel/vmlinuz-x86_64` on x86_64 hosts) instead — build it with `make -C kernel` before invoking `make linux-integration`. On Linux the suite runs only the cross-platform scenarios that don't depend on macOS-only types; the full suite remains macOS-only for now.

## Requirements

The full macOS build and test baseline requires:

- Mac with Apple silicon
- macOS 26
- Xcode 26

Older macOS versions are not supported. The Linux backend uses the Swift and
host requirements described in [Backends](#backends); macOS-only targets remain
outside that Linux test path.

## Example Usage

For examples of how to use the libraries' API surface, the cctl executable is a good start. This app is a useful playground for exploring the API. It contains commands that exercise some of the core functionality of the various products, such as:

1. [Manipulating OCI images](./Sources/cctl/ImageCommand.swift)
2. [Logging in to container registries](./Sources/cctl/LoginCommand.swift)
3. [Creating root filesystem blocks](./Sources/cctl/RootfsCommand.swift)
4. [Running simple Linux containers](./Sources/cctl/RunCommand.swift)

## Linux kernel

A Linux kernel is required for spawning lightweight virtual machines on macOS.
Containerization provides an optimized kernel configuration located in the [kernel](./kernel) directory.

This directory includes a containerized build environment to easily compile a kernel for use with Containerization.

The kernel configuration is a minimal set of features to support fast start times and a lightweight environment.

While this configuration will work for the majority of workloads we understand that some will need extra features.
To solve this Containerization provides first class APIs to use different kernel configurations and versions on a per container basis.
This enables containers to be developed and validated across different kernel versions.

See the [README](/kernel/README.md) in the kernel directory for instructions on how to compile the optimized kernel.

### Kernel Support

Containerization allows user provided kernels but tests functionality starting with kernel version `6.14.9`.

### Pre-built Kernel

If you wish to consume a pre-built kernel, make sure it has `VIRTIO` drivers compiled into the kernel (not merely as modules).

The [Kata Containers](https://github.com/kata-containers/kata-containers) project provides a Linux kernel that is optimized for containers, with all required configuration options enabled. The [releases](https://github.com/kata-containers/kata-containers/releases/) page contains downloadable artifacts, and the image itself (`vmlinux.container`) can be found in the `/opt/kata/share/kata-containers/` directory.

## Prepare to build package

Install the recommended version of Xcode.

Set the active developer directory to the installed Xcode (replace `<PATH_TO_XCODE>`):

```bash
sudo xcode-select -s <PATH_TO_XCODE>
```

Install [Swiftly](https://github.com/swiftlang/swiftly), [Swift](https://www.swift.org), and [Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html):

```bash
make cross-prep
```

If you use a custom terminal application, you may need to move this command from `.zprofile` to `.zshrc` (replace `<USERNAME>`):

```bash
# Added by swiftly
. "/Users/<USERNAME>/.swiftly/env.sh"
```

Restart the terminal application. Ensure this command returns `/Users/<USERNAME>/.swiftly/bin/swift` (replace `<USERNAME>`):

```bash
which swift
```

If you've installed or used a Static Linux SDK previously, you may need to remove older SDK versions from the system (replace `<SDK-ID>`):

```bash
swift sdk list
swift sdk remove <SDK-ID>
```

## Build the package

Build Containerization from sources:

```bash
make all
```

## Test the package

After building, run basic and integration tests:

```bash
make test integration
```

A kernel is required to run integration tests.
If you do not have a kernel locally, a default kernel can be fetched using the `make fetch-default-kernel` target.

Fetching the default kernel only needs to happen after an initial build or after a `make clean`.

```bash
make fetch-default-kernel
make all test integration
```

## Protobufs

Containerization depends on specific versions of `grpc-swift` and `swift-protobuf`. You can install them and re-generate RPC interfaces with:

```bash
make protos
```

## Building a kernel

If you'd like to build your own kernel please see the instructions in the [kernel directory](./kernel/README.md).

## Pre-commit hook

Run `make pre-commit` to install a pre-commit hook that ensures that your changes have correct formatting and license headers when you run `git commit`.

## Documentation

Generate the API documentation for local viewing with:

```bash
make docs
make serve-docs
```

Preview the documentation by running in another terminal:

```bash
open http://localhost:8000/containerization/documentation/
```

## Contributing

Contributions to Containerization are welcomed and encouraged. Please see [CONTRIBUTING.md](/CONTRIBUTING.md) for more information.

## Project Status

Containerization is under active development. Source stability is guaranteed
within a minor release line; use SwiftPM's `upToNextMinor` requirement when a
consumer must avoid potentially source-breaking minor upgrades.
