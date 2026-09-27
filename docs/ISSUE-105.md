<!-- markdownlint-disable MD013 -->

# VSOCK peer close remains open

The existing parallel socket integration test times out awaiting EOF in its first silent-server round. The fork retains the Virtualization connection object and its original descriptor after handing a duplicate descriptor to the caller. Closing the returned file handle leaves the original descriptor open, so the remote peer cannot observe EOF.

Acceptance is the unchanged 100-round parallel VM integration test, including silent close, bidirectional traffic, half-close and EOF assertions. Original failure evidence is retained in container-only run `20260927T153550Z/vm-integration`.

The implementation and verification are tracked in [PR-105.md](PR-105.md).
