# Update the fork to Apple main

## Steps to reproduce

Build the fork at `7b9eb0a77ff615d764fbbf52125e2b6cdd846db8` against
current Apple interfaces.

## Current behavior

The fork is based on an older Apple revision. Current Apple changes affect VM sizing,
OCI runtime setup, filesystem operations, archives and guest memory safety.
Some overlapping changes need to be combined with the fork's workload namespaces.

## Expected behavior

Base the fork on Apple `7723232d1832e059f2a092bc3377f844ec7b3803`.
Retain the fork's workload, resource and filesystem features with regression tests.
Keep the package exclusion fix already merged in apple/containerization#798.

## Environment and scope

Apple Silicon macOS; Swift 6.3 and 6.4; official ARM64 Swift Linux images.
This is a fork integration change. It does not publish a new Apple PR.
See [the PR handoff](PR-upstream-sync-20261112.md).
