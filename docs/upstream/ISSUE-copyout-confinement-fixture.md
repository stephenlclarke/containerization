# Copy-out confinement fixture reads a preserved symlink as a regular file

## Steps to reproduce

Run the complete SDK VM integration suite at `5b42fca0850b416d469de36b47bf5484385dabe0`. `testCopyOutDoesNotEscapeRootfsViaSymlink` plants `/tmp/leak -> /target`, calls `copyOut` without `followSymlink`, then tries to read the host destination as UTF-8.

## Problem description

The current documented default preserves a standalone symlink. The failing destination is in fact a symlink whose exact target is `/target`; reading it on the host fails because the host target is absent. This is the intended default result, not a failed transfer or permission problem. The fixture predates standalone-link preservation and no longer requests the dereference behavior that its content assertion intends to test.

Assert the default copied link target first. Then explicitly set `followSymlink: true`, copy into a separate fresh host path and require `CONTAINED`. This preserves the security assertion that dereferencing stays inside the container root filesystem, while also checking default link preservation. Do not dereference the preserved destination on the host or weaken production copy behavior.

## Environment

- Local Apple silicon macOS, Bazel 8.8.0 and qualified native lower archives.
- SDK `5b42fca0850b416d469de36b47bf5484385dabe0`, matching rebuilt guest, pinned runc v1.5.1 and retained kernel fingerprint.
- Complete VM attempt: 212 passed, two named unsupported graphics skips, this one failure. Raw evidence and restored host state remain retained under the performance goal's `candidate-sdk-unaligned/vm-v4`.

No external issue is submitted. Related: [PR handoff](PR-copyout-confinement-fixture.md).
