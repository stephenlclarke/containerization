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

import CShim

enum FilesystemPathResolver {
    /// Opens `path` beneath a pinned filesystem root. `RESOLVE_IN_ROOT`
    /// contains absolute paths, `..`, and ordinary symlinks, while
    /// `RESOLVE_NO_MAGICLINKS` blocks procfs links that can reference another
    /// process's filesystem context.
    static func open(root: Int32, path: String, flags: Int32) -> Int32 {
        path.withCString { path in
            var how = cz_open_how(
                flags: UInt64(flags),
                mode: 0,
                resolve: UInt64(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)
            )
            return CZ_openat2(root, path, &how, MemoryLayout<cz_open_how>.size)
        }
    }
}

#endif
