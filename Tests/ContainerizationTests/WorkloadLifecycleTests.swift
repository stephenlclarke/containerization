//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import Containerization

@Suite
struct WorkloadLifecycleTests {
    @Test
    func `decoded identities enforce the generation fence invariants`() throws {
        let invalid = Data(
            """
            {"containerID":"","processGeneration":0,"sandboxGeneration":0}
            """.utf8,
        )

        #expect(throws: Error.self) {
            try JSONDecoder().decode(
                WorkloadLifecycleIdentity.self,
                from: invalid,
            )
        }
    }

    @Test
    func `decoded acknowledgements require a positive operation generation`() throws {
        let invalid = Data(
            """
            {"identity":{"containerID":"container-a","processGeneration":1,"sandboxGeneration":1},"operationGeneration":0,"effect":"status","observedAt":0}
            """.utf8,
        )

        #expect(throws: Error.self) {
            try JSONDecoder().decode(
                WorkloadLifecycleAcknowledgement.self,
                from: invalid,
            )
        }
    }

    @Test
    func `released workload generations cannot be rebound`() async throws {
        let fence = WorkloadLifecycleFence()
        let retired = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 1,
            sandboxGeneration: 1,
        )
        try await fence.bind(retired)
        try await fence.release(retired)

        await #expect(throws: Error.self) {
            try await fence.bind(retired)
        }
        let replacement = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 2,
            sandboxGeneration: 1,
        )
        try await fence.bind(replacement)
        try await fence.validate(replacement)
    }

    @Test
    func `acknowledgements are generation fenced and idempotent`() async throws {
        let fence = WorkloadLifecycleFence()
        let first = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 1,
            sandboxGeneration: 1,
        )
        try await fence.bind(first)

        let timestamp = Date(timeIntervalSince1970: 42)
        let acknowledgement = try await fence.acknowledge(
            .pause,
            identity: first,
            operationGeneration: 3,
            observedAt: timestamp,
        )
        let replay = try await fence.acknowledge(
            .pause,
            identity: first,
            operationGeneration: 3,
            observedAt: timestamp.addingTimeInterval(10),
        )
        #expect(replay == acknowledgement)
        await #expect(throws: Error.self) {
            try await fence.acknowledge(
                .status,
                identity: first,
                operationGeneration: 2,
            )
        }

        let replacement = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 1,
            sandboxGeneration: 2,
        )
        try await fence.bind(replacement)
        _ = try await fence.acknowledge(
            .status,
            identity: replacement,
            operationGeneration: 5,
        )
        await #expect(throws: Error.self) {
            try await fence.acknowledge(
                .pause,
                identity: replacement,
                operationGeneration: 4,
            )
        }
        await #expect(throws: Error.self) {
            try await fence.validate(first)
        }
    }

    @Test
    func `shared sandbox identities cannot acknowledge another workload`() async throws {
        let fence = WorkloadLifecycleFence()
        let first = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 4,
            sandboxGeneration: 7,
        )
        let second = try WorkloadLifecycleIdentity(
            containerID: "container-b",
            processGeneration: 2,
            sandboxGeneration: 7,
        )
        try await fence.bind(first)
        try await fence.bind(second)
        try await fence.release(first)

        await #expect(throws: Error.self) {
            try await fence.acknowledge(
                .cleanup,
                identity: first,
                operationGeneration: 5,
            )
        }
        #expect(
            try await fence.acknowledge(
                .status,
                identity: second,
                operationGeneration: 5,
            ).identity == second,
        )
    }

    @Test
    func `advancing a shared sandbox invalidates every older workload`() async throws {
        let fence = WorkloadLifecycleFence()
        let first = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 1,
            sandboxGeneration: 1,
        )
        let second = try WorkloadLifecycleIdentity(
            containerID: "container-b",
            processGeneration: 1,
            sandboxGeneration: 1,
        )
        try await fence.bind(first)
        try await fence.bind(second)

        let replacement = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 1,
            sandboxGeneration: 2,
        )
        try await fence.bind(replacement)

        await #expect(throws: Error.self) {
            try await fence.validate(second)
        }
        await #expect(throws: Error.self) {
            try await fence.bind(second)
        }
    }

    @Test
    func `acknowledgement replay state retains only the latest operation`() async throws {
        let fence = WorkloadLifecycleFence()
        let identity = try WorkloadLifecycleIdentity(
            containerID: "container-a",
            processGeneration: 1,
            sandboxGeneration: 1,
        )
        try await fence.bind(identity)

        _ = try await fence.acknowledge(
            .status,
            identity: identity,
            operationGeneration: 1,
        )
        let latest = try await fence.acknowledge(
            .memoryEvents,
            identity: identity,
            operationGeneration: 2,
        )
        #expect(
            try await fence.acknowledge(
                .memoryEvents,
                identity: identity,
                operationGeneration: 2,
            ) == latest,
        )
        await #expect(throws: Error.self) {
            try await fence.acknowledge(
                .status,
                identity: identity,
                operationGeneration: 1,
            )
        }
    }

    @Test
    func `memory event deltas require cgroup OOM evidence`() {
        let before = ContainerStatistics.MemoryEventStatistics(
            low: 1,
            high: 2,
            max: 3,
            oom: 4,
            oomKill: 5,
            oomGroupKill: 6,
        )
        let after = ContainerStatistics.MemoryEventStatistics(
            low: 3,
            high: 5,
            max: 8,
            oom: 4,
            oomKill: 6,
            oomGroupKill: 8,
        )
        let delta = after.delta(since: before)

        #expect(
            delta
                == ContainerStatistics.MemoryEventStatistics(
                    low: 2,
                    high: 3,
                    max: 5,
                    oom: 0,
                    oomKill: 1,
                    oomGroupKill: 2,
                ),
        )
        #expect(delta.observedOOMKill)
        #expect(!before.delta(since: before).observedOOMKill)
    }
}
