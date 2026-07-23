# Reconcile Apple's indexed EXT4 file tree with subtree export

## Context

Apple Containerization commit
[`450d44e`](https://github.com/apple/containerization/commit/450d44e)
replaces linear child scans in the EXT4 file tree with an insertion-ordered
name index. The change fixes quadratic behavior while unpacking directories
with many entries.

The fork also carries directory-subtree export. Its export traversal builds
archive-relative paths from a selected source node, so the upstream root-only
traversal line conflicts even though both implementations can consume the new
ordered child collection.

## Required behavior

- Adopt Apple's ordered child index and constant-time name lookup unchanged.
- Preserve deterministic insertion order for formatting, reading, and export.
- Keep full-filesystem and selected-directory export behavior.
- Resolve the conflict only at the traversal initialization boundary.

## Resolution

The signed merge commit
[`0fac7775ab074d656464e7957b6380fa06abf3e7`](https://github.com/stephenlclarke/containerization/commit/0fac7775ab074d656464e7957b6380fa06abf3e7)
includes Apple commit `450d44e`. It retains the subtree-aware tuple traversal
in `EXT4Reader+Export.swift`; the tuple now iterates the ordered values exposed
by Apple's indexed file tree. No upstream indexing code was rewritten.

## Validation

```console
make check
make coverage
```

Observed on Apple silicon macOS:

- Formatting and license checks passed.
- All 647 tests in 85 suites passed.
- Coverage reporting completed successfully.
- The selected-directory export regression passed.
- Apple's large-directory and file-tree reader tests passed in the full suite.

## Commit tracking

- Apple performance fix: `450d44e`.
- Signed reconciliation merge:
  `0fac7775ab074d656464e7957b6380fa06abf3e7`.
