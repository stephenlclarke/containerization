# chore: rebase containerization on Apple main

## Changes

Rebase on Apple `7723232d1832e059f2a092bc3377f844ec7b3803` and keep the fork's
workload namespaces, resource controls, filesystem context and archive handling.
Apple's merged package exclusion fix (#798) is included through upstream history.

Use Apple's current descriptor operations, VM resources and runtime setup. Keep
implicit VM sizing for existing fork callers; reject CPU overhead that overflows.
Apply network sysctls in the VM only when the workload uses the VM network. Private
or joined network namespaces pass those settings to the OCI runtime.

Keep strict memory safety checks with Swift 6.3 and 6.4. Conditional annotations
handle the compiler change for pointer closure calls without disabling warnings.

## Validation

- macOS: 1,065 tests in 128 suites pass.
- Official Swift 6.4.1 Linux image: 1,115 tests in 144 suites pass.
- Both guest executables build with Swift 6.3 and 6.4.1 on Linux (glibc).
- The network-scope regression fails when the namespace guard is removed.
- Protobuf regeneration produces no changes. Swift format checks pass.
- Both static ARM64 guest executables build with Swift 6.3 and its matching
  Static Linux SDK.
- After the compiler compatibility changes, 74 focused macOS tests pass.

Evidence is in `upstream-pr-refresh/20261112/fork-sync` in the task workspace.

## Compatibility and remaining limits

Explicit VM resources keep Apple's behavior. Existing fork callers can still omit
VM resources and use workload limits plus overhead. Packed EXT4 metadata tests now
match Apple's current layout. Linux tests run in the official image, which includes
Swift Testing. The Static Linux SDK is used for production guest builds only.

These checks do not establish full VM runtime integration on macOS. The local
container API service did not start during the runtime preflight.

Main requires a review and blocks force pushes. Publication uses a separate review
branch. A history-only merge retains the published fork main as an ancestor and
keeps the reviewed rebased tree unchanged. This permits a normal reviewed merge
without rewriting main. No main protection setting is changed.
See [the issue handoff](ISSUE-upstream-sync-20261112.md).
