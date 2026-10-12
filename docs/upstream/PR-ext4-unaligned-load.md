# fix(ext4): load unaligned filesystem metadata safely

## Motivation and resulting behavior

Raw filesystem bytes may begin at any address. Replace alignment-requiring integer loads with `loadUnaligned` so selected paths, inode metadata and other reader consumers can decode the same bytes without a runtime alignment trap. This adopts the exact primitive correction already used by Compose's enhanced dependency patch.

## Implementation

The public `loadLittleEndian(as:)` delegates to a module-internal overload accepting `Endianness`. Both branches use unaligned loads. The internal overload lets regression tests execute both byte-order paths on one host; this does not claim execution on physical big-endian hardware. No public API, package dependency, guest RPC, archive format or filesystem mutation behavior changes.

SDK-owned tests cover every offset zero through seven for UInt16, UInt32 and UInt64; the branch-selection test exercises both byte-order paths and the public test independently pins normal image decoding. The existing Compose patch is retained until a newly qualified SDK artifact is consumed by the next layer; it must not be removed from the still-pinned older SDK graph prematurely.

## Validation

The original-source public-load reproducer traps with `load from misaligned raw pointer`. The changed maintained module passes two logical tests and all 24 parameter combinations in an isolated instrumented capture. All 14 executable lines in the changed load methods are covered; the overall captured file is 38.81% because this selection excludes unchanged conversion helpers and physical big-endian host detection. Instrumentation uses atomic counters, and the retained report rejects wrapped counts. Broader SDK, native artifact, guest and matching Container/Compose integration gates remain pending.

The original green controller rejected the successful result because it confused logical tests with parameter cases. A separately retained recovery processor authenticates the original zero exit status, unique 8/16 parameter inventory, final suite success, source fingerprints, raw coverage and host restoration; the failed controller receipt is preserved and no test was rerun. Subsequent test formatting changes only import order and range spacing and is checked against the exact captured test. The first compiler SDK-setup failure is also retained. No published baseline artifact or old measurement was rebuilt or repeated.

## Compatibility and remaining scope

The buffer must still contain enough bytes for its requested type. The helper retains existing generic and byte-order behavior. This is a host library repair; it introduces no guest protocol or behavioral change. Publish and consume a freshly qualified host SDK layer against unchanged native foundation archives before replacing Compose's existing patched layer. Do not relabel the earlier native SDK artifact as containing this repair. Full stack qualification, overall package coverage and Docker performance parity remain open.

See [the companion issue](ISSUE-ext4-unaligned-load.md). No upstream submission is made by this local handoff.
