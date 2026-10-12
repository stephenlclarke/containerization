# Export selected ext4 paths and directory subtrees as archives

## Problem

`EXT4.EXT4Reader.export(archive:)` can export an entire ext4 filesystem, but
callers that need to materialize one directory into another filesystem must
first export the whole image and then filter it externally. That loses the
reader's existing handling for ownership, timestamps, extended attributes,
symbolic links, and hard links. Callers that need one regular file or symbolic
link also lack a reader API that retains the requested basename, follows only
the requested final link, and streams regular-file bytes without buffering the
whole file.

## Scope

Add generic ext4 reader APIs for exporting a selected directory's *contents* at
archive root and for exporting one selected regular file or symbolic link as a
single archive member. They are filesystem primitives: they do not interpret
Docker metadata, allocate volumes, or define an orchestration policy.

## Expected behavior

- `export(archive:subtree:)` requires an existing directory.
- The selected directory itself is not added as an archive path; its children
  are rooted at the archive root.
- `export(archive:selectedPath:followSymlink:)` emits one regular file or
  symbolic link using the selected path's final component as its archive name.
  Parent symlinks are resolved, while following the final symlink is explicit.
- Selected hard links are emitted as standalone regular files so the archive
  does not refer to a primary name outside the one-member selection.
- Regular-file content is streamed in bounded chunks, with sparse holes and
  unwritten extents represented in the archive when present.
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
- Export one regular file, relative/absolute/dangling symlinks, an optionally
  followed target, and a selected hard link; verify archive names and metadata.
- Export sparse and all-hole files and verify exact logical bytes.
- Reject a root, directory, missing path, and a recovery-marked superblock
  before traversing its group descriptors when clean-journal mode is required.

## Compatibility

The overloads are additive. Existing callers of `export(archive:)` continue to
export the complete filesystem, and `export(archive:subtree:)` retains its
directory-contents behavior. Higher-level runtimes can use the selected-path
primitive without importing Docker- or Compose-specific concepts. The optional
clean-journal initializer check is disabled by default for compatibility.
