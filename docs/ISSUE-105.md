<!-- markdownlint-disable MD013 -->

# VSOCK peer close remains open

The existing parallel socket integration test times out awaiting EOF in its first silent-server round. The fork retains the Virtualization connection object and its original descriptor after handing a duplicate descriptor to the caller. Closing the returned file handle leaves the original descriptor open, so the remote peer cannot observe EOF.

Acceptance is the unchanged 100-round parallel VM integration test, including silent close, bidirectional traffic, half-close and EOF assertions. Original failure evidence is retained in container-only run `20260927T153550Z/vm-integration`.

The descriptor implementation and later upstream runc/sysctl work are tracked in [PR-105.md](PR-105.md). At signed source `6db16197bbad8196a78132f86529daa89125aafb`, hosted Linux tests (1,014), macOS unit tests (983), and the Sonar gate passed; new-code coverage is 60/66 lines (90.9%), with no unresolved new issues or hotspots to review. Five source-matched focused runc VM cases passed with no skips and host restoration. The hosted PR workflow itself skips VM integration and image publication.

Downstream Container `db240b6c2e40ffcd10a6ff50a62f121777fc3bb5`, consuming the published C6db layers, subsequently completed its full 25-stage qualification, including 414 CLI cases plus warmup and 213/215 VM cases with two GPU skips. Its known component compatibility differences remain explicit. The [qualified Qdb240 runtime prerelease](https://github.com/stephenlclarke/container/releases/tag/layer-runtime-db240b6c2e40-f02cdf492fb4) was published, and all five assets passed authenticated download verification. These results retain their exact source identities and do not qualify a later documentation commit. This issue continues to record the original VSOCK failure and its unchanged EOF acceptance test.
