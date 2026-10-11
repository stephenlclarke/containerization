# Upstream handoff: export selected ext4 paths and directory subtrees

## Proposed pull request

`feat(ext4): export selected ext4 paths`

This handoff began with the Apple-shaped subtree-export commit
`b91f20f717439c26d51ae13ad7b172cf86cbabb2` and now includes selected-path
export and clean-journal rejection support for offline readers.

## Summary

Keep `EXT4.EXT4Reader.export(archive:subtree:)` as the directory-contents
primitive and add `export(archive:selectedPath:followSymlink:)` for one regular
file or symbolic link. Selected files retain their requested basename and
metadata, stream in bounded chunks, and preserve sparse regions in archive
metadata. Parent symlinks resolve normally; final-link following remains
explicit. A selected hard link is materialized as a regular archive member.
Readers may also opt into rejecting filesystems marked for journal recovery
before traversing group descriptors.

## Motivation and context

The existing reader can export a whole filesystem or a directory's contents,
but cannot export one regular file or symlink as a named archive member. A
runtime otherwise has to boot a guest or build its own ext4-to-host transfer
path. The selected-path API is generic and contains no Docker metadata, volume
lifecycle policy, or Compose model handling.

## Implementation

### Code map

`Sources/ContainerizationEXT4/EXT4Reader+Export.swift`

* Retains the existing complete-filesystem and subtree export behaviors.
* Adds `export(archive:selectedPath:followSymlink:)`, emitting exactly one
  regular-file or symlink member under the requested final component.
* Streams regular-file contents through `ArchiveWriterTransaction` in bounded
  chunks and records sparse data extents when present.
* Keeps PAX/xattr metadata and materializes selected hard links as regular
  files, without referring to an absent primary name.

`Sources/ContainerizationEXT4/EXT4+Reader.swift` and `EXT4.swift`

* Add an opt-in `requireCleanJournal` initializer guard that checks the ext4
  recovery flag before reading group descriptors or traversing the filesystem.

`Sources/ContainerizationEXT4/EXT4Reader+IO.swift`

* Follow symlinks in parent path components even when final-component
  following is disabled, matching `lstat`-style final-component semantics.

`Tests/ContainerizationEXT4Tests/TestEXT4ReaderExport.swift` and
`TestEXT4SparseRead.swift`

* Add selected regular-file metadata/content, relative and absolute symlink,
  dangling-link, final-link-following, parent-symlink, selected-hardlink,
  sparse/all-hole, invalid-path, and clean-journal regressions.
* Retain subtree content, permissions, ownership, extended attributes,
  internal and external-primary hard links, and legacy full-export coverage.

## Validation

The preceding subtree-export checkpoint passed its focused test, full package
suite (641 tests in 84 suites), and `make check`. The selected-path, sparse export, path-resolution and clean-journal additions pass 55 focused reader tests with no skips. The proof captures the exact implementation/test bytes and restores the verification checkout clean. Coverage is retained for the four affected files: reader initialization 82.8%, export 84.4%, path I/O 95.2%, and shared errors 63.3%; these focused percentages include existing code outside this test selection. A malformed-image regression proves that both link-preserving and link-following exports reject a truncated extent-backed target, even when the surviving prefix names a valid existing file. Broader package, guest and runtime checkpoint gates remain pending. No predecessor binaries or measurements were rebuilt or rerun.

## Compatibility and risks

These APIs are additive. `export(archive:)` retains full-filesystem output, and
`export(archive:subtree:)` continues to put the selected directory's contents
at archive root. The selected-path API uses the requested final name, including
when following a final symlink, and emits standalone file data rather than an
invalid hard-link reference. `requireCleanJournal` defaults to false, so
existing reader callers are unchanged. The container service should catch
only the named recovery-required error and use its guest path in that case.

## Upstream review checklist

* Confirm that separate directory-subtree and selected-path exports provide
  clear generic `ContainerizationEXT4` semantics.
* Confirm that a selected hard link should be materialized as regular data.
* Confirm that parent links follow while final-link following is controlled by
  the explicit flag.
* Confirm no Docker- or Compose-specific behavior has leaked into the API.
* Run the focused EXT4 tests and standard formatting checks.

Related issue handoff:
`docs/ISSUE-ext4-subtree-archive-export.md`.
