# Upstream handoff: export ext4 directory subtrees as archives

## Proposed pull request

`feat(ext4): add subtree archive export`

This handoff covers the Apple-shaped code commit
`b91f20f717439c26d51ae13ad7b172cf86cbabb2`.

## Summary

Add `EXT4.EXT4Reader.export(archive:subtree:)`, an additive primitive that
exports a selected ext4 directory's contents at archive root while retaining
the reader's established archive metadata behavior.

## Motivation and context

Container runtimes sometimes need to materialize one image filesystem
directory into an independently managed filesystem. The existing reader can
export only a complete ext4 filesystem, requiring every caller to reimplement
archive filtering and risking loss of metadata or invalid hard-link targets.

The proposed API makes that operation a generic ext4 capability. It contains
no Docker image parsing, volume lifecycle policy, or Compose model handling.

## Implementation

### Code map

`Sources/ContainerizationEXT4/EXT4Reader+Export.swift`

* Makes `export(archive:)` a compatibility wrapper over the new subtree API.
* Adds `export(archive:subtree:)`, rooted at the selected directory's
  children.
* Keeps the existing PAX/xattr archive behavior for every supported node.
* Retains hard links inside the exported tree, and materializes a regular file
  when the corresponding primary hard-link target is outside the tree.

`Tests/ContainerizationEXT4Tests/TestEXT4ReaderExport.swift`

* Covers content, permissions, ownership, extended attributes, hard links,
  external-primary hard links, and legacy whole-filesystem export.
* Covers rejection of a non-directory source.

## Validation on macOS

```console
swift test --filter EXT4ReaderExportTests
swift test
make check
```

All commands passed locally. The full package suite passed 641 tests in 84
suites.

## Compatibility and risks

This is an additive API; `export(archive:)` retains its full-filesystem output.
The destination directory is deliberately represented by archive root rather
than by an extra top-level component, which makes the archive suitable for
direct materialization into another filesystem. A hard-link target outside the
selection is converted to a regular-file entry, preventing an invalid archive
reference while preserving the selected file's data and metadata.

## Upstream review checklist

* Confirm that rooted directory-content export is the appropriate generic
  `ContainerizationEXT4` abstraction.
* Confirm the external-primary hard-link fallback is preferred to emitting an
  archive link to a missing path.
* Confirm no Docker- or Compose-specific behavior has leaked into the API.
* Run the standard macOS unit and formatting checks.

Related issue handoff:
`docs/ISSUE-ext4-subtree-archive-export.md`.
