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

import ContainerizationOS
import Foundation
import Testing

struct RegistryInfoTests {
    @Test
    func constructionFromPublicAPI() {
        let modifiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let createdDate = Date(timeIntervalSince1970: 1_690_000_000)
        let info = RegistryInfo(
            hostname: "registry.example.com:5000",
            username: "developer",
            modifiedDate: modifiedDate,
            createdDate: createdDate
        )

        #expect(info.hostname == "registry.example.com:5000")
        #expect(info.username == "developer")
        #expect(info.modifiedDate == modifiedDate)
        #expect(info.createdDate == createdDate)
    }
}
