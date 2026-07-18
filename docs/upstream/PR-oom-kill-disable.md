# feat(runtime): configure OOM killer mode

## Summary

Expose the standard OCI `disableOOMKiller` memory setting through `LinuxContainer.Configuration`.

## Motivation

The OCI model already has `LinuxMemory.disableOOMKiller`, but public `LinuxContainer` callers could not configure it. This leaves callers that need this standard cgroup setting no supported route through Containerization.

## Implementation

- Add optional `LinuxContainer.Configuration.disableOOMKiller` with an omitted-by-default policy.
- Add the matching `disableOOMKiller` initializer parameter without changing existing callers.
- Project the value directly to `LinuxMemory.disableOOMKiller` in the generated OCI runtime specification.

The functional source change is commit `7f1d7bd` (`feat(runtime): configure OOM killer mode`). It touches only the generic Linux container configuration and its focused runtime-spec test.

## Validation

```text
swift test --disable-automatic-resolution --filter 'LinuxContainerTests/runtimeSpecIncludesConfiguredOOMKillerMode'
```

The focused test passes and verifies the public configuration produces `resources.memory.disableOOMKiller == true` in the OCI specification.

## Compatibility

- Existing callers retain the runtime default because the new setting is optional.
- This models an existing OCI property; it adds no Docker-specific API and no Windows behavior.
- The macOS host continues to delegate cgroup enforcement to the existing Linux guest OCI runtime.

## Follow-up consumers

The companion `apple/container` adapter can expose a generic `--oom-kill-disable` CLI flag and carry it in Linux runtime data. `container-compose` can then map the Compose `oom_kill_disable: true` service attribute without changing the Containerization API again.

## Risk

Enforcement remains the responsibility of the guest OCI runtime, as with the other `LinuxMemory` resource fields. This change deliberately does not invent host-side semantics or broaden the API beyond the OCI configuration bridge.
