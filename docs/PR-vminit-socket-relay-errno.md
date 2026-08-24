# Pull-request handoff: capture vminitd socket relay errno locally

## Summary

Restore the Linux guest build by giving `VsockProxy` a local POSIX error
snapshot helper. Capture the `chmod` error before cleanup so the original
failure remains observable.

Closes <https://github.com/stephenlclarke/containerization/issues/35>.

## Implementation

- Construct `POSIXError` from the current Linux `errno`, with `EIO` as a safe
  fallback for an unknown code.
- Use the helper for socket ownership and permissions failures.
- Snapshot permission errors before closing and removing the socket.
- Add a Linux-only regression for the error snapshot contract.

## Validation

Formatting:

```console
swift format lint --strict --configuration .swift-format-nolint \
  vminitd/Sources/VminitdCore/VsockProxy.swift \
  Tests/VminitdCoreTests/VsockProxyTests.swift
```

Focused Linux test in `swift:6.3.0-noble`:

```console
swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors \
  --filter VsockProxyTests
```

Result: 1 test in 1 suite passed.

## Compatibility and risk

No public API changes. Successful socket publication is unchanged. Failure
paths now compile on Linux and report the syscall error that actually caused
the failure.
