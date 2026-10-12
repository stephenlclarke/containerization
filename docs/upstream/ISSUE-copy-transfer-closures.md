# Copy transfer closures obscure cleanup and exceed the Swift quality rule

## Steps to reproduce

Analyze SDK `e4e39e2a197730d64a35b5d5116af6f3b3915c4b` with the existing Swift profile. Sonar reports 13 `swift:S3087` findings in the four `LinuxContainer.copyIn` and `copyOut` paths. The exact-source analysis is `65519d65-b9ce-42c6-9438-64b9963f504e`; its quality gate passes with 90.5% new-code coverage and zero unreviewed security hotspots, but the nested-closure findings remain open.

## Problem description

State locking, task groups, guest RPC closures, metadata callbacks and dispatched file I/O are nested together. Extract each operation at its actual boundary while preserving the state-lock span, producer error order, metadata completion, descriptor lookup timing, task-group completion and listener/port cleanup. Do not change the public copy contract, suppress the rule or discard failure evidence.

## Environment

Apple silicon macOS, Swift 6.3, current Container SDK native dependency graph and local source-bound macOS/Linux coverage. The active Swift rules permit at most two nested closures and seven explicit function parameters.

Related: [PR handoff](PR-copy-transfer-closures.md). No upstream submission is authorized by this document.
