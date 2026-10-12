# test(copy): distinguish preserved links from confined following

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

The VM copy-out confinement fixture used the default `followSymlink: false` call but expected regular-file contents. The retained failure proves the host destination is the correctly preserved `/target` symlink. Reading that link as a file fails on a host without `/target`.

The fixture now requires the default copied link target to equal `/target`, then explicitly follows the guest link into a separate fresh host destination and requires the container's `CONTAINED` contents. The second destination prevents the host from following the previously preserved absolute link. Root-filesystem confinement remains mandatory; no production source, public API, wire behavior or timing acceptance changes.

## Testing

- [x] Retained original full-VM failure and direct host link inspection establish the stale fixture expectation.
- [x] README and matching issue handoff updated.
- [ ] Focused VM regression against the changed immutable SDK source.
- [ ] Coherent native/guest qualification and downstream admission for the changed source revision.

The prior repaired SDK release and all historical benchmark artifacts stay immutable. New candidate provenance must name the changed source even though the production implementation is unchanged. Do not relabel existing native or guest artifacts as this source. Instrumented production coverage remains valid for its original source; no new overall coverage claim follows from a fixture-only edit.

Related: [issue handoff](ISSUE-copyout-confinement-fixture.md). No Apple/grpc publication is performed.
