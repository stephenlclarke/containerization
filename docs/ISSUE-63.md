# Issue 63: sync Apple upstream before the 0.14.1 stack release

## Problem

The Container Compose 0.14.1 release preflight found the support fork three
commits behind Apple `containerization` main. Stable stack publication requires
the support forks to contain current upstream history.

## Scope

- Merge Apple main without rewriting fork history.
- Retain the fork's runtime and release behavior.
- Verify the newly introduced CIDR and NBD argument surfaces with focused tests.
- Publish the exact merged revision for the matched 0.14.1 stack.

## Acceptance evidence

- `git rev-list --left-right --count upstream/main...HEAD` reports zero behind.
- The merge commit is signed.
- `swift test --filter 'TestCIDR|BlockArgumentTests'` passes all focused cases.
- Pull request [#64](https://github.com/stephenlclarke/containerization/pull/64)
  receives an exact-head review and green required checks before merge.
