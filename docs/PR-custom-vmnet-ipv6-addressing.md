# Upstream handoff: configure IPv6 on custom vmnet interfaces

## Proposed pull request

`feat(network): carry IPv6 on custom vmnet interfaces`

This handoff covers the Apple-shaped code commit
`fe272b22c133bd82e319d3c91863fe11abe708a0`.

## Summary

Adds optional IPv6 address and gateway fields to `NATNetworkInterface`, the
generic macOS 26 interface type for a caller-owned vmnet network reference.
This lets the existing virtual-machine agent configure an IPv6 address and
default route for custom vmnet networks.

## Motivation and context

The generic `Interface` contract, guest agent, and netlink implementation
already support IPv6 address and default-route setup. `NATNetworkInterface` was
the remaining custom-vmnet path that only represented IPv4, creating a gap for
any macOS client that configures an IPv6 prefix itself.

## Implementation

### Code map

`Sources/Containerization/NATNetworkInterface.swift`

* Adds optional `ipv6Address` and `ipv6Gateway` protocol properties.
* Adds optional initializer arguments after the existing custom network reference.
* Preserves nil defaults and leaves the obsolete pre-macOS-26 initializer
  explicitly IPv4-only.

The shared `Interface` implementation already passes these fields to the guest
agent, which configures the address and default route through existing netlink
operations. No Compose-specific type or policy is introduced.

## Validation on macOS

```console
swift test --disable-automatic-resolution --filter InterfaceTests --no-parallel
```

Passed: the focused interface suite, including existing IPv6 interface protocol
and route-value coverage. Downstream macOS integration coverage creates a
custom vmnet network with an explicit IPv6 gateway and confirms the guest
default route uses it.

## Docker Compose compatibility

This is deliberately a generic runtime primitive. A higher-level macOS client
can map an IPv6 IPAM gateway through this API, but this PR neither reads
Compose YAML nor claims Docker Compose compatibility on its own.

## Compatibility and risks

Both arguments are optional, so all current IPv4-only callers preserve their
behavior. The change is available only on macOS 26 where custom vmnet
references are supported. It does not alter Windows or Linux-host behavior.

## Upstream review checklist

* Confirm the optional fields belong on the existing generic custom-vmnet interface.
* Confirm nil defaults preserve the current IPv4-only interface behavior.
* Confirm the guest-agent route setup remains the single owner of IPv6 guest configuration.
* Run the standard macOS unit suite.

Related issue handoff: `docs/ISSUE-custom-vmnet-ipv6-addressing.md`.
