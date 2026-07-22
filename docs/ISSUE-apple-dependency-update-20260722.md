# Upstream sync: Apple Containerization dependency update

## Context

Apple commit
[`4f8dc6b53c8557434aafb2d0f7ef454dc0d026bb`](https://github.com/apple/containerization/commit/4f8dc6b53c8557434aafb2d0f7ef454dc0d026bb)
(`Update Package.resolved with latest versions (#808)`) refreshes the Swift
dependency lockfile for current Swift 6.3 support and regenerates the
`SandboxContext` protobuf isolation annotations. The fork retains additional
macOS-safe runtime fields in `SandboxContext.proto`, so generated output must
be rebuilt from the fork source rather than blindly taking either side of the
merge conflict.

## Required behavior

- Adopt Apple’s dependency resolutions and generated Swift concurrency
  annotations.
- Preserve the fork’s existing protobuf schema fields for Compose-facing
  macOS runtime configuration.
- Keep the generated protobuf source’s repository-standard license header.
- Avoid any changes to host-platform support, Docker Desktop, Windows, or the
  downstream Compose pin.

## Resolution

The `.proto` source remains authoritative. The fork regenerated
`SandboxContext.pb.swift` from that source with the Apple dependency update,
then restored the standard generated-source license header. This produces both
the Apple `nonisolated` generated declarations and the fork’s existing schema
fields with no hand-edited generated message definitions.

While this slice was being finalized, fork `main` also received
`9a3c5b4db57013256b681df9d90fe1a9235fcd03`, an independent merge of the same
Apple commit. Its resulting source tree differs from this slice’s upstream
merge only by the same generated-file header restoration. The signed
reconciliation merge retains that concurrent history without changing the
validated source content.

## Validation

```console
swift build
make test
make check
make coverage
```

Observed results on Apple silicon macOS:

- `swift build` passed.
- `make test` passed 646 tests in 85 suites.
- `make check` passed formatting and license validation.
- `make coverage` passed 646 tests in 85 suites and generated the coverage
  report.

No downstream Compose source, binary pin, or released asset changed in this
sync. Docker Compose V2 parity remains the evidence from the unchanged current
Compose prerelease and is not re-asserted as a new result here.

## Commit tracking

- `bc71c26ffe44d64a80a4cbacfd1660223188fc55`
  (`merge: integrate apple containerization dependency update`)
- `62291e3b44309a70bb3b4b3f02df5977835c3f6a`
  (`fix(build): retain generated protobuf license header`)
- `9a3c5b4db57013256b681df9d90fe1a9235fcd03`
  (`chore(upstream): merge apple containerization main`; concurrent `main` update)
- `e2d60675f55074cc01e319eee1c21556d9a28474`
  (`merge: reconcile containerization upstream sync`)
