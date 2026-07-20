# Issue: capability-gate virtio-GPU guest integration

## Summary

The macOS integration suite constructs a Virtualization.framework virtio-GPU
device, but the selected guest Linux kernel can omit its DRM virtio-GPU driver.
In that environment the guest never creates `/dev/dri/renderD128`, and the
two graphics smoke tests fail before they can inspect the configured device.

The runtime graphics configuration and its unit tests remain valid. The
missing render node is a kernel-artifact capability, not a macOS host or
Compose policy failure.

The proposed implementation is
[`de5b47a`](https://github.com/stephenlclarke/containerization/commit/de5b47a740355f1cd0baefb98b9031ad8e7c183a),
which changes only the existing integration harness.

## Expected behavior

The graphics smoke tests must continue to fail for all unexpected errors. They
must report an explicit skipped-capability result only for the exact
`notFound` error identifying the missing `/dev/dri/renderD128` guest device.
Hosts using a kernel with the driver continue to exercise modalias, device
node, and non-root access behavior unchanged.

## Scope

- macOS Virtualization.framework guest integration only.
- No Docker, Windows, Linux/Cloud Hypervisor, Compose, or runtime API change.
- No relaxation of unit coverage for graphics configuration.

## Validation

Run both graphics smoke tests against a kernel without the DRM render node and
confirm they are counted as skipped, not passed. Run the full integration
suite and verify every non-capability-dependent test remains required.
