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

@testable import Cgroup

struct Cgroup2ManagerProcessTests {
    @Test func processIdentifiersHandleEmptyFiles() throws {
        #expect(try Cgroup2Manager.parseProcessIdentifiers(nil) == [])
        #expect(try Cgroup2Manager.parseProcessIdentifiers("") == [])
    }

    @Test func processIdentifiersTrimAndSortValues() throws {
        let identifiers = try Cgroup2Manager.parseProcessIdentifiers("99\n 7 \n42\n")

        #expect(identifiers == [7, 42, 99])
    }

    @Test func processIdentifiersRejectMalformedValues() {
        #expect(throws: ContainerizationError.self) {
            try Cgroup2Manager.parseProcessIdentifiers("42\nnot-a-pid\n")
        }
    }
}

#endif
