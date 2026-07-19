# Upstream handoff: add a guest cgroup parent configuration

## Proposed pull request

`feat(runtime): add guest cgroup parent support`

This handoff covers the Apple-shaped code commit `8d4b530b5a8a9b8bca550e54a9820296cc548b7d`.

## Summary

Adds an optional relative `cgroupParent` to `LinuxContainer.Configuration`. The
generated OCI specification places each container in a leaf cgroup below the
sandbox VM's existing `/container` hierarchy.

## Motivation and context

The runtime already accepts OCI cgroup paths and creates nested guest cgroups.
Exposing the parent as a validated configuration value lets higher-level macOS
clients preserve a workload hierarchy without copying cgroup management into
every client or treating macOS as a Linux host.

## Implementation

### Code map

`Sources/Containerization/LinuxContainer.swift`

* Adds the documented `cgroupParent` configuration property and initializer
  argument.
* Validates that a supplied path is non-empty, relative, and free of empty,
  `.` and `..` components.
* Derives `/container/<parent>/<container-id>` while preserving the default
  `/container/<container-id>` path.

`Tests/ContainerizationTests/LinuxContainerTests.swift`

* Confirms nested path generation for `build/interactive`.
* Confirms absolute and traversal-shaped paths are rejected.

## Validation on macOS

```console
swift test
```

Passed: 638 tests in 83 suites, including focused `LinuxContainerTests`
coverage for the generated path and unsafe input rejection.

## Docker Compose compatibility

This is deliberately generic runtime support. A separate Compose adapter may
project Compose's `cgroup_parent` attribute through this API. Docker Compose
v2's configuration semantics remain the authority for that higher-level
mapping; this PR neither parses Compose YAML nor changes Docker compatibility
behavior itself.

## Compatibility and risks

The property is optional, so existing callers retain the identical OCI cgroup
path. Only the sandbox VM's Linux cgroup v2 hierarchy is affected. The
validation prevents callers from selecting the root, escaping the
runtime-managed path, or requesting any macOS-host hierarchy.

## Upstream review checklist

* Confirm `cgroupParent` is appropriately a generic `LinuxContainer`
  configuration, rather than a Compose-specific API.
* Confirm the relative-path validation matches the runtime-managed
  `/container` ownership boundary.
* Confirm omitted configuration remains byte-for-byte equivalent in the
  generated OCI cgroup path.
* Run the standard macOS unit suite.

Related issue handoff: `docs/ISSUE-guest-cgroup-parent.md`.
