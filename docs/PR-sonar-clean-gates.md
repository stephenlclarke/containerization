# Pull request: make Containerization SonarQube authoritative

<!-- markdownlint-disable MD013 -->

## Summary

- Export the instrumented Swift package suite as project-confined LCOV and SonarQube generic coverage XML.
- Verify the project-level previous-version policy, label analyses with the exact checked-out commit, and wait for the quality gate.
- Reject unresolved new issues and security hotspots on pull requests and `main`.
- Keep generated integration fixtures in the test domain and exclude vendored libarchive headers from first-party metrics.

See [issue 97](https://github.com/stephenlclarke/containerization/issues/97) and its [repository handoff](ISSUE-97.md).

## Validation

- [x] Coverage converter unit tests and Python compilation
- [x] GitHub Actions workflow validation
- [x] Markdown and source diff validation
- [ ] Xcode 26.6 instrumented package suite
- [ ] Exact-head SonarQube pull-request analysis
- [ ] Exact merged-main SonarQube analysis

Local Apple-toolchain validation remains unavailable until the host's Xcode 27 licence is explicitly accepted. The authoritative hosted workflow uses Xcode 26.6 and must supply the remaining evidence before merge.

## Compatibility and risk

Runtime behavior is unchanged. The source/test classification affects analysis only, and exclusions are restricted to generated Swift, generated integration fixtures, and the repository's vendored libarchive headers.

## Upstream relationship

This is Stephen-fork quality policy. It changes no Apple runtime behavior and does not push to an Apple remote.

Closes [#97](https://github.com/stephenlclarke/containerization/issues/97).

<!-- markdownlint-enable MD013 -->
