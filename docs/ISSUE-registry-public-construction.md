<!-- markdownlint-disable MD013 -->

# Registry metadata cannot be constructed by release consumers

## Steps to reproduce

Build the optimized ContainerizationOS release without testing internals, then import it from a separate module and construct RegistryInfo with hostname, username, modifiedDate and createdDate.

## Current behavior

RegistryInfo is public and exposes public attributes, but its synthesized memberwise initializer is internal. Container's RegistryResourceTests therefore use @testable import for this dependency, which fails against the published release: module ContainerizationOS was not compiled for testing.

## Expected behavior

Clients can construct registry metadata through a public initializer without requesting testing internals or accessing the user's Keychain.

## Environment and evidence

The failure was recorded on Apple silicon macOS in the Container 8303b2f9 immutable checkpoint with SDK 518f92a0. The original failed checkpoint, its successful 28 target reports and prior benchmark results are retained in the performance campaign.

## Scope

Add a public four-argument initializer with the existing labels and unchanged field values. Retain the guest, dependency pins, metadata layout and Keychain behavior. Publish a freshly qualified SDK artifact before updating the upper consumer. No Apple issue or pull request has been submitted.
