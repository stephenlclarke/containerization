# LinuxContainer configuration cannot control the OCI OOM killer setting

## Summary

`ContainerizationOCI.LinuxMemory` already models the OCI `disableOOMKiller` property, but `LinuxContainer.Configuration` cannot set it. Consumers of the public Containerization API therefore cannot request the standard OCI memory-cgroup behavior without constructing and managing an OCI runtime specification outside the library.

## Expected behavior

`LinuxContainer.Configuration` should expose an optional, generic OOM-killer setting and project it into `LinuxMemory.disableOOMKiller`. An omitted value must preserve the runtime default.

## Scope

- macOS host with the existing Linux guest runtime only.
- No Windows code or platform abstraction changes.
- No custom Docker/Compose behavior; this is the OCI-level primitive that higher layers can consume.

## Reproduction

1. Construct `LinuxContainer.Configuration` with the existing public API.
2. Generate its OCI runtime specification.
3. Observe that `resources.memory.disableOOMKiller` cannot be configured.

## Proposed resolution

Add `disableOOMKiller: Bool?` to `LinuxContainer.Configuration` and its convenience initializer, then pass it through when `LinuxContainer` produces `LinuxMemory`.
