# fix(ext4): decode little-endian values from unaligned storage

<!-- markdownlint-disable MD013 -->

## Motivation

Resolve the image-reader crash described in [the issue record](ISSUE-ext4-unaligned-load.md), discovered by the native Compose sanitizer lane.

## Implementation

Use `loadUnaligned(as:)` in both existing endian branches. Preserve the public generic signature and existing byte-order behavior; no allocation or copy is added outside the standard library's unaligned-load implementation. Add deterministic scalar regression coverage at every byte offset for 16-, 32- and 64-bit values. The patch is generic and contains no Compose policy.

## Validation

The unchanged dependency fails the equivalent focused consumer regression at Bazel invocation `421c2b24-261b-4133-b2a6-5d4f87b5bc2e`. Fixed exact-pin consumer regression and full affected TSan suite are pending. This record will be updated with the actual result before this PR is considered ready. No SwiftPM fallback, retry, sanitizer suppression or upstream stock patch is used.

## Compatibility, risks and parity

No wire format, disk format, public signature, guest image, runtime service or Docker semantics change. The raw loader continues to require enough bytes and a bitwise-copyable representation; all maintained callers load integer/EXT4 metadata types. Existing whole-buffer big-endian reversal is unchanged and is not claimed as new cross-endian support. Docker runtime parity is unaffected by this local decoding primitive, and this unit fix is not full parity evidence.

## Delivery and rollback

Branch `upstream/ext4-unaligned-load` is retained in Stephen's fork for review and generic upstream handoff. No Apple remote writes. The active Container-family build migration owns this branch/worktree; remove them after reviewed merge and consumer pin admission. Reverting the source change restores the previous loader and its known crash; consumers must not claim TSan qualification at that old pin. Next review: 18 September 2026 after native consumer validation.
