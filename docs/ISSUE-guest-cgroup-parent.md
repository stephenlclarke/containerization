# Issue handoff: configurable guest cgroup parent

## Problem

`LinuxContainer` always writes the OCI cgroup path as
`/container/<container-id>`. This prevents a macOS runtime client from
representing Docker Compose's `cgroup_parent` service attribute, even though
the sandbox VM already owns the complete cgroup v2 hierarchy and `vminitd`
creates nested cgroups from an OCI path.

The missing capability is limited to the Linux guest. macOS has no host cgroup
hierarchy and must never be treated as one.

## Expected behavior

An API client can select a relative cgroup parent such as `workloads/build`.
The runtime creates the container leaf at
`/container/workloads/build/<container-id>` inside its sandbox VM. Omitted
parents retain the existing `/container/<container-id>` path.

Absolute paths, empty components, and `.` or `..` traversal components are
rejected before a runtime specification is produced.

## Reproduction

On an Apple-silicon macOS checkout, construct a `LinuxContainer` with
`Configuration(cgroupParent: "workloads/build")`. Before this change its
generated OCI specification has no way to differ from
`/container/<container-id>`.

## Scope and ownership

This belongs in `apple/containerization`: it adds a small, generic OCI-runtime
configuration property. It does not mention Docker or Compose, does not create
a macOS-host cgroup, and does not alter the VM's cgroup namespace policy.

## Proposed fix

Add `LinuxContainer.Configuration.cgroupParent`, validate it as a safe relative
guest path, and derive the OCI `linux.cgroupsPath` below the existing
`/container` runtime root. The signed fork commit is
`8d4b530b5a8a9b8bca550e54a9820296cc548b7d`.
