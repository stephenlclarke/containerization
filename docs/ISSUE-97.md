# Issue 97: make SonarQube coverage and gates authoritative

<!-- markdownlint-disable MD013 -->

## Problem

The SonarQube workflow scans source on Linux without running the Swift tests, imports no coverage, does not record the exact source commit, and does not wait for the previous-version quality gate. Generated integration fixtures and vendored libarchive headers also distort maintained-source metrics.

## Acceptance criteria

- Generate and import real Swift package line coverage on the supported macOS toolchain.
- Verify `Previous version` policy and analyze the exact lowercase 40-character source SHA.
- Analyze pull requests and `main`, wait for the gate, and reject unresolved new issues and security hotspots.
- Classify integration fixtures as tests and exclude only generated or vendored inputs.
- Retain coverage evidence and preserve Apple runtime behavior.

GitHub issue: [#97](https://github.com/stephenlclarke/containerization/issues/97)

<!-- markdownlint-enable MD013 -->
