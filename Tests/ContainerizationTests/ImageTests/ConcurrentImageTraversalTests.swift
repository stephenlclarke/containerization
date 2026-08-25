//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerizationOCI
import Testing

@testable import Containerization

private actor TraversalProbe {
    private(set) var maximumActive = 0
    private var active = 0

    func resolve(_ descriptor: Descriptor) async throws -> [Descriptor] {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return [
            Descriptor(
                mediaType: "application/vnd.test.child",
                digest: "\(descriptor.digest)-child",
                size: 0)
        ]
    }
}

@Suite("Concurrent image traversal")
struct ConcurrentImageTraversalTests {
    @Test func resolvesDescriptorsConcurrentlyInInputOrder() async throws {
        let descriptors = (0..<8).map {
            Descriptor(
                mediaType: "application/vnd.test.parent",
                digest: "sha256:\($0)",
                size: 0)
        }
        let probe = TraversalProbe()

        let children = try await ConcurrentImageTraversal.children(
            of: descriptors,
            maximumConcurrency: 3
        ) { descriptor in
            try await probe.resolve(descriptor)
        }
        let maximumActive = await probe.maximumActive

        #expect(maximumActive == 3)
        #expect(children.map(\.digest) == descriptors.map { "\($0.digest)-child" })
    }
}
