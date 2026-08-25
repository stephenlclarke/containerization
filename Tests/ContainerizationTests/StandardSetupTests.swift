//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Testing

@testable import Containerization

private actor SetupOverlapProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func begin() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }
}

private actor SetupCancellationProbe {
    private(set) var cancelled = 0

    func recordCancellation() {
        cancelled += 1
    }
}

private enum SetupTestError: Error {
    case expected
}

struct StandardSetupTests {
    @Test func independentOperationsOverlap() async throws {
        let probe = SetupOverlapProbe()
        let operation: @Sendable () async throws -> Void = {
            await probe.begin()
            try await Task.sleep(for: .milliseconds(50))
            await probe.end()
        }

        try await Vminitd.runStandardSetupOperations([
            operation,
            operation,
            operation,
            operation,
        ])

        #expect(await probe.maximumActive == 4)
    }

    @Test func failureCancelsRemainingOperations() async {
        let probe = SetupCancellationProbe()
        let failing: @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(20))
            throw SetupTestError.expected
        }
        let waiting: @Sendable () async throws -> Void = {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                await probe.recordCancellation()
                throw CancellationError()
            }
        }

        do {
            try await Vminitd.runStandardSetupOperations([failing, waiting, waiting, waiting])
            Issue.record("expected setup failure")
        } catch SetupTestError.expected {
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await probe.cancelled == 3)
    }
}
