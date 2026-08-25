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

enum ConcurrentImageTraversal {
    static func children(
        of descriptors: [Descriptor],
        maximumConcurrency: Int,
        resolve: @escaping @Sendable (Descriptor) async throws -> [Descriptor]
    ) async throws -> [Descriptor] {
        try await withThrowingTaskGroup(of: (Int, [Descriptor]).self) { group in
            var iterator = descriptors.enumerated().makeIterator()
            for _ in 0..<max(maximumConcurrency, 1) {
                guard let (index, descriptor) = iterator.next() else {
                    break
                }
                group.addTask {
                    (index, try await resolve(descriptor))
                }
            }

            var ordered = [[Descriptor]?](repeating: nil, count: descriptors.count)
            for try await (index, children) in group {
                ordered[index] = children
                if let (nextIndex, descriptor) = iterator.next() {
                    group.addTask {
                        (nextIndex, try await resolve(descriptor))
                    }
                }
            }
            return ordered.compactMap { $0 }.flatMap { $0 }
        }
    }
}
