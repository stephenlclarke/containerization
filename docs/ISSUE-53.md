# Issue 53: synchronize Apple fixes and the release TLS dependency

## Problem

The fork was behind Apple main for two fixes required by the 0.14.0 matched
stack. Apple pull request 856 corrects external-journal efsck handling, and
Apple pull request 851 enters the container IPC namespace for exec.

The release graph also selects the reviewed
`stephenlclarke/swift-nio-ssl` fork because its optional-certificate and
certificate-refresh fixes are not in the Apple dependency revision. Leaving
Containerization on the Apple URL gives standalone Containerization builds a
different TLS implementation from the matched release root and creates
another duplicate package-identity edge when the full stack resolves.

## Requested outcome

- Integrate exact Apple commits `db615ca` and `4294c0f` without dropping fork behavior.
- Preserve the fork's private user and network namespace entry while adding
  the Apple IPC entry.
- Pin SwiftNIO SSL revision
  `09c5c9adcdd2a459187e45fe0143eb01063f244a` from the reviewed support fork.
- Run focused EXT4, vmexec, TLS dependency, formatting, and exact-head review gates.
- Merge through a signed pull request before Compose pins the immutable
  release graph.

## Related work

- [Containerization issue 53](https://github.com/stephenlclarke/containerization/issues/53)
- [Apple Containerization pull request 851](https://github.com/apple/containerization/pull/851)
- [Apple Containerization pull request 856](https://github.com/apple/containerization/pull/856)
- [SwiftNIO SSL pull request 2](https://github.com/stephenlclarke/swift-nio-ssl/pull/2)
- [Container release integration pull request 169](https://github.com/stephenlclarke/container/pull/169)
- [Container Compose release pull request 333](https://github.com/stephenlclarke/container-compose/pull/333)
