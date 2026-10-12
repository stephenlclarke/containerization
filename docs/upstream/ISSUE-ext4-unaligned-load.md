# EXT4 metadata loads trap on unaligned image bytes

## Steps to reproduce

At SDK source `d428b16f5f4d2024579785779b63560926354428`, allocate a raw buffer aligned to eight bytes, advance its start by one byte, populate eight little-endian bytes and call `loadLittleEndian(as: UInt64.self)`. The retained isolated original-source reproducer terminates with `Fatal error: load from misaligned raw pointer` (status -5). Image bytes and sliced buffers do not promise natural alignment.

## Current behavior

The reader's generic primitive calls `UnsafeRawBufferPointer.load(as:)`. Both the direct little-endian path and the reversed big-endian buffer path require alignment that their byte-storage contract does not provide. Compose currently carries a source patch for this defect; its newer native dependency graph lacks that protection.

## Expected behavior

Decode the same integer values at every byte offset without trapping. Keep the public signature, byte-order conversion and existing buffer-size preconditions. Move the same fix into the owning SDK so downstream clients can consume one qualified artifact instead of a consumer-only patch.

## Environment and evidence

Apple silicon macOS 27, Xcode 27.0 (27A266a), Apple Swift 6.4. The retained `candidate-sdk-unaligned/red-v2` proof reproduces the public-load trap. A preceding compiler invocation lacked an explicit SDK and stopped before execution; it remains preserved. The changed captured module passes two Swift Testing tests with 24 parameter combinations, covering offsets zero through seven for UInt16/32/64 and both simulated byte-order branches. Changed load methods cover all 14 executable lines. This is focused boundary proof, not full package or Linux hardware qualification.

The initial green controller expected 24 logical tests, but Swift Testing reports two parameterized tests containing 24 cases. Its native process exited successfully. A separate read-only recovery authenticates the raw case inventory, source/test bytes, atomic-instrumentation coverage and host restoration without rerunning tests; the original failed controller receipt remains unchanged. Full captured-file coverage is 38.81% because unchanged conversion helpers and physical big-endian host detection are outside this selection. No baseline binary or historical benchmark was rebuilt or rerun.

See [the companion change record](PR-ext4-unaligned-load.md).
