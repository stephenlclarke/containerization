# Preserve Docker image VOLUME declarations in `ImageConfig`

## Problem

Docker-compatible image configuration JSON may contain a `Volumes` object
whose destination keys are created by Dockerfile `VOLUME` instructions.
`ContainerizationOCI.ImageConfig` already retains adjacent Docker config
fields such as `ExposedPorts` and `StopSignal`, but silently discarded
`Volumes` during decoding. Runtime consumers therefore cannot discover the
declaration or make a deliberate compatibility decision.

## Scope

This additive model change preserves Docker image metadata only. It does not
prescribe Docker's volume copy-up behavior, storage driver behavior, or a
container-runtime mount policy.

## Expected behavior

`ImageConfig` must decode and encode `Volumes` as a map keyed by container
destination. An absent field remains `nil`, preserving existing OCI-only image
behavior.

## Validation

- Construct an image configuration with a volume declaration and verify it is retained.
- Decode Docker image config JSON containing multiple `Volumes` destinations
  and verify the complete map.
- Run the focused Containerization OCI test target.

## Compatibility

The optional property is source-compatible for existing callers and losslessly
preserves a Docker image config extension already accepted by the image loader.
