# perf: batch archive reads and reuse parsed directory components

## Changes and motivation

Use the existing 4 MiB chunk size for all file-descriptor archive inputs. Retain sparse-aware pwrite offsets. Parse path components once and recurse through array slices instead of repeatedly rebuilding normalized FilePaths.

## Validation

The first iteration passed all 68 archive tests, including sparse, hard-link, truncated-input and metadata cases. Expanded the large-file regression to cross two 4 MiB boundaries with compressed and uncompressed input. The second iteration passed all 68 archive and 50 OS tests, plus the unchanged Extras suite. The 50-level debug archive case fell from 36.035 to 5.368 seconds; the 100-level OS case takes 67 ms. Nine optimized Alpine extractions after batching used 65 writes; whole-stack measurements are tracked in the container-only Bazel performance report.

## Compatibility and risks

No API or extraction policy changes. Descriptor lifetimes and O_NOFOLLOW traversal remain unchanged. Each open input may now buffer up to 4 MiB. Deep recursive traversal still consumes one descriptor per level, as before. Linux guest executable cross-compilation and runtime benchmarks are separate final integration gates. See [the issue](ISSUE-runtime-performance.md).

## Third iteration: cache directory depth

Compute directory depth once when queuing metadata restoration. Comparing these
integers preserves deepest-first ordering without repeatedly walking every path
during sorting. All 68 archive tests pass; the same debug deep-nesting fixture
fell again from 5.368 seconds to 0.863 seconds. Deferred permissions, timestamps
and last-entry behavior remain covered by the existing regressions.
