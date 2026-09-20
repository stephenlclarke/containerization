# Pull request draft: prevent guest stdio backpressure from blocking other streams

## Motivation

See [the issue record](ISSUE-stdio-backpressure.md). This is an incomplete local investigation, not a release-ready change.

## Current changes

Replace synchronous destination writes with a nonblocking relay using one page of pending data. A separately registered duplicate destination descriptor preserves independent read readiness when terminal input and output share a master. Partial writes retain their exact suffix; writable readiness resumes draining. Final close drains available data without blocking the reaper, and destination hangup/error closes owned resources. Setup failures release allocated memory and owned descriptors. Writes retry `EINTR` but do not mistake `EIO` for temporary backpressure.

`TerminalIO` transfers socket ownership to successful relays so its fallback cleanup cannot truncate asynchronous output. Failed attachment closes the untransferred master; an absent stdout relay leaves master cleanup with `TerminalIO`. The caller-level failure helper is exercised directly by a regression.

Add a Linux-only Swift Testing target and an opt-in standalone component executable for static SDKs without Swift Testing. The latter uses `@testable` access and must be built in debug mode with `CONTAINERIZATION_STDIO_REGRESSION=1`; it is absent from ordinary release builds. Its default mode exercises backpressure; `--edge-cases` covers close/error/PTY behavior, and `--attachment-failure` covers the caller handoff. Every standalone process is bounded by an eight-second alarm.

## Validation and compatibility

Real Linux execution used Swift 6.3's aarch64 static Linux SDK and an isolated, journalled guest on the local MBP. This is component proof inside an unchanged released guest, not proof that the guest initializer itself has been replaced. The harness deliberately records diagnostic-only failure after its exact component assertions, with no E03 observations, so these results cannot satisfy a parity gate. Each case cleaned up all owned resources; the final recovery report is clear.

| Evidence | Result |
| --- | --- |
| Old relay binary `c50bae36d9f99ffdcd23c2d34b2d81a58b59bd94618611a37cfa810d40deba2a` | Fails nonblocking-destination check; `--transfer-only` fails unrelated-stream liveness |
| First candidate binary `a7fba278335a9320939d50cf2654ecc369e80125c5b1226b647eb181e558363e` | Exact delayed 4 MiB transfer, EOF and independent stream pass |
| Reviewed error-path candidate `4ac7ea5da52d74218be8ecc012638dfb52fe932f22894fd3398aebcce64d0a42` | Transfer still passes; first edge test incorrectly required a specific PTY write errno and failed `terminalWriteError` |
| Final caller/test candidate `0f44ae9bad308239997c1e76c67941b553bd7a8134fc2f6fa9492a6976ba6802` | Close drain, registration rollback, repeated close, shared PTY, hangup release and caller attachment cleanup pass |

The PTY test correction removed only a kernel-errno assumption; relay release remains mandatory. The final candidate changes the caller handoff and test, not the already-passing relay transfer implementation. Independent final source/test review found no actionable issues. Focused formatting uses the repository's `.swift-format-nolint` policy; `git diff --check` passes.

Retained case seals: red/green `80ea8c12a50c1cdeb76d9edd2c40632209d588ceb808e06c339519a0d13165df` / `d8188a57d752bd7df0f9b8c5285b9e5fca6b06ce6ec65df0f6ef018ec08a6248`; intermediate `d21714523e4ca719cdc10d22d4f509ebbab2cb5b53580496af42bf4d9baa0cdf` / `dba6bd68e165243cc2edb7b6290b60fbdf118ceefcb5dfecff6d3cd7aecd686b`; final `67090cfefe18b2ff81167818aae0608fcb70bdc0d2fcdb0b2557defe36dd1020` / `7ce63aeb1a6297a16cf72a1dd5850bb91eea2f06c4bbb28a77f045ec48dbddbb`. Final setup/operation/cleanup durations were 8.370754917 / 6.643411167 / 2.079778667 seconds, not quiet performance samples.

Full stock/enhanced native and Docker parity, replacement guest execution, native Linux Swift Testing, coverage, sanitizer/leak evidence and quiet comparison benchmarks remain required. The installed static SDK lacks the `Testing` module, so its attempted Swift Testing build is not a passing unit-suite result. No coverage percentage is inferred from component passes. Existing downloaded package evidence is not qualification for this branch.

## Publication

No pull request, release or Apple-side mutation has been made. This local upstream-shaped work must pass review and be integrated through the Stephen-owned fork before consumer pins change.
