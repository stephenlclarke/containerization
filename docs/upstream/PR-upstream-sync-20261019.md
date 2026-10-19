# Synchronize Apple Containerization

Merge Apple upstream through `6adea5663427b4068108e9268e6125fc139b6045`. Retain fork sandbox, namespace, archive hardlink/attribute, buffered registry transport, and resource-plan validation contracts. Use upstream descriptor primitives and packed ext4 metadata layout; retain only the existing-directory traversal required for deferred archive attributes.

Validation: full warning-as-error `make test` compiled every host target. Only two legacy ext4 tests failed (three assertions), because they assumed the superseded metadata layout. Their revised checks verify exact image capacity and packed metadata bounds; all 93 ext4 tests then passed. All other host suites passed in the full attempt. `make protos` with pinned protoc 26.1 and repository Hawkeye regenerated identical protobuf source. No published baseline or benchmark assets were rebuilt.

Linux-only guest/Cloud Hypervisor runtime changes require Linux validation; macOS does not execute those paths. This is a source synchronization PR and does not claim a qualified release or new parity measurements.
