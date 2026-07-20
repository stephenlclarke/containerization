# Pull request: capability-gate virtio-GPU guest integration

## Summary

This test-only macOS change turns one precise unavailable-guest-kernel result
into a skipped integration capability:

- `ContainerizationError.notFound` for
  `/dev/dri/renderD128` is skipped by the two virtio-GPU smoke tests.
- Any other error still fails the test.
- README now distinguishes the graphics configuration contract from the guest
  kernel artifact that supplies its DRM driver.

## Commit tracking

- Containerization code:
  [`de5b47a`](https://github.com/stephenlclarke/containerization/commit/de5b47a740355f1cd0baefb98b9031ad8e7c183a)
  `test(integration): classify unavailable virtio gpu`.
- Changed code: `Sources/Integration/ContainerTests.swift` and
  `Sources/Integration/Suite.swift`.
- Apple/container and container-compose changes: none.

## Why this is Apple-shaped

The change is isolated to the existing macOS integration harness. It does not
introduce Compose terminology, Docker policy, a Linux-only behavior, or a new
runtime abstraction. The public graphics API remains strict and unit-tested;
only the optional guest-kernel capability is classified accurately.

## Validation

```console
swift test --filter 'graphicsConfiguration|legacyGraphics'
make containerization
./bin/containerization-integration --filter 'container virtio graphics' \
  --max-concurrency 1
make coverage
make integration
```

Expected result on a kernel without `virtio_gpu`: the classification check
passes and the two selected smoke tests are skipped with the render-node
reason, while the complete suite succeeds. On a driver-capable kernel, both
tests retain their existing strict assertions.

Observed in the fork at `de5b47a`:

- `make coverage`: 638 unit tests in 83 suites passed and produced the LLVM
  coverage report.
- The deterministic classifier check covers the exact error, a wrong device
  path, a wrong error code, and an unrelated error.
- `make integration`: 174 of 176 tests passed; the two virtio-GPU device
  tests were explicitly skipped because this kernel lacks the render node.

## Docker Compose compatibility

Not applicable. Docker Compose has no part in this runtime-test capability
classification.
