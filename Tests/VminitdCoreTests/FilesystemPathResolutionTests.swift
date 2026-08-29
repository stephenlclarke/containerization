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

import Foundation
import Testing

@testable import VminitdCore

struct FilesystemPathResolutionTests {
    @Test func opensAPathInsideThePinnedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let target = fixture.root.appendingPathComponent("target")
        try Data("inside".utf8).write(to: target)

        let fd = FilesystemPathResolver.open(root: fixture.rootDescriptor, path: "/target", flags: O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        if fd >= 0 {
            _ = Foundation.close(fd)
        }
    }

    @Test func rejectsAParentTraversalSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let outside = fixture.directory.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appendingPathComponent("escape").path,
            withDestinationPath: "../outside"
        )

        let fd = FilesystemPathResolver.open(root: fixture.rootDescriptor, path: "/escape", flags: O_RDONLY | O_CLOEXEC)
        let openError = errno
        #expect(fd < 0)
        #expect(openError == ENOENT)
        if fd >= 0 {
            _ = Foundation.close(fd)
        }
    }

    @Test func rejectsProcfsMagicLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("inside".utf8).write(to: fixture.root.appendingPathComponent("target"))

        let root = Foundation.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(root >= 0)
        defer { _ = Foundation.close(root) }

        let exposedDirectory = Foundation.open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(exposedDirectory >= 0)
        defer { _ = Foundation.close(exposedDirectory) }

        // The procfs descriptor link is deliberately intermediate. O_NOFOLLOW
        // alone protects only the final component and would otherwise open the
        // regular `target` file successfully.
        let path = "/proc/self/fd/\(exposedDirectory)/target"
        let fd = FilesystemPathResolver.open(root: root, path: path, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let openError = errno
        #expect(fd < 0)
        #expect(openError == ELOOP)
        if fd >= 0 {
            _ = Foundation.close(fd)
        }
    }

    private final class Fixture {
        let directory: URL
        let root: URL
        let rootDescriptor: Int32

        init() throws {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.root = self.directory.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            self.rootDescriptor = Foundation.open(self.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard self.rootDescriptor >= 0 else {
                throw POSIXError(.EBADF)
            }
        }

        func remove() {
            _ = Foundation.close(self.rootDescriptor)
            try? FileManager.default.removeItem(at: self.directory)
        }
    }
}

#endif
