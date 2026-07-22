# Pull request handoff: synchronize Apple Containerization dependencies

## Summary

Synchronize the fork with Apple Containerization PR
[#808](https://github.com/apple/containerization/pull/808). The update adopts
the current Swift package resolutions and regenerated protobuf concurrency
annotations while preserving the fork’s authoritative protobuf schema.

## Apple-shaped boundary

- Uses Apple’s dependency resolutions and generated-code shape.
- Regenerates from `SandboxContext.proto` so the fork’s existing macOS runtime
  fields remain intact without a parallel schema or Compose-specific API.
- Adds only the repository-standard license header that the generator omits;
  it does not hand-maintain generated message implementations.
- Leaves all platform and Compose behavior unchanged.

## Code map

| Path | Change |
| --- | --- |
| `Package.resolved` | Adopts Apple’s current resolved dependencies. |
| `Sources/Containerization/SandboxContext/SandboxContext.pb.swift` | Regenerates SwiftProtobuf output with Apple’s isolation annotations and retains the standard file header. |
| `Sources/Containerization/SandboxContext/SandboxContext.proto` | Remains the authoritative fork schema; no schema field was removed or manually duplicated. |

## Validation

```console
swift build
make test
make check
make coverage
```

Verified on Apple silicon macOS:

- Build passed.
- Tests and coverage both passed 646 tests in 85 suites.
- Formatting and license validation passed.

Docker Compose V2 parity is not a changed surface in this PR: the Compose
runtime pin remains untouched while its current prerelease completes the
required stable-release soak.

## PR template

### Type of change

- [x] Dependency/build maintenance
- [x] Generated-source maintenance
- [x] Documentation update
- [ ] New feature
- [ ] Breaking change

### Motivation and context

Apple’s Swift 6.3 dependency refresh also changes generated concurrency
annotations. Regenerating from the fork’s existing protobuf source keeps that
maintenance current without losing macOS runtime capabilities consumed by the
Compose layer.

The fork `main` advanced independently with a merge of the same Apple commit
during this slice. The final signed reconciliation merge preserves that history
and has no additional source-content delta beyond the already validated header
restoration.

### Testing

- [x] Tested locally on macOS
- [x] Full repository test suite passed
- [x] Full coverage target passed
- [x] Formatting and license checks passed
- [x] Documentation updated
- [ ] Docker Compose V2 parity (no downstream Compose pin change)

## Commit tracking

- `bc71c26ffe44d64a80a4cbacfd1660223188fc55`
  (`merge: integrate apple containerization dependency update`)
- `62291e3b44309a70bb3b4b3f02df5977835c3f6a`
  (`fix(build): retain generated protobuf license header`)
- `9a3c5b4db57013256b681df9d90fe1a9235fcd03`
  (`chore(upstream): merge apple containerization main`; concurrent `main` update)
- `e2d60675f55074cc01e319eee1c21556d9a28474`
  (`merge: reconcile containerization upstream sync`)
