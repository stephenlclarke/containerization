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

/// Chooses the namespace flags needed to enter a container process.
public enum LinuxNamespaceEntry {
    /// Returns `requestedFlags` without the user namespace flag when the
    /// target process already uses the caller's user namespace.
    ///
    /// Linux rejects an attempt to reenter the current user namespace. Other
    /// namespaces must still be entered so an exec process retains the target
    /// container's isolation.
    public static func flags(
        requestedFlags: Int32,
        userNamespaceFlag: Int32,
        targetUserNamespaceMatchesCurrent: Bool
    ) -> Int32 {
        guard targetUserNamespaceMatchesCurrent else {
            return requestedFlags
        }
        return requestedFlags & ~userNamespaceFlag
    }
}
