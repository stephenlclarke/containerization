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
import ContainerizationOS
import FoundationEssentials

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

struct ContainerMount {
    private let mounts: [ContainerizationOCI.Mount]
    private let rootfs: String

    init(rootfs: String, mounts: [ContainerizationOCI.Mount]) {
        self.rootfs = rootfs
        self.mounts = mounts
    }

    func mountToRootfs() throws {
        for m in self.mounts {
            let osMount = m.toOSMount()
            try osMount.mount(root: self.rootfs)
        }
    }

    func configureConsole() throws {
        let ptmx = rootfs + "/dev/ptmx"
        let temporaryPtmx = try createTemporaryConsoleSymlink()
        defer { unlink(temporaryPtmx) }

        guard rename(temporaryPtmx, ptmx) == 0 else {
            throw App.Errno(stage: "rename(temporary pts/ptmx)")
        }
    }

    private func createTemporaryConsoleSymlink() throws -> String {
        for _ in 0..<16 {
            let path = rootfs + "/dev/.ptmx-\(UUID().uuidString)"
            if symlink("pts/ptmx", path) == 0 {
                return path
            }
            guard errno == EEXIST else {
                throw App.Errno(stage: "symlink(temporary pts/ptmx)")
            }
        }
        throw App.Failure(message: "failed to allocate temporary pts/ptmx symlink")
    }
}

extension ContainerizationOCI.Mount {
    func toOSMount() -> ContainerizationOS.Mount {
        ContainerizationOS.Mount(
            type: self.type,
            source: self.source,
            target: self.destination,
            options: self.options
        )
    }
}
