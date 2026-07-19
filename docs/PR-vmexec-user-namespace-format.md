# Upstream handoff: format user-namespace mapping assignment

## Proposed pull request

`style(vmexec): format user namespace mapping assignment`

This handoff covers the Apple-shaped code commit
`fbf9ce64f3ba007d1617fea2f2efade230371b20`.

## Summary

Restores the formatter-required line break in the guest runtime's private
user-namespace mapping-file helper. The change is source layout only and
unblocks the repository's strict format gate.

## Motivation and context

The prior assignment/continuation layout failed `swift format lint --strict`
with `AddLines`. That blocked the full local stack release validation before
Containerization unit or guest integration coverage could run. The formatter's
own output is the sole behavioral authority for this change.

## Implementation

### Code map

`vminitd/Sources/vmexec/RunCommand.swift`

Breaks the `contents` assignment before the mapping continuation.

The private `writeUserNamespaceMappings(_:to:)` helper retains its map,
separator, trailing newline, and file writes. The mapping handshake, OCI
configuration, and public APIs are unchanged.

## Validation on macOS

```console
swift format format --configuration .swift-format-nolint \
  vminitd/Sources/vmexec/RunCommand.swift
make swift-fmt-check
make check
```

All three commands pass after the change. No unit test is added because the
compiled guest behavior and every executable branch are unchanged; strict
formatting is the regression check. The full Containerization guest
integration and cross-stack release gates are run as the following release
validation step.

## Docker Compose compatibility

No Compose adapter or Docker Compose V2 fixture is applicable. This PR has no
Docker- or Compose-shaped surface and changes no runtime semantics.

## Compatibility and risks

The public API and encoded OCI configuration are identical before and after
the patch. The only risk is a future formatter configuration choosing a
different canonical layout; rerunning the standard formatter gate detects
that without changing runtime behavior.

## Upstream review checklist

* Confirm the formatter-generated layout is preferred over a style exception.
* Verify the diff remains limited to the private mapping-file helper.
* Run the standard macOS source and guest integration checks.
* Keep Docker/Compose policy and custom user-namespace mapping features out
  of scope.

Related issue handoff: `docs/ISSUE-vmexec-user-namespace-format.md`.
