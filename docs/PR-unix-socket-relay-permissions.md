# Upstream handoff: apply `.outOf` Unix relay socket permissions

## Proposed pull request

`fix(relay): apply host Unix socket permissions`

## Summary

Apply `UnixSocketConfiguration.permissions` when `UnixSocketRelay` creates the
host listener for an `.outOf` relay. Add a focused regression proving that a
requested `0600` mode is present on the created host Unix-domain socket.

## Motivation and context

`UnixSocketConfiguration` documents `permissions` as the permissions to set on
the created host socket. The `.into` path honours that value, but `.outOf`
previously omitted it when constructing `UnixType`. Protected guest services
that publish a private host endpoint could therefore receive a process-default
mode instead of the requested access boundary.

This correction is a generic Containerization relay fix. It contains no
Docker, Compose, logging-driver, or provider-specific policy.

Related issue handoff: `docs/ISSUE-unix-socket-relay-permissions.md`.

## Implementation

- Extract the `.outOf` host-listener construction into a package-visible helper
  so its filesystem contract can be tested without starting a VM.
- Pass `configuration.permissions` through to `UnixType` using its existing
  `mode_t` representation.
- Close the socket if `listen()` fails, preserving the established error while
  avoiding a leaked descriptor.
- Add `UnixSocketRelayTests.outOfRelayAppliesRequestedHostSocketPermissions`,
  which creates a short temporary socket path and verifies mode `0600`.

## Testing

Focused validation on Apple silicon macOS:

```console
swift test --filter UnixSocketRelayTests
```

Result: 1 test in 1 suite passed in 0.002 seconds. Repository-wide validation
is intentionally deferred to the next coherent multi-slice checkpoint.

## Compatibility and risks

The public API and relay protocol are unchanged. Callers that omit
`permissions` retain the existing default behavior. Callers that provide a
mode now receive the documented access control for `.outOf`, matching `.into`
semantics.

The helper remains package-scoped and is not part of the public API. The
regression uses a short path below `/tmp` because Unix-domain socket path length
is independently constrained; path-length semantics are not changed by this
patch.

## Upstream review checklist

- Verify `.outOf` applies an explicitly requested host socket mode.
- Verify an omitted mode preserves the existing default.
- Verify a `listen()` failure closes the newly created socket and returns the
  original error.
- Verify `.into` behavior remains unchanged.
- Keep higher-level Docker and Compose policy out of the generic relay
  implementation.

## Publication state

The Apple-shaped source, test, and handoff remain local on
`upstream/engine-linux-sandbox`. Do not create an Apple issue, pull request,
comment, branch, or push until all programme development waves are complete and
publication is explicitly authorised.
