# Compatibility gap: CPU CFS quota and period

## Surface

Generic macOS-hosted Linux container resource configuration.

## Problem

The runtime could express an optional CFS quota for fractional CPU limits but
fixed the CFS period at `100000` microseconds. Clients that need an explicit
Linux CFS quota/period pair could not faithfully project it to the guest's
cgroup v2 `cpu.max` interface.

## Required behavior

- Retain the existing CPU-count-derived default when no CFS override is set.
- Allow callers to set both a quota and period in microseconds.
- Allow a period without a quota, preserving an unlimited cgroup quota.
- Expose only generic OCI resource concepts.

## Apple-shaped implementation

Implementation commit: `e540824`
(`feat(runtime): support CPU CFS quota and period`).

The companion Container consumer is `81cc56f`
(`feat(runtime): support CPU CFS quota and period`). It parses generic CLI
flags, persists values, and validates them before projecting to this API.
Compose-specific mapping is deliberately outside both Apple-shaped changes.

## Scope and non-goals

- macOS-hosted Linux guests only.
- No Windows behavior.
- No CPU realtime scheduler or CPU affinity implementation.
- No Docker/Compose dependencies or public types.

## Upstream handoff condition

Replay this commit after `f7b45bf`, then replay `81cc56f` in the Container
consumer. Run the focused unit tests and the downstream guest cgroup test;
update commit identifiers if replay changes them.
