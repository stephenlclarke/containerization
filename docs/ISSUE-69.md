# Issue 69: serialize VM-backed cctl NBD integration coverage

## Problem

Apple pull request
[#903](https://github.com/apple/containerization/pull/903) added end-to-end
`cctl --block` integration coverage. Fork issue
[#65](https://github.com/stephenlclarke/containerization/issues/65) and pull
request [#66](https://github.com/stephenlclarke/containerization/pull/66)
serialized the two-VM persistence case after it exposed a reproducible
Virtualization.framework scheduling failure.

The 0.14.1 release gate subsequently showed that the one-VM mount and raw cases
have the same boundary. Both completed their guest commands and emitted their
expected output before Virtualization.framework stopped their VMs unexpectedly
during concurrent teardown. The already-exclusive persistence case passed in
the same run.

## Scope

- Route all three VM-backed `cctl --block` cases through the integration
  suite's existing exclusive-execution lane.
- Keep the malformed-spec case concurrent because it fails validation before
  booting a VM.
- Preserve every NBD assertion and all production behavior unchanged.
- Prepare an Apple-shaped upstream handoff tied to the originating pull
  request.

## Acceptance evidence

- Before the change, the release gate completed with 181/185 passed and two
  skipped; the mount and raw cases were the only failures.
- Both failures occurred after their expected guest output and reported
  `VZErrorDomain Code=1` during concurrent teardown.
- The already-exclusive format-and-persist case passed immediately afterward.
- After the change, the filtered four-case `cctl block` group passes with
  default concurrency in 6.73 seconds. The validation-only case runs first in
  the concurrent lane, followed by all three VM-backed cases sequentially in
  the exclusive lane.

Related issue: [#69](https://github.com/stephenlclarke/containerization/issues/69).
