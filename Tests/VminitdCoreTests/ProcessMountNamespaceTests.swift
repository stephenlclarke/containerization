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

#if canImport(Musl)
import Musl
private typealias TestStat = Musl.stat
#elseif canImport(Glibc)
import Glibc
private typealias TestStat = Glibc.stat
#endif

@testable import VminitdCore

struct ProcessMountNamespaceTests {
    @Test func duplicateReferencesCapturedNamespace() throws {
        let namespace = try ProcessMountNamespace(pid: getpid())
        let duplicate = try namespace.duplicate()
        defer { _ = Foundation.close(duplicate) }

        let current = Foundation.open("/proc/self/ns/mnt", O_RDONLY | O_CLOEXEC)
        #expect(current >= 0)
        defer { _ = Foundation.close(current) }

        var duplicateInfo = TestStat()
        var currentInfo = TestStat()
        #expect(fstat(duplicate, &duplicateInfo) == 0)
        #expect(fstat(current, &currentInfo) == 0)
        #expect(duplicateInfo.st_dev == currentInfo.st_dev)
        #expect(duplicateInfo.st_ino == currentInfo.st_ino)
    }

    @Test func duplicateOutlivesOwningHandle() throws {
        var namespace: ProcessMountNamespace? = try ProcessMountNamespace(pid: getpid())
        let duplicate = try #require(namespace).duplicate()
        namespace = nil
        defer { _ = Foundation.close(duplicate) }

        var info = TestStat()
        #expect(fstat(duplicate, &info) == 0)
    }
}

#endif
