# Issue 67: sync Apple stdio and logging updates before 0.14.1

## Problem

The Container Compose 0.14.1 release preflight found the support fork two
commits behind Apple `containerization` main. Stable stack publication requires
the support forks to contain current upstream history.

## Scope

- Merge Apple main without rewriting fork history.
- Adopt the reusable stdio vsock pool and `ContainerManager` logger routing.
- Preserve the fork's pre-bound DNS host-service port, configured OCI runtime
  path, and existing lifecycle, memory-reclamation, and hotplug behavior.
- Publish the exact merged revision for the matched 0.14.1 stack.

## Acceptance evidence

- `git rev-list --left-right --count upstream/main...HEAD` reports zero behind.
- The merge commit is signed.
- `make check` and `git diff --check` pass.
- Linux stdio-slot and port-allocator coverage plus the repository checks pass
  on pull request [#68](https://github.com/stephenlclarke/containerization/pull/68).
- Pull request #68 receives an exact-head review before merge.

