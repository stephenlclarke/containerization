# Issue handoff: custom vmnet interfaces cannot configure IPv6 guests

## Problem

`NATNetworkInterface`, the generic interface used when a caller supplies a
custom vmnet network reference, retained only IPv4 address and gateway
information. The guest setup path already understands `Interface.ipv6Address`
and `Interface.ipv6Gateway`, so a caller could configure an IPv6 prefix on
vmnet but could not carry the corresponding IPv6 guest address and default
route through this interface type.

## Expected behavior

A macOS 26 caller that creates a custom vmnet network can provide optional
IPv6 address and gateway values alongside the existing IPv4 values. The
virtual-machine agent configures the IPv6 address and default route using the
existing generic `Interface` protocol behavior. Callers that omit both values
retain the current IPv4-only behavior.

## Reproduction

On macOS 26, create a custom vmnet network with an IPv6 prefix and construct
`NATNetworkInterface` with its network reference. Before this change, its
initializer exposes no IPv6 configuration, so the guest receives no configured
IPv6 address or IPv6 default route from that interface.

## Scope and ownership

This belongs in `apple/containerization`: it is a small, generic extension of
an existing macOS vmnet interface. It does not parse Docker or Compose
configuration, invent network policy, or change Windows or Linux-host behavior.

## Proposed fix

Add optional `ipv6Address` and `ipv6Gateway` properties and matching
initializer arguments to `NATNetworkInterface`. Preserve the previous nil
defaults and initialize the unavailable pre-macOS-26 form with nil IPv6
values. The signed fork commit is
`fe272b22c133bd82e319d3c91863fe11abe708a0`.
