# Diagnose stopped-container copy startup cost

<!-- markdownlint-disable MD013 -->

## Reproduction and current behavior

Copy a small file into a created or stopped dedicated Container VM using the retained stopped-copy fixtures. Current native Container supports the operation without starting the workload, but the operation must boot the guest to write its EXT4 root filesystem. Retained API-service timings attribute roughly 90% of latency to runtime bootstrap and do not separate VM startup, guest-agent readiness, and guest filesystem setup. Existing published baseline measurements remain immutable.

## Expected behavior

Record non-overlapping monotonic phases at the VMM and guest-setup boundaries so optimization targets the dominant cost. Include the unfinished phase on failure and separate cleanup from the failed operation. Do not change filesystem semantics, lifecycle state, retries, timeouts or workload execution to improve a measurement.

## Environment and evidence

The diagnostic candidate starts from SDK `518f92a006c94c55e21422f3cf2f93c2f039d053`, using the local MBP and the existing guest and kernel artifacts. Focused source tests and the next candidate runtime capture are retained under `ContainerFamily/retained/workflow/performance-parity-20261011T150042Z/candidate-container-startup-timings`. This local handoff does not create an upstream submission or claim a measured speedup.

The first retained diagnostic VM trial passed its functional copy assertion but correctly failed diagnostic acceptance because the integration fixture supplied no logger. The integration VMM and selected copy fixture now receive the suite debug logger, allowing the existing opt-in startup records to be captured without changing production defaults. The failed raw run and complete host/binary restoration remain retained.

Five successful diagnostic trials attribute a median 400.582 ms of 415.893 ms container creation to VM start (about 96%), while guest setup takes 7.806 ms (under 2%). Two additional integration fixtures reuse the same copy correctness assertions with explicit 4-vCPU/512-MiB and 1-vCPU/1024-MiB VM resources to isolate memory reduction from CPU reduction and test whether bounded copy-only resources reduce that cost. These are diagnostic candidates, not production policy or release qualification; the original 4-vCPU/1024-MiB fixture and all production resource defaults remain unchanged.
