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

enum MemoryTarget {
    static let alignment: UInt64 = 1 << 20
    static let minimum: UInt64 = 4 << 20

    static func validate(_ memoryInBytes: UInt64, maximum: UInt64) throws {
        guard memoryInBytes.isMultiple(of: alignment) else {
            throw ContainerizationError(.invalidArgument, message: "memory target must be a multiple of 1 MiB")
        }
        guard memoryInBytes >= minimum, memoryInBytes <= maximum else {
            throw ContainerizationError(
                .invalidArgument,
                message: "memory target must be between \(minimum) and \(maximum) bytes"
            )
        }
    }
}
