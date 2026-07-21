# Upstream handoff: add OCI container annotations

## Summary

Add an optional annotation map to `LinuxContainer.Configuration` and project
non-empty values into the generated OCI runtime specification.

## Type of change

- [x] New feature
- [x] Documentation update
- [x] Tests
- [ ] Breaking change

## Motivation and context

The OCI specification has an `annotations` member and Containerization already
models it, but callers of the public `LinuxContainer` API could not set it.
This small configuration bridge gives all macOS clients one generic, typed path
for OCI metadata instead of forcing product-specific adapters.

## Implementation

### Code map

- `Sources/Containerization/LinuxContainer.swift` adds the documented
  `annotations` configuration property, initializer argument, and OCI-spec
  projection.
- `Tests/ContainerizationTests/LinuxContainerTests.swift` proves that the
  generated specification preserves multiple configured annotations.

### Apple-shaped boundary

The change is deliberately limited to generic OCI configuration. It neither
parses Compose files nor exposes Docker labels, and it does not alter the
macOS-host security boundary or any Windows-specific runtime behavior.

## Testing

```sh
swift test --disable-automatic-resolution --filter LinuxContainerTests --no-parallel
swift test --disable-automatic-resolution --no-parallel
make swift-fmt-check
make check-licenses
```

All commands passed locally on macOS. The focused suite includes the new
annotation regression test; the full unit suite exercises the unchanged
default configuration path.

## Compatibility and risks

The property defaults to an empty dictionary, so existing callers continue to
generate a specification with no `annotations` member. Non-empty annotation
maps are emitted verbatim as OCI string metadata. No Docker Compose behavior
changes in this repository; a separate consumer can map a higher-level
configuration into this generic primitive.

## Commit tracking

- Required `containerization` code and test commit:
  [`9109cbb8dab85917475f2ab3cecdbee797e2c0ad`](https://github.com/stephenlclarke/containerization/commit/9109cbb8dab85917475f2ab3cecdbee797e2c0ad), `feat(runtime): add OCI container annotations`.
- Planned generic consumer: `apple/container` will add persistent
  `ContainerConfiguration.annotations`, a `--annotation` CLI option, and the
  runtime bridge.
- Planned Compose consumer: `container-compose` will map service
  `annotations` separately from `labels` and validate Docker Compose V2
  normalization behavior.

## Upstream review checklist

- [ ] Confirm this API is appropriately generic OCI configuration.
- [ ] Confirm an empty annotation map preserves the existing serialized spec.
- [ ] Confirm the configuration property and initializer naming match the
  public API style.
- [ ] Run the standard macOS unit suite.

Related issue handoff: `docs/ISSUE-oci-container-annotations.md`.
