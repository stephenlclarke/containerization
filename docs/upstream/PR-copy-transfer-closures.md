# refactor(copy): separate transfer operations from coordination

## Type of Change

- [x] Refactor
- [x] Documentation update

## Motivation and Context

Thirteen nested-closure findings remain in the current copy-transfer implementation. Private guest producers, first-element stream readers and dispatched transfer helpers separate those operations from the existing lock and task-group coordination. Private request values keep RPC helper signatures within the active seven-parameter rule.

Public APIs and transfer behavior stay unchanged. Producer error storage, metadata completion, descriptor closing, listener shutdown and port release retain their order. Streamed-copy file descriptors are read inside the dispatched operation, matching the previous lookup timing.

## Testing

- [x] Retained exact-source Sonar findings and the active Swift rule parameters.
- [ ] Immutable source compilation and focused copy-state tests.
- [ ] Current-source macOS/Linux coverage and zero-finding Sonar analysis.
- [ ] Repaired SDK native/guest publication and VM copy regression.

Historical releases, binaries, benchmarks and failures remain immutable. This refactor does not claim a performance improvement. The changed source requires new candidate provenance and downstream SDK admission; existing artifacts must not be relabeled. Root owns final immutable validation and publication.

Related: [issue handoff](ISSUE-copy-transfer-closures.md). No Apple or grpc submission is performed.
