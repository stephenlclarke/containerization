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

import ContainerizationOCI
import Foundation

internal protocol ContainsAuth {

}

extension ContainsAuth {
    static var hasRegistryCredentials: Bool {
        authentication != nil
    }

    static var authentication: Authentication? {
        authentication(environment: ProcessInfo.processInfo.environment)
    }

    static func authentication(environment: [String: String]) -> Authentication? {
        guard let password = environment["REGISTRY_TOKEN"],
            !password.isEmpty,
            let username = environment["REGISTRY_USERNAME"],
            !username.isEmpty
        else {
            return nil
        }
        return BasicAuthentication(username: username, password: password)
    }
}
