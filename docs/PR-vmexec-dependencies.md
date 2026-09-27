<!-- markdownlint-disable MD013 -->
# perf: remove guest server dependencies from vmexec

## Changes and motivation

Move unchanged workload network contracts into ContainerizationNetlink and namespace-entry flag selection into ContainerizationOS. Keep public type aliases in their former modules. Expose the existing Cgroup and LCShim targets through the ContainerizationCgroup product and use that smaller product from vmexec. Declare the OCI target's existing NIOFoundationCompat import explicitly; the former broad dependency had supplied it transitively.

## Validation

The optimized ARM64 Linux guest cross-compiles. Existing workload-network tests exercise the original Containerization API through the compatibility aliases. Namespace-entry tests move to the OS layer with their implementation. All ten focused tests pass. Two alternating nine-trial runtime comparisons preserve successful startup and command execution. Helper size falls from 88,341,440 to 73,935,808 bytes. Changing only VminitdCore no longer compiles or links vmexec.

## Compatibility and risks

Shared implementations and encoded network data are unchanged. The public type aliases preserve Swift source compatibility; clients must rebuild because the defining module changes. Existing SwiftPM consumers already build from source. No namespace, capability, mount, device-count or memory-throttling settings change. No startup or exec speed improvement is claimed from these measurements. The final pinned build and benchmark evidence is recorded in the container-only Bazel workspace.

See [the issue](ISSUE-vmexec-dependencies.md).
