# Runtime extraction performance

## Reproduction and current behavior

Extract the retained Alpine OCI archive and run ArchiveReaderTests.extractDeepNesting on macOS with Xcode Swift and the pinned Bazel workspace. Sparse-aware extraction receives 4 KiB blocks and issues 7,318 writes. Repeated ComponentView reconstruction makes the debug deep-nesting fixture take 36 seconds.

## Expected behavior

Batch archive input and reuse parsed components while preserving sparse files, permissions, deferred metadata, error reporting and descriptor-based no-symlink traversal.

## Evidence

See the paired investigation and optimization evidence under ContainerFamily/retained/container-only. No remote issue has been opened.
