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

import Foundation
import Testing

@testable import ContainerizationOS

#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

struct MountTests {
    @Test func existingMountDirectoryIsOpenedAfterCreationRace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mountpoint = root.appendingPathComponent("mqueue")
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(rootFD >= 0)
        defer { close(rootFD) }

        let mount = Mount(type: "mqueue", source: "mqueue", target: "/dev/mqueue", options: [])
        let mountpointFD = try mount.openOrCreateMountDirectory(parentFd: rootFD, component: "mqueue")
        defer { close(mountpointFD) }

        var status = stat()
        #expect(fstat(mountpointFD, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFDIR)
    }
}
#endif
