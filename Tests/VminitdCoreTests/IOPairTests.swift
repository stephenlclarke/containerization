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
import Foundation
import Testing

@testable import VminitdCore

@Suite(.serialized)
struct IOPairTests {
    @Test func destinationIsNonblockingBeforeAnyDataArrives() throws {
        let input = Pipe()
        let output = Pipe()
        let relay = IOPair(
            readFrom: input.fileHandleForReading,
            writeTo: output.fileHandleForWriting,
            reason: "test nonblocking destination"
        )
        try relay.relay()
        defer { relay.close() }

        // The shared epoll thread must never enter a blocking destination
        // write, even when another stream is required to make it writable.
        let flags = fcntl(output.fileHandleForWriting.fileDescriptor, F_GETFL)
        #expect(flags >= 0)
        #expect(flags & O_NONBLOCK != 0)
    }
}
#endif
