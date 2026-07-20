# Preserve Docker image VOLUME declarations in `ImageConfig`

## Summary

Add an optional `volumes` field to `ContainerizationOCI.ImageConfig` for
Docker image config `Volumes` metadata.

## Motivation

Image consumers need to distinguish an image that declares Dockerfile
`VOLUME` destinations from one that does not. Discarding the field at the
shared OCI-model boundary prevents higher layers from implementing or
explicitly reporting runtime support.

## Implementation

- Add the `Volumes` coding key and typed destination map beside the existing
  Docker config extensions.
- Preserve source compatibility with a defaulted initializer argument.
- Cover construction and JSON decoding in `ContainerizationOCITests`.

## Validation

- `swift test --filter OCITests`
- Package-wide test suite before submission.

## Compatibility and follow-up

This patch only preserves metadata. Docker's first-use volume copy-up remains
the responsibility of a runtime or orchestration layer with an appropriate
storage primitive.
