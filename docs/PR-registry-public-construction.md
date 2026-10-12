<!-- markdownlint-disable MD013 -->

# fix(os): expose registry metadata construction to release consumers

## Motivation

The Container test suite cannot consume the released ContainerizationOS module because registry fixture construction relies on an internal synthesized initializer. This blocks the Container checkpoint after the copy optimization and benchmarks passed.

## Implementation

Add an explicit public initializer for the four existing RegistryInfo attributes. Add a regression test that uses an ordinary module import and checks every supplied attribute. The Container consumer will also use an ordinary import after adopting the new SDK release.

## Validation

The minimal optimized module visibility control rejected the old initializer as internal and accepted the new public initializer, preserving all four supplied values. The ordinary-import regression typechecked successfully with the Xcode Swift Testing macro plugin; strict Swift formatting passed. Original SDK group qualification and actual source quality analysis remain required before publishing the changed SDK. Reuse unchanged baseline artifacts and recorded benchmark measurements.

## Compatibility and risks

This is an additive public API with the same argument labels and behavior as the former internal memberwise initializer. It changes neither data layout nor Keychain access and introduces no default values. Guest source and runtime protocol remain unchanged.

## Linked work

See ISSUE-registry-public-construction.md and the Container checkpoint API boundary failure. Upstream submission remains deferred until programme-wide qualification.
