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

import Testing

@testable import VminitdCore

struct LinuxNamespaceEntryTests {
    private let userNamespaceFlag: Int32 = 1 << 28
    private let requestedFlags: Int32 = (1 << 28) | (1 << 25) | (1 << 17)

    @Test func preservesUserNamespaceForDistinctTarget() {
        #expect(
            LinuxNamespaceEntry.flags(
                requestedFlags: requestedFlags,
                userNamespaceFlag: userNamespaceFlag,
                targetUserNamespaceMatchesCurrent: false
            ) == requestedFlags
        )
    }

    @Test func omitsOnlyCurrentUserNamespace() {
        #expect(
            LinuxNamespaceEntry.flags(
                requestedFlags: requestedFlags,
                userNamespaceFlag: userNamespaceFlag,
                targetUserNamespaceMatchesCurrent: true
            ) == ((1 << 25) | (1 << 17))
        )
    }
}
