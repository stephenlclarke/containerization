# test: distinguish closed directory descriptors from reused slots

## Changes

Capture device/inode while the callback owns the private directory. After callback failure, require EBADF or a different object at the same number, capturing errno immediately after fstat. A second case allocates a free descriptor at or above the released number with F_DUPFD_CLOEXEC, exercising reuse safely without overwriting another parallel test's descriptor. Under contention the allocation can use a higher slot; exact-slot reuse is not claimed. A leak still identifies the original live directory and fails.

## Validation

The original full coverage failure and raw descriptor/errno values remain recorded. All 55 focused secure-path tests pass, including both cleanup cases, with warnings-as-errors. Independent read-only review confirmed leak detection and safe allocation. No production code changes, suite serialization, retries or benchmark baseline runs are introduced. Full coverage is rerun once at the signed checkpoint because this failed assertion invalidated the earlier gate.

Related: [issue handoff](ISSUE-descriptor-cleanup-test.md).

## Quality follow-up

The exact `363bc62` checkpoint passed full macOS coverage and all 1,061 Linux tests. SonarCloud passed its quality gate with 93.3% new-code coverage, but the separate zero-issue check retained one S1186 finding on the directory-creation helper's intentionally empty default callback. A nested comment now explains that directory creation alone requires no caller descriptor operation. The callback behavior and existing cleanup tests are unchanged; coverage and analysis are refreshed at the new signed source checkpoint.
