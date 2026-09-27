<!-- markdownlint-disable MD013 -->

# fix(virtualization): close original VSOCK descriptors after handoff

Restore Apple's explicit close of the original accepted descriptor after duplicating it, and apply the same ownership transfer when dialing. The fork still retains the connection object for descriptor handoff; the original descriptor no longer keeps the peer open after the caller closes its file handle.

Validation uses existing connection-owner unit tests and the unchanged native parallel-traffic regression. Related issue: [VSOCK descriptor close](ISSUE-vsock-descriptor-close.md). No test deadlines or EOF assertions are changed.
