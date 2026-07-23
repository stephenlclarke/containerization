# Pull request handoff: sync Apple's indexed EXT4 file tree

## Proposed pull request

`chore(upstream): merge apple containerization main`

This handoff covers the signed reconciliation merge
[`0fac7775ab074d656464e7957b6380fa06abf3e7`](https://github.com/stephenlclarke/containerization/commit/0fac7775ab074d656464e7957b6380fa06abf3e7).

## Summary

Consume Apple's constant-time EXT4 child lookup while preserving the fork's
archive-relative subtree export traversal.

## Apple-shaped boundary

- Includes Apple commit `450d44e` without modifying its ordered-index
  implementation.
- Resolves one textual conflict in the fork-owned subtree export overload.
- Keeps the public complete-filesystem export delegating to the subtree path.
- Adds no abstraction, dependency, or behavior beyond the upstream
  `OrderedCollections` dependency.

## Code map

- `Package.swift`
  - adopts Apple's explicit `OrderedCollections` product dependency.
- `Sources/ContainerizationEXT4/EXT4+FileTree.swift`
  - uses Apple's insertion-ordered name index and direct lookup.
- `Sources/ContainerizationEXT4/EXT4+Formatter.swift`
  - mutates children through the indexed helpers.
- `Sources/ContainerizationEXT4/EXT4+Reader.swift`
  - consumes the ordered child values.
- `Sources/ContainerizationEXT4/EXT4Reader+Export.swift`
  - retains the selected source node and archive-relative tuple traversal.
- `Tests/ContainerizationEXT4Tests/TestEXT4Reader+IO.swift`
  - adopts Apple's indexed child mutation helpers.

## Validation on macOS

```console
make check
make coverage
```

Results:

- Formatting and license gates passed.
- Full unit and coverage run: 647 tests in 85 suites passed.
- Coverage report generated successfully.
- Subtree export and hard-link coverage remained green.

## Compatibility and risks

`children` changes from a mutable array to insertion-ordered dictionary values,
but the collection is internal to the EXT4 implementation. All mutations use
Apple's `addChild` and `removeChild` helpers.

The only merge choice retains the existing subtree traversal origin and
archive-relative path. It still consumes children in insertion order, so the
performance fix and deterministic archive behavior are both preserved.

## PR template

### Type of change

- [x] Upstream synchronization
- [x] Performance fix
- [x] Conflict reconciliation
- [x] Documentation update
- [ ] Public API change
- [ ] Breaking change

### Motivation and context

Keep the fork current with Apple's fix for quadratic EXT4 directory unpacking
without regressing selected-directory archive export.

### Testing

- [x] Formatting passed
- [x] License validation passed
- [x] Full unit suite passed
- [x] Coverage run passed
- [x] Subtree export regression passed

Related issue handoff:
`docs/ISSUE-ext4-file-tree-index-sync-20260723.md`.
