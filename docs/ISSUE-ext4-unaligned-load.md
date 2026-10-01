# EXT4 image metadata can trap on unaligned storage

<!-- markdownlint-disable MD013 -->

## Prerequisites and scope

Read-only upstream inspection on 18 September 2026 confirms the aligned loads remain at Apple main `ecd9a29f9799ec13d2662d018e00e29c89d66a15` and Stephen main `51bf8a10e2036861f87ccdf2fd881a8726c534d2`. An upstream issue search for `unaligned` found no matching fix. This work is confined to Stephen's fork; no Apple submission is authorized during the active programme.

## Steps to reproduce

Load little-endian image metadata from a raw buffer whose starting address is not a multiple of the value's alignment. The deterministic regression allocates eight-byte-aligned storage and probes each offset from zero through seven. Existing Compose image-volume initialization also reaches this path through `Data.InlineData` and `EXT4Reader.decodeExtents`.

## Current behavior

The helper uses `UnsafeRawBufferPointer.load(as:)`, which traps with `Fatal error: load from misaligned raw pointer`. A real enhanced Compose thread-sanitizer run first exposed this in the empty-volume/default-journal test. A focused ordinary native Bazel regression also fails against the unchanged dependency: invocation `421c2b24-261b-4133-b2a6-5d4f87b5bc2e`, 8.289 seconds build/test elapsed. This is not a timing benchmark or a sanitizer-only defect.

## Expected behavior

Valid image bytes decode identically at any byte alignment without adding an alignment requirement to callers. Keep the existing generic API, byte count requirements and endian policy.

## Environment and evidence

Local Apple Silicon MBP, Xcode 27 toolchain; exact host/toolchain details and failing test logs are retained by the shared Bazel launcher. The original full TSan failure is `b08f099d-e6c7-4c29-bd3b-f62876974400`. Private crash diagnostics remain in the internal retained `workflow/compose-tsan-20260918` folder; they are not published because they contain host paths.

Owner: active Container-family Bazel migration. Terminal condition: focused regression and affected consumer suite pass with the fix and the fork PR is reviewed. Stock Apple remains separately pinned and is not silently patched.
