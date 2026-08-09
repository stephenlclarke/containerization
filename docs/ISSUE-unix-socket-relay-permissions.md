# Issue handoff: `UnixSocketRelay` ignores `.outOf` host socket permissions

## I have done the following

- [x] I have searched the existing issues.
- [x] I reproduced the issue using the local `main`-derived implementation
  branch.

## Steps to reproduce

1. Create a `UnixSocketConfiguration` with `direction: .outOf`, a host
   `destination`, and `permissions: .init(rawValue: 0o600)`.
2. Start the host listener used by `UnixSocketRelay.setupHostVsockDial()`.
3. Inspect the POSIX permissions of the created host Unix-domain socket.

The focused regression is
`UnixSocketRelayTests.outOfRelayAppliesRequestedHostSocketPermissions`.

## Current behavior

The `.outOf` setup path constructs `UnixType` without passing
`configuration.permissions`. The host listener therefore receives the
process-default socket mode instead of the explicitly requested mode. This
contradicts the public `PublishSocket` contract and can make a private
guest-to-host service endpoint accessible more broadly than requested.

The opposite `.into` path already passes the configured permissions to
`UnixType` when it creates its listener.

## Expected behavior

Both relay directions must apply `UnixSocketConfiguration.permissions` to the
Unix-domain socket they create. An `.outOf` relay configured with `0o600` must
create its host listener with mode `0600` before accepting connections.

## Environment

- OS: macOS 26.5.2 (25F84), Apple silicon
- Xcode: 26.6 (17F113)
- Swift: Apple Swift 6.3.3

## Relevant log output

```shell
swift test --filter UnixSocketRelayTests
Test run with 1 test in 1 suite passed after 0.002 seconds.
```

The regression fails against the unmodified implementation because the
requested mode is never passed into `UnixType`.

## Scope and ownership

This belongs in `apple/containerization`: it corrects the generic Unix-socket
relay contract and contains no Docker, Compose, logging-driver, or
provider-specific policy.

The Apple-shaped fix and focused regression are retained locally on
`upstream/engine-linux-sandbox`. They must not be published to Apple until all
programme development waves are complete and publication is explicitly
authorised.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
