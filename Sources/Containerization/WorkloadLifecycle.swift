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

import ContainerizationError
import Foundation

/// Stable lower-runtime identity for one live workload generation.
///
/// Containerization deliberately does not expose Docker lifecycle states. It
/// fences observable effects to the authority-supplied workload and sandbox
/// generations so a delayed acknowledgement cannot mutate a replacement
/// process or another workload sharing the VM.
public struct WorkloadLifecycleIdentity: Codable, Equatable, Hashable, Sendable {
    public let containerID: String
    public let processGeneration: UInt64
    public let sandboxGeneration: UInt64

    private enum CodingKeys: String, CodingKey {
        case containerID
        case processGeneration
        case sandboxGeneration
    }

    public init(
        containerID: String,
        processGeneration: UInt64,
        sandboxGeneration: UInt64,
    ) throws {
        guard !containerID.isEmpty, processGeneration > 0, sandboxGeneration > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "workload lifecycle identity requires non-empty ID and positive generations",
            )
        }
        self.containerID = containerID
        self.processGeneration = processGeneration
        self.sandboxGeneration = sandboxGeneration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            containerID: values.decode(String.self, forKey: .containerID),
            processGeneration: values.decode(
                UInt64.self,
                forKey: .processGeneration,
            ),
            sandboxGeneration: values.decode(
                UInt64.self,
                forKey: .sandboxGeneration,
            ),
        )
    }
}

public enum WorkloadLifecycleEffect: String, Codable, Equatable, Sendable {
    case status
    case pause
    case resume
    case resize
    case updateResources
    case cleanup
    case memoryEvents
}

/// Positive acknowledgement returned only after the requested lower-runtime
/// effect has completed for the exact bound generation.
public struct WorkloadLifecycleAcknowledgement: Codable, Equatable, Sendable {
    public let identity: WorkloadLifecycleIdentity
    public let operationGeneration: UInt64
    public let effect: WorkloadLifecycleEffect
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case identity
        case operationGeneration
        case effect
        case observedAt
    }

    public init(
        identity: WorkloadLifecycleIdentity,
        operationGeneration: UInt64,
        effect: WorkloadLifecycleEffect,
        observedAt: Date = Date(),
    ) throws {
        guard operationGeneration > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "operation generation must be positive",
            )
        }
        self.identity = identity
        self.operationGeneration = operationGeneration
        self.effect = effect
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(
                WorkloadLifecycleIdentity.self,
                forKey: .identity,
            ),
            operationGeneration: values.decode(
                UInt64.self,
                forKey: .operationGeneration,
            ),
            effect: values.decode(
                WorkloadLifecycleEffect.self,
                forKey: .effect,
            ),
            observedAt: values.decode(Date.self, forKey: .observedAt),
        )
    }
}

/// Per-sandbox generation fence. Repeating the same operation is idempotent;
/// changing its effect or attempting it against a stale generation fails.
public actor WorkloadLifecycleFence {
    private var active = [String: WorkloadLifecycleIdentity]()
    private var highestIdentities = [String: WorkloadLifecycleIdentity]()
    private var acknowledgements = [WorkloadLifecycleIdentity: WorkloadLifecycleAcknowledgement]()
    private var highestSandboxGeneration: UInt64 = 0

    public init() {}

    public func bind(_ identity: WorkloadLifecycleIdentity) throws {
        guard identity.sandboxGeneration >= highestSandboxGeneration else {
            throw stale(identity, current: nil)
        }
        if identity.sandboxGeneration > highestSandboxGeneration {
            active.removeAll(keepingCapacity: true)
            acknowledgements.removeAll(keepingCapacity: true)
            highestIdentities.removeAll(keepingCapacity: true)
            highestSandboxGeneration = identity.sandboxGeneration
        }
        if let current = active[identity.containerID] {
            guard identity == current || isNewer(identity, than: current) else {
                throw stale(identity, current: current)
            }
            if current != identity {
                acknowledgements.removeValue(forKey: current)
            }
        } else if let highest = highestIdentities[identity.containerID] {
            guard isNewer(identity, than: highest) else {
                throw stale(identity, current: highest)
            }
        }
        active[identity.containerID] = identity
        highestIdentities[identity.containerID] = identity
    }

    public func validate(_ identity: WorkloadLifecycleIdentity) throws {
        guard let current = active[identity.containerID], current == identity else {
            throw stale(identity, current: active[identity.containerID])
        }
    }

    public func acknowledge(
        _ effect: WorkloadLifecycleEffect,
        identity: WorkloadLifecycleIdentity,
        operationGeneration: UInt64,
        observedAt: Date = Date(),
    ) throws -> WorkloadLifecycleAcknowledgement {
        try validate(identity)
        if let existing = acknowledgements[identity] {
            if operationGeneration == existing.operationGeneration {
                guard existing.effect == effect else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "operation generation already acknowledged for a different effect",
                    )
                }
                return existing
            }
            guard operationGeneration > existing.operationGeneration else {
                throw ContainerizationError(
                    .invalidState,
                    message: "operation generation \(operationGeneration) is older than acknowledged generation \(existing.operationGeneration)",
                )
            }
        }
        let acknowledgement = try WorkloadLifecycleAcknowledgement(
            identity: identity,
            operationGeneration: operationGeneration,
            effect: effect,
            observedAt: observedAt,
        )
        acknowledgements[identity] = acknowledgement
        return acknowledgement
    }

    public func release(_ identity: WorkloadLifecycleIdentity) throws {
        try validate(identity)
        active.removeValue(forKey: identity.containerID)
        acknowledgements.removeValue(forKey: identity)
    }

    private func isNewer(
        _ attempted: WorkloadLifecycleIdentity,
        than current: WorkloadLifecycleIdentity,
    ) -> Bool {
        attempted.sandboxGeneration > current.sandboxGeneration
            || (attempted.sandboxGeneration == current.sandboxGeneration
                && attempted.processGeneration > current.processGeneration)
    }

    private func stale(
        _ attempted: WorkloadLifecycleIdentity,
        current: WorkloadLifecycleIdentity?,
    ) -> ContainerizationError {
        ContainerizationError(
            .invalidState,
            message: current.map {
                "stale workload generation \(attempted.processGeneration)/\(attempted.sandboxGeneration); current is \($0.processGeneration)/\($0.sandboxGeneration)"
            } ?? "workload generation is not bound",
        )
    }
}
