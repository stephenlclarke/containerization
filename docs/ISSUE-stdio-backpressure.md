# Issue: guest stdio must not block the shared process supervisor

## Problem

An enhanced released native Container CLI transfers a 4 MiB input through `exec -i ... cat` when stdout is consumed immediately, but a 250 ms pause before consuming stdout leaves the transfer incomplete at its unchanged 20-second deadline. This reproduces outside devcontainer's transfer path. It is diagnostic evidence, not proof of the precise source-level cause or a benchmark.

The real Linux component reproduction confirms an `IOPair` defect: it registers only its source with `Epoll`, which makes only that descriptor nonblocking. Its callback writes to the destination synchronously on the single `ProcessSupervisor` event thread. Filling a destination prevents an unrelated relay from delivering its marker. The old implementation fails this test; the candidate keeps that stream responsive and delivers the delayed 4 MiB payload exactly, with EOF. The old code is unchanged between the admitted enhanced guest revision `7e066a3101bc84fa0f7231daf6a03aa9ef62a567` and upstream baseline `d29e00a`. This does not yet prove the full native/parity failure is resolved.

## Required behavior

Keep relay memory bounded, retain every partial write, resume after destination backpressure clears, propagate EOF only after queued bytes, and keep unrelated stdio streams responsive. Terminal input and output can share a file description; their readiness handlers must not overwrite each other. Close and failed registration must release only owned descriptors without recursive mutex acquisition.

## Verification

The standalone component tests execute the real `IOPair`, `ProcessSupervisor` and Linux epoll, not a fake. Verified cases include nonblocking destination, unrelated-stream responsiveness, delayed 4 MiB transfer with exact bytes and EOF, close while output is full, duplicate/registration failure cleanup, repeated close and unrelated descriptor preservation, shared PTY read/write, PTY hangup release and failed `TerminalIO` attachment ownership. See [the PR evidence](PR-104.md) for immutable binary hashes, actual replacement-guest E03 proof and retained case seals.

The replacement guest passes all six original E03 assertions. E07 transfers substantially more framed data but still waits for EOF; a separate host stdin policy correction is under Container PR 288 and combined qualification remains open. Native Linux Swift Testing, instrumented coverage, leak/sanitizer checks and full stock/enhanced/Docker qualification remain outstanding. Sonar's reported new-code coverage is zero and its gate fails; component execution is not a coverage report. No release or benchmark improvement is claimed.

## Ownership and publication

Owner: Container-family release task. Stephen's active branch `fix/stdio-backpressure` is under draft PR 104; local `upstream/stdio-backpressure` preserves the generic Apple-shaped patch. Both are isolated from other worktrees. No Apple publication is authorized at this stage. Remove the active worktree after accepted integration and preservation of the upstream-ready patch. Next review: combined host/guest E07 proof and real Linux coverage, before main promotion.
