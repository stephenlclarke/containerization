# Issue 72: serialize VM-backed cctl run integration coverage

## Problem

Apple pull request
[#906](https://github.com/apple/containerization/pull/906) added five end-to-end
`cctl run` command-resolution cases. The 0.14.2 Container Compose release gate
showed that these subprocess-backed cases are not safe to overlap on one macOS
host. They share the cctl application image store and create independent
vmnet-backed Virtualization.framework VMs.

The commands produced their expected guest output before
Virtualization.framework stopped one or more VMs unexpectedly during concurrent
teardown. This is the same host-level scheduling boundary established for the
VM-backed `cctl --block` coverage in fork issue
[#69](https://github.com/stephenlclarke/containerization/issues/69) and pull
request [#70](https://github.com/stephenlclarke/containerization/pull/70).

## Scope

- Route all five VM-backed `cctl run` cases through the integration suite's
  existing exclusive-execution lane.
- Preserve the command-resolution implementation and every assertion from
  Apple pull request #906.
- Keep the correction limited to integration scheduling; do not change cctl or
  Containerization runtime behavior.
- Prepare an Apple-shaped upstream handoff tied to the originating pull
  request.

## Acceptance evidence

- Before the change, the full release suite passed 187/190 cases and skipped
  two. `cctl run entrypoint override keeps image cmd` printed `/bin/sh` and
  then failed with `VZErrorDomain Code=1`.
- A focused five-case run at the normal maximum concurrency of four passed
  3/5. Both entrypoint-override cases produced their expected output before
  failing during VM shutdown.
- The same five cases passed 5/5 with maximum concurrency one.
- The individually filtered failing case passed 1/1 with maximum concurrency
  four because only one VM was active.
- After the change, the focused five-case group passes 5/5 when the harness is
  invoked with maximum concurrency four; the exclusive lane executes the VMs
  sequentially.

Related issue: [#72](https://github.com/stephenlclarke/containerization/issues/72).
