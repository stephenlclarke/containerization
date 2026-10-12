# perf(runtime): measure VM and stopped-copy startup phases

<!-- markdownlint-disable MD013 -->

## Motivation and changes

The stopped-copy path still spends most of its time bootstrapping a VM. Add debug timing records around mount preparation, VMM construction, VM startup, guest setup and state commit. The VZ startup breakdown separates prestart, Virtualization.framework start, agent socket readiness, agent initialization, Rosetta setup and time synchronization. Guest setup separates standard setup, filesystem mounts, socket relays, networking and resolver files.

Use `ContinuousClock` for elapsed durations, report integer microseconds, and retain the unfinished phase and failure outcome. Separate explicit cleanup under `failure-cleanup`, preserving `failed-phase`. The VZ and guest records are nested breakdowns of the outer creation spans; do not sum them into the parent total.

## Validation

Four deterministic timing tests cover non-overlapping phases and totals, first-phase failure, cleanup attribution, whole seconds and sub-microsecond precision. All 75 expanded timing and LinuxContainer lifecycle tests passed locally with the existing instrumented candidate cache, and host restoration passed. Focused execution and runtime diagnostics are retained separately; instrumentation alone is not optimization or performance qualification. An independent review found no actionable source issue.

## Compatibility and risks

No public API, guest protocol, lifecycle, mount, timeout, retry or filesystem policy changes. Logs contain phase names, outcome, durations and the existing container identity; no file paths, content, environment or credential material are added. Startup now performs a bounded number of clock reads and constructs debug metadata when logging evaluates the message. LinuxContainer can report these spans with either VMM backend. Current guest artifacts and published baseline binaries/results are reused unchanged.

See [the issue handoff](ISSUE-stopped-copy-startup-timings.md). The next runtime capture must establish the dominant phase before changing the measured path.

The first retained diagnostic VM trial passed its functional copy assertion but correctly failed diagnostic acceptance because the integration fixture supplied no logger. The integration VMM and selected copy fixture now receive the suite debug logger, allowing the existing opt-in startup records to be captured without changing production defaults. The failed raw run and complete host/binary restoration remain retained.

Five successful diagnostic trials attribute a median 400.582 ms of 415.893 ms container creation to VM start (about 96%), while guest setup takes 7.806 ms (under 2%). Two additional integration fixtures reuse the same copy correctness assertions with explicit 4-vCPU/512-MiB and 1-vCPU/1024-MiB VM resources to isolate memory reduction from CPU reduction and test whether bounded copy-only resources reduce that cost. These are diagnostic candidates, not production policy or release qualification; the original 4-vCPU/1024-MiB fixture and all production resource defaults remain unchanged.
