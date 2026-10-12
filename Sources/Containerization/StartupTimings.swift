//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import Logging

/// Measures non-overlapping startup phases, including the phase that fails.
struct StartupTimings {
    private let startedAt: ContinuousClock.Instant
    private var phaseStartedAt: ContinuousClock.Instant
    private var phase: String
    private var completed: [(String, Duration)] = []
    private var failedPhase: String?

    init(phase: String, at now: ContinuousClock.Instant = .now) {
        self.startedAt = now
        self.phaseStartedAt = now
        self.phase = phase
    }

    mutating func begin(_ phase: String, at now: ContinuousClock.Instant = .now) {
        self.completed.append((self.phase, self.phaseStartedAt.duration(to: now)))
        self.phaseStartedAt = now
        self.phase = phase
    }

    mutating func beginCleanup(at now: ContinuousClock.Instant = .now) {
        self.failedPhase = self.phase
        self.begin("failure-cleanup", at: now)
    }

    func metadata(outcome: String, at now: ContinuousClock.Instant = .now) -> Logger.Metadata {
        let phases = self.completed + [(self.phase, self.phaseStartedAt.duration(to: now))]
        let summary = phases.map { "\($0.0)=\(Self.microseconds($0.1))" }.joined(separator: ",")
        var metadata: Logger.Metadata = [
            "outcome": "\(outcome)",
            "active-phase": "\(self.phase)",
            "phase-duration-us": "\(summary)",
            "total-duration-us": "\(Self.microseconds(self.startedAt.duration(to: now)))",
        ]
        if let failedPhase = self.failedPhase {
            metadata["failed-phase"] = "\(failedPhase)"
        }
        return metadata
    }

    private static func microseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
    }
}
