# Synchronize containerization with Apple main

## Motivation

The container-only dependency graph must include Apple main `bc994b88df46207fad7775b0eabc51947e315881`, including explicit VM sizing, OCI runtime support, filesystem statistics, socket liveness, and archive fixes. Preserve the fork's namespace, device, graphics, filesystem-context, and resource-control features.

## Acceptance

Merge without rewriting history. Validate the combined host APIs through the reduced Bazel layers and compile the Linux guest with the installed Swift 6.3 Static Linux SDK. Preserve previous refs and failed validation evidence. Other container-family applications are outside this change.
