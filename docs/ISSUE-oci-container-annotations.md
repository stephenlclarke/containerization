# Issue handoff: configurable OCI container annotations

## Problem

`ContainerizationOCI.Spec` already models OCI annotations, but
`LinuxContainer.Configuration` cannot supply them. Every macOS client that
needs runtime metadata must therefore misuse a different metadata channel or
maintain a private specification mutation.

## Steps to reproduce

On macOS, construct a `LinuxContainer` with the public configuration API. Before this change there is no supported way to make the generated OCI runtime specification contain:

```json
"annotations": {
  "com.example.owner": "platform"
}
```

## Current behavior

The generated specification always leaves `annotations` unset, despite the
underlying OCI model supporting the field.

## Expected behavior

An application can set a string-to-string annotation map on
`LinuxContainer.Configuration`. Non-empty values become the OCI spec's
annotations; the default empty map preserves the existing nil field.

## Scope and ownership

This belongs in `apple/containerization`: it is a generic OCI-spec projection
with no Docker or Compose dependency. It applies inside the existing macOS
sandbox VM and has no Windows- or Linux-host-specific behavior.

## Proposed fix

Add `annotations` to `LinuxContainer.Configuration`, expose it through the
memberwise initializer, and assign it while generating the OCI specification.
The signed fork code commit is
`9109cbb8dab85917475f2ab3cecdbee797e2c0ad`.
