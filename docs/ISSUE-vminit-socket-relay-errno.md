# Issue handoff: vminitd socket relay does not build on Linux

## Problem

The guest `VsockProxy` socket-publication path calls `swiftErrno`, but that
helper is private to `Server+GRPC.swift`. The merged guest implementation
therefore fails to compile on Linux and cannot produce the init image required
by Container Compose packaging.

The `chmod` failure path also performs descriptor and filesystem cleanup before
constructing its error. Those operations can replace `errno`, causing the
caller to receive the wrong failure.

## Expected behavior

`VsockProxy` must construct a `POSIXError` from the failing syscall's `errno`
within its own source boundary. Failure cleanup must preserve that captured
error.

## Scope and ownership

This belongs in `containerization` because it corrects the Linux guest socket
relay implementation. It changes no host API or Compose policy.

Tracking issue: <https://github.com/stephenlclarke/containerization/issues/35>.

## Regression coverage

The Linux-only `VsockProxyTests.currentPOSIXErrorSnapshotsErrno` test proves
that constructing the error snapshots `errno` rather than consulting a later
value.

Focused Linux validation:

```console
swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors \
  --filter VsockProxyTests
```

Result: 1 test in 1 suite passed.
