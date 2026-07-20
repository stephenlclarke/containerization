# Export an ext4 directory subtree as an archive

## Problem

`EXT4.EXT4Reader.export(archive:)` can export an entire ext4 filesystem, but
callers that need to materialize one directory into another filesystem must
first export the whole image and then filter it externally. That loses the
reader's existing handling for ownership, timestamps, extended attributes,
symbolic links, and hard links.

## Scope

Add a generic ext4 reader API that exports a selected directory's *contents*
at the archive root. It is a filesystem primitive: it does not interpret
Dockerfile metadata, allocate volumes, or define an orchestration policy.

## Expected behavior

- `export(archive:subtree:)` requires an existing directory.
- The selected directory itself is not added as an archive path; its children
  are rooted at the archive root.
- Existing archive metadata behavior is retained for directories, regular
  files, symbolic links, ownership, timestamps, and extended attributes.
- Hard links wholly inside the subtree remain links. When the primary name
  lives outside the selected subtree, the first selected name is emitted as a
  regular file so the archive never links to a missing target.
- The existing `export(archive:)` API retains its whole-filesystem behavior.

## Validation

- Export and unpack a selected subtree, asserting content, mode, UID/GID,
  extended attributes, and an in-subtree hard link.
- Exercise a hard link whose first discovered name is outside the subtree.
- Export the full filesystem through the existing overload to verify its
  compatibility behavior.
- Reject a non-directory selection.

## Compatibility

The new overload is additive. Existing callers of `export(archive:)` continue
to export the complete filesystem. Higher-level runtimes can use the new
primitive without importing Docker- or Compose-specific concepts.
