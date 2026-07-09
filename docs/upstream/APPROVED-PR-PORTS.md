# Approved upstream PR ports

This fork carries the approved upstream changes below so the Stephen-owned container stack can release against them before Apple merges and publishes equivalent commits. These notes are for future upstream submission or removal when the Apple changes land. Do not push these commits to Apple from this fork.

## apple/containerization#753: send registry User-Agent

- Upstream PR: <https://github.com/apple/containerization/pull/753>
- Local status: ported as approved.
- Behavior: `RegistryClient` now builds requests with a default `User-Agent` from `clientID`, while preserving caller override support and avoiding duplicate `User-Agent` headers.
- Validation: `swift test --filter RegistryRequestHeaderTests -Xswiftc -warnings-as-errors` covers the default value, a custom client ID, caller override behavior, and coexistence with other headers.
