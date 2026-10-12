# fix: preserve guest connection ownership through shutdown

## Changes

Use NIO's typed `withConnectedSocket` initializer so that pipeline configuration precedes inbound traffic while the configured result is retained through registration and activation. Retain the wrapped transport and call its additive async close API directly, then await the connection runner. This avoids GRPCClient's pre-start shutdown path without adding sleeps or changing async-writer deinitialization policy. Select the signed transport lifetime correction in both host and guest resolved graphs.

## Validation

The socketpair ownership regression passed both a connected peer and a peer that closes first, alongside the FileHandle owner-retention case (two tests, three cases). The focused run completed in 46.088 seconds with warnings-as-errors; formatting, license-header and scoped Markdown checks passed. Close errors are asserted rather than suppressed. Original and activation-only failures, source identities and focused SDK/transport results are retained with the performance/parity checkpoint. The transport correction passed 542 applicable core and HTTP/2 cases with one existing host-vsock applicability skip. Full exact-source SDK coverage, Linux and VM qualification remain subsequent gates; earlier fbe guest/native proofs remain historical evidence and are not relabelled for this revision.

## Compatibility

Vminitd public API signatures and guest wire protocols remain unchanged. Public GRPCClient remains available. Normal active calls retain graceful transport shutdown, while callers must still explicitly close their guest client. No published baseline artifact is rebuilt or rebenchmarked and no performance gain is claimed.

Related: [issue handoff](ISSUE-guest-connection-lifetime.md), [transport correction](https://github.com/stephenlclarke/grpc-swift-nio-transport/commit/2ddb7175729b30e5a12f4c3cb14f15985b1b2b1e).
