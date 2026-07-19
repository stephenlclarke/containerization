# Issue handoff: vminitd user-namespace mapping formatter violation

## Problem

`make check` could not complete in the Containerization fork because strict
Swift formatting rejected the chained assignment in
`vminitd/Sources/vmexec/RunCommand.swift`.

The guest code that writes the UID and GID mapping files used this form:

```swift
let contents = mappings
    .map { ... }
```

The repository formatter requires the assignment operator to terminate its
line before that continuation. This is a source-layout failure only; it does
not affect mapping values, namespace setup, or guest execution.

## Expected behavior

The repository-wide `make check` formatting gate accepts the guest
user-namespace mapping helper so the normal release validation can proceed.

## Reproduction

On an Apple-silicon macOS checkout with the repository-local Hawkeye tool
installed, run:

```console
make check
```

Before the fix, `swift format lint --recursive --strict` reports:

```text
vminitd/Sources/vmexec/RunCommand.swift:409:23: error: [AddLines] add 1 line break
```

## Scope and ownership

This belongs in `apple/containerization`: it preserves the project's normal
Swift formatting contract in generic guest runtime code. It adds no Docker or
Compose vocabulary, changes no public API, and does not alter macOS host or
Linux guest isolation behavior.

## Proposed fix

Use the formatter's canonical assignment layout in the private
`writeUserNamespaceMappings(_:to:)` helper. The signed fork commit is
`fbf9ce64f3ba007d1617fea2f2efade230371b20`.
