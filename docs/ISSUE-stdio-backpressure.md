# Issue: guest stdio must not block the shared process supervisor

## Problem

An enhanced released native Container CLI transfers a 4 MiB input through `exec -i ... cat` when stdout is consumed immediately, but a 250 ms pause before consuming stdout leaves the transfer incomplete at its unchanged 20-second deadline. This reproduces outside devcontainer's transfer path. It is diagnostic evidence, not proof of the precise source-level cause or a benchmark.

The real Linux component reproduction confirms an `IOPair` defect: it registers only its source with `Epoll`, which makes only that descriptor nonblocking. Its callback writes to the destination synchronously on the single `ProcessSupervisor` event thread. Filling a destination prevents an unrelated relay from delivering its marker. The old implementation fails this test; the candidate keeps that stream responsive and delivers the delayed 4 MiB payload exactly, with EOF. The old code is unchanged between the admitted enhanced guest revision `7e066a3101bc84fa0f7231daf6a03aa9ef62a567` and upstream baseline `d29e00a`. This does not yet prove the full native/parity failure is resolved.

## Required behavior

Keep relay memory bounded, retain every partial write, resume after destination backpressure clears, propagate EOF only after queued bytes, and keep unrelated stdio streams responsive. Terminal input and output can share a file description; their readiness handlers must not overwrite each other. Close and failed registration must release only owned descriptors without recursive mutex acquisition.

## Verification

The standalone component tests execute the real `IOPair`, `ProcessSupervisor` and Linux epoll, not a fake. Verified cases include nonblocking destination, unrelated-stream responsiveness, delayed 4 MiB transfer with exact bytes and EOF, close while output is full, duplicate/registration failure cleanup, repeated close and unrelated descriptor preservation, shared PTY read/write, PTY hangup release and failed `TerminalIO` attachment ownership. See [the PR evidence](PR-stdio-backpressure.md) for immutable binary hashes and retained case seals.

Actual guest replacement, original E03/E07/native reproductions, native Linux Swift Testing, instrumented coverage, leak/sanitizer checks and full stock/enhanced/Docker qualification remain outstanding. No release or benchmark improvement is claimed.

## Ownership and publication

Owner: Container-family release task. Local branch `upstream/stdio-backpressure` is isolated from existing worktrees. It will be incorporated through a Stephen-owned pull request after validation; no Apple publication is authorized at this stage. Remove this worktree after accepted integration and preservation of the upstream-ready patch. Next review: completion of the focused relay tests.
