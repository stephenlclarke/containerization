# Compatibility gap: generic fractional CPU quota

## Problem

`LinuxContainer.Configuration.cpus` is intentionally integral because it
contributes to sandbox VM vCPU allocation. The OCI runtime supports a separate
CFS quota, but the generic configuration did not let a client select it. That
prevented a macOS-hosted Linux workload from being limited to a fractional CPU
while retaining a valid integral VM configuration.

## Required behavior

- Provide an optional generic CFS quota in microseconds.
- Continue using a 100 ms period.
- Fall back to the existing integral CPU-derived quota when omitted.
- Keep this API independent of Docker and Compose.

## Apple-shaped implementation

Commit `f7b45bf` (`feat(runtime): support fractional CPU quota`) adds only a
generic optional configuration field and projects it into OCI `LinuxCPU`.
There are no Compose types, command-line flags, or non-macOS branches in this
fork change.

## Scope and non-goals

- macOS-hosted Linux runtime only.
- No Windows behavior.
- No CPU period, realtime, cpuset, or host-scheduler changes.
- No fractional VM vCPU allocation.

## Upstream handoff condition

Before an Apple pull request, replay the commit on the current upstream base
and rerun the focused runtime-spec test. The downstream Container and Compose
validation belongs to their respective repositories.
