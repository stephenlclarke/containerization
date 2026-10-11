# Immediate guest-client shutdown can abandon the gRPC channel

## Description

The guest client resumed a checked continuation from inside NIO's channel initializer before the connected socket had registered and activated. Immediate close could release its configured async writer before `channelActive`. Separately, GRPCClient shutdown before its connection task starts skips the transport entirely, leaving an eager wrapped channel unconsumed. Both paths reproduced an NIO unfinished-writer assertion in the host unit suite.

## Reproduction

Construct Vminitd over a local socket pair, close its peer or leave that peer open, close the client immediately and release it. The previous owner-retention test ignored the close error and could report success before the asynchronous assertion. Raw original and activation-only crash evidence is retained in the performance/parity goal.

## Expected behavior

Socket activation must finish before returning a client. Explicit close must dispose the underlying connection and await its runner before the SDK owner can be released. Tests must not suppress close errors.

Related: [implementation handoff](PR-guest-connection-lifetime.md), [transport lifetime fix](https://github.com/stephenlclarke/grpc-swift-nio-transport/commit/2ddb7175729b30e5a12f4c3cb14f15985b1b2b1e).
