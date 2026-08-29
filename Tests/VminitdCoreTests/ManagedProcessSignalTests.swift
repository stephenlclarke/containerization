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

#if os(Linux)

import ContainerizationError
import Testing

@testable import VminitdCore

struct ManagedProcessSignalTests {
    @Test func exitedProcessDoesNotRequireSignalDescriptor() throws {
        #expect(try ManagedProcess.signalDescriptor(descriptor: nil, hasExited: true) == nil)
    }

    @Test func runningProcessRequiresSignalDescriptor() {
        #expect(throws: ContainerizationError.self) {
            try ManagedProcess.signalDescriptor(descriptor: nil, hasExited: false)
        }
    }

    @Test func runningProcessReturnsSignalDescriptor() throws {
        #expect(try ManagedProcess.signalDescriptor(descriptor: 42, hasExited: false) == 42)
    }
}

#endif
