# chore: synchronize containerization with Apple main

## Changes

Merge Apple main `bc994b88df46207fad7775b0eabc51947e315881`. Adopt explicit `VMResources` and upstream seccomp/runtime behavior while preserving fork extensions. Keep one guest test target, place filesystem statistics in their intended type, and retain both sets of regression tests. The new runc exec implementation explicitly rejects filesystem-context requests, which remain anchored to the container init process.

## Compatibility

Callers must pass VM sizing through `vm:`; workload CPU/memory limits remain in container configuration. Live memory resizing preserves positive initial VM headroom and handles oversubscribed workloads without unsigned underflow. A pod workload may retain its own OCI runtime selection when adding a seccomp profile.

## Validation

All six host Bazel suites passed: ContainerizationUnitTests, ContainerizationOSTests, ContainerizationArchiveTests, ContainerizationEXT4Tests, ContainerizationOCITests, and ContainerizationExtrasTests. Added regressions cover oversubscribed memory resizing and per-workload runtime/seccomp selection. The updated container caller passed all 25 container suites. Both Linux guest executables compiled with Swift 6.3 and the aarch64 musl SDK using the compatible macOS 26.5 host SDK.

Logs, staged-tree fingerprints, test reports, and pre-merge bundles are retained under `ContainerFamily/retained/container-only/upstream-sync/20260927T123656Z`. The Bazel workspace also needs the zstd public-header import patch because upstream now imports zstd directly from Swift.

## Risks and related work

Linux test compilation is blocked because the installed Static Linux SDK does not ship the Swift Testing module (`guest-tests-compile.log`). Host tests and guest executable cross-compilation do not establish Linux test execution or a refreshed end-to-end performance comparison. Existing benchmark evidence belongs to its recorded prior revisions. See [the matching issue](ISSUE-upstream-sync-20260927.md).
