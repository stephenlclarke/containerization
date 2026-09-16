# Coverage generation fails with split SwiftPM test bundles

## Problem

Xcode 27 and Swift 6.4 emit one coverage-instrumented executable per
SwiftPM test target beneath `.build/out/Products/Debug`. The inherited
coverage recipe assumes the former aggregate
`containerizationPackageTests.xctest` executable, so `make coverage` and
`make coverage-sonar` fail after otherwise successful tests because that path
no longer exists.

The unattended `container-compose` stable-release controller exercises this
target in a clean isolated checkout. Consequently, the stale path blocks
Container-family release promotion even though the instrumented test
executables and profile data are available.

## Expected behaviour

- Discover all SwiftPM `.xctest` products deterministically.
- Accept the historical aggregate layout and current split-bundle layout.
- Reject missing, ambiguous, symlinked, or non-executable bundle products
  instead of silently reducing the report scope.
- Pass every discovered test executable to `llvm-cov` so coverage represents
  the complete package.
- Replace coverage evidence only after `llvm-cov` succeeds.

## Compatibility

The change is limited to local and hosted coverage generation. It does not
modify Containerization library or runtime behaviour and remains compatible
with stock Apple source consumers.

## Validation

- Coverage-helper unit tests exercise legacy, split, missing, malformed,
  symlinked, multi-object, success, and failure paths.
- `make coverage-sonar` must complete on Xcode 27 and produce non-empty text,
  LCOV, and Sonar generic reports.
- The downstream unattended Compose release must pass its isolated
  Containerization coverage gate.

## Tracking

- Issue: <https://github.com/stephenlclarke/containerization/issues/101>
