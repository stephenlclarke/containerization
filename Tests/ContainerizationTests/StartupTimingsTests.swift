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

import Testing

@testable import Containerization

struct StartupTimingsTests {
    @Test func recordsNonOverlappingPhasesAndTotal() {
        let start = ContinuousClock.now
        var timings = StartupTimings(phase: "prestart", at: start)
        timings.begin("virtualization-start", at: start.advanced(by: .microseconds(7)))
        timings.begin("agent-connect", at: start.advanced(by: .microseconds(20)))
        let metadata = timings.metadata(outcome: "success", at: start.advanced(by: .microseconds(29)))

        #expect(metadata["phase-duration-us"]?.description == "prestart=7,virtualization-start=13,agent-connect=9")
        #expect(metadata["total-duration-us"]?.description == "29")
        #expect(metadata["active-phase"]?.description == "agent-connect")
        #expect(metadata["outcome"]?.description == "success")
    }

    @Test func failureIncludesUnfinishedFirstPhase() {
        let start = ContinuousClock.now
        let timings = StartupTimings(phase: "prestart", at: start)
        let metadata = timings.metadata(outcome: "failure", at: start.advanced(by: .microseconds(41)))

        #expect(metadata["phase-duration-us"]?.description == "prestart=41")
        #expect(metadata["active-phase"]?.description == "prestart")
        #expect(metadata["outcome"]?.description == "failure")
    }

    @Test func separatesCleanupFromTheFailedPhase() {
        let start = ContinuousClock.now
        var timings = StartupTimings(phase: "virtual-machine-start", at: start)
        timings.beginCleanup(at: start.advanced(by: .microseconds(12)))
        let metadata = timings.metadata(outcome: "failure", at: start.advanced(by: .microseconds(31)))

        #expect(metadata["phase-duration-us"]?.description == "virtual-machine-start=12,failure-cleanup=19")
        #expect(metadata["failed-phase"]?.description == "virtual-machine-start")
        #expect(metadata["total-duration-us"]?.description == "31")
    }

    @Test func handlesWholeSecondsAndTruncatesSubMicroseconds() {
        let start = ContinuousClock.now
        var timings = StartupTimings(phase: "agent-connect", at: start)
        timings.begin("agent-handshake", at: start.advanced(by: .seconds(2)))
        let metadata = timings.metadata(outcome: "failure", at: start.advanced(by: .seconds(2) + .nanoseconds(1999)))

        #expect(metadata["phase-duration-us"]?.description == "agent-connect=2000000,agent-handshake=1")
        #expect(metadata["total-duration-us"]?.description == "2000001")
    }
}
