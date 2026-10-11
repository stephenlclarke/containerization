# Pull request handoff: synchronize Apple Containerization main

Merge Apple `3e7bc39e66b38806ec8199aaa24509d66708eb60` into the exact released fork source `6db16197bbad8196a78132f86529daa89125aafb`. Seven merge conflicts require reconciliation; no performance experiment is included.

## Resolution boundaries

- `FileDescriptorOps.swift` adopts Apple's primitives, error cases, close-on-exec descriptors and guarded resolve-beneath flag. The composite file retains Apple's iterative component reuse. A non-creating `withOpenDirectory` bridge preserves the fork's deferred metadata/hardlink callers and their error contract. Explicit permissions are applied only to a newly created, pinned directory descriptor, preserving the fork's behavior independently of umask.
- `ArchiveReader.swift` retains the fork's filtered extraction, direct sparse block copying, deferred metadata and hardlink ordering. It uses Apple's relative member-name conversion and exhaustive new error cases; no copy-root containment fix is claimed.
- `EXT4+Formatter.swift` is byte-identical to Apple's target. Apple's partial-group layout and allocation accounting replace the older fork implementation. Journal end-block validation is adopted without removing the fork's additive usable-capacity sizing and JBD2 minimum checks.
- Token handling adopts Apple's optional-service query helper and tests, retaining the fork's TLS realm validation, redirect/challenge rejection, bounded response body, independent deadline and cancellation completion. Registry requests retain the upstream User-Agent override behavior.
- Coverage retains the fork's validated multi-bundle LLVM wrapper, which already implements the intent of Apple's multi-bundle fix and feeds Sonar. The upstream extra-flags hook is adopted. No second coverage implementation or extra test build is added.

## Validation

The four focused host suites pass after migrating the fork's two obsolete EXT4 layout assertions to Apple's packed metadata layout. The replacement checks retain requested filesystem sizes, validate every group bitmap and its invalid tail, reconcile group/superblock free counts, and require all metadata blocks to be allocated and in bounds. The formatter remains byte-identical to Apple's target.

Validation completed on October 11, 2026:

- `make check`: passed, including the Makefile's quoted Swift version and scratch-path handling.
- `swift test --jobs 4 --scratch-path <retained scratch> --filter 'ContainerizationOSTests|ContainerizationArchiveTests|ContainerizationEXT4Tests|ContainerizationOCITests'`: 453 tests passed (79 OS, 68 archive, 93 EXT4, 213 OCI).
- `python3 -m unittest discover -s Tools/coverage -p 'test_*.py'`: 19 tests passed.
- Independent images generated from the compiled formatter: 160 MiB (167772160 bytes) and 128 MiB + 4 KiB (134221824 bytes). Installed `e2fsck -fn` returned 0 for both; each completed all five passes without filesystem errors. The tiny partial group remains one block; its metadata is packed into earlier filesystem space.

The original failing test log and the subsequent successful log, image bytes, generation helper, commands, and e2fsck outputs remain in the goal's `upstream-audit` directory. No VM workloads, push, publication, or performance claim forms part of this validation.

Retain the existing archive sparse/hardlink/deferred-metadata tests and upstream traversal, token-query, partial-group and journal tests. Added bridge coverage checks refusal of symlink traversal, close-on-exec and descriptor closure after callback failure; the hardlink regression also covers absolute archive names anchored below the extraction root. Full layer tests, product coverage and later real integration remain required before a release claim. Copy-root symlink handling (Container #2379) and sparse EXT4 export corruption (Containerization #958) remain separately queued; neither is claimed fixed by synchronization.
