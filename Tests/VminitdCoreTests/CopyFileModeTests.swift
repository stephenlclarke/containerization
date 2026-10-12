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
import GRPCCore
import Testing

#if canImport(Musl)
import Musl
private typealias TestStat = Musl.stat
#elseif canImport(Glibc)
import Glibc
private typealias TestStat = Glibc.stat
#endif

@testable import VminitdCore

struct CopyFileModeTests {
    @Test func copyInModeEncodingPreservesLegacyDefaultAndExplicitZero() {
        #expect(resolveCopyInFileMode(0) == 0o644)
        #expect(resolveCopyInFileMode(UInt32(S_IFREG)) == 0)
        #expect(resolveCopyInFileMode(UInt32(S_IFREG) | 0o640) == 0o640)
        #expect(resolveCopyInFileMode(0o755) == 0o755)
    }

    @Test func copyInAppliesRequestedModeWithoutChangingOwnership() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("copy-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        let fd = Foundation.open(file.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        try #require(fd >= 0)
        defer { _ = Foundation.close(fd) }

        var original = TestStat()
        try #require(fstat(fd, &original) == 0)

        for expectedMode: mode_t in [0o640, 0o664, 0o755] {
            try applyCopyInFileMode(fd: fd, mode: expectedMode, path: file.path)

            var copied = TestStat()
            try #require(fstat(fd, &copied) == 0)
            #expect(copied.st_mode & 0o777 == expectedMode)
            #expect(copied.st_uid == original.st_uid)
            #expect(copied.st_gid == original.st_gid)
        }
    }

    @Test func copyInCanApplyExplicitZeroModeToARealFileDescriptor() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("copy-mode-zero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        let fd = Foundation.open(file.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        try #require(fd >= 0)
        defer { _ = Foundation.close(fd) }

        let mode = resolveCopyInFileMode(UInt32(S_IFREG))
        try applyCopyInFileMode(fd: fd, mode: mode, path: file.path)

        var copied = TestStat()
        try #require(fstat(fd, &copied) == 0)
        #expect(copied.st_mode & 0o777 == 0)
    }

    @Test func copyInModeReportsInvalidFileDescriptor() {
        #expect(throws: RPCError.self) {
            try applyCopyInFileMode(fd: -1, mode: 0o640, path: "/copy-target")
        }
    }
}

#endif
