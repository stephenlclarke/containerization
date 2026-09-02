# Issue 65: serialize write-heavy cctl NBD persistence coverage

## Problem

Apple pull request
[#903](https://github.com/apple/containerization/pull/903) added end-to-end
`cctl --block` integration coverage. The two-VM
`cctl block NBD format and persist` case passes in isolation, but fails
reproducibly when the four new cctl block cases run concurrently: the first VM
successfully formats the export and reads its UUID before
Virtualization.framework reports that the VM stopped unexpectedly during
teardown.

## Scope

- Route only the write-heavy, two-VM persistence case through the integration
  suite's existing exclusive-execution lane.
- Preserve concurrent execution for the other cctl block checks and the rest
  of the suite.
- Retain the upstream test's format-and-reopen assertions unchanged.
- Prepare an Apple-shaped upstream handoff tied to the originating pull request.

## Acceptance evidence

- Before the change, the full suite completes with 181/184 passed and 2 skipped;
  the NBD format/persist case is the sole failure.
- Before the change, the four cctl block cases complete with 3/4 passed; the
  same case is the sole failure.
- In isolation, the affected case passes 1/1 in 2.98 seconds.
- After scheduling the affected case exclusively, the cctl block group passes
  4/4 and the full suite passes 182/184 with the same two expected skips.

Related issue: [#65](https://github.com/stephenlclarke/containerization/issues/65).
