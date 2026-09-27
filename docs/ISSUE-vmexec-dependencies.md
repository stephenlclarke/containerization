<!-- markdownlint-disable MD013 -->
# Reduce vmexec dependencies

## Problem

Every container start and exec launches vmexec. Its package depends on the full Containerization and VminitdCore products merely to use workload network data and namespace-entry flags. This links guest server code into the helper and makes server changes invalidate the helper's build.

## Expected behavior

Use the existing OS and Netlink libraries for shared contracts, retain source compatibility for existing clients, and link the existing Cgroup and LCShim targets without importing the guest server.

## Evidence and scope

The optimized ARM64 helper is 88,341,440 bytes before this change and 73,935,808 bytes afterward, a 16.3% reduction. Alternating nine-trial runs show essentially unchanged startup and exec latency. This is a binary-size and dependency-boundary improvement; it does not claim to close the remaining VM startup gap. No remote issue has been opened.
