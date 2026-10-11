# test: distinguish closed directory descriptors from reused slots

## Changes

Capture device/inode while the callback owns the private directory. After callback failure, require EBADF or a different object at the same number, capturing errno immediately after fstat. A second case allocates a free descriptor at or above the released number with F_DUPFD_CLOEXEC, exercising reuse safely without overwriting another parallel test's descriptor. Under contention the allocation can use a higher slot; exact-slot reuse is not claimed. A leak still identifies the original live directory and fails.

## Validation

The original full coverage failure and raw descriptor/errno values remain recorded. All 55 focused secure-path tests pass, including both cleanup cases, with warnings-as-errors. Independent read-only review confirmed leak detection and safe allocation. No production code changes, suite serialization, retries or benchmark baseline runs are introduced. Full coverage is rerun once at the signed checkpoint because this failed assertion invalidated the earlier gate.

Related: [issue handoff](ISSUE-descriptor-cleanup-test.md).
