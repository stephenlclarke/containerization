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
    @Test func duplicatesReferenceCapturedFilesystemContext() throws {
        let namespace = try ProcessMountNamespace(pid: getpid())
        let root = try ProcessRoot(pid: getpid())
        let namespaceDuplicate = try namespace.duplicate()
        let rootDuplicate = try root.duplicate()
        defer {
            _ = Foundation.close(namespaceDuplicate)
            _ = Foundation.close(rootDuplicate)
        }

        let currentNamespace = Foundation.open("/proc/self/ns/mnt", O_RDONLY | O_CLOEXEC)
        let currentRoot = Foundation.open("/proc/self/root", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(currentNamespace >= 0)
        #expect(currentRoot >= 0)
        defer {
            _ = Foundation.close(currentNamespace)
            _ = Foundation.close(currentRoot)
        }

        var namespaceDuplicateInfo = TestStat()
        var currentNamespaceInfo = TestStat()
        #expect(fstat(namespaceDuplicate, &namespaceDuplicateInfo) == 0)
        #expect(fstat(currentNamespace, &currentNamespaceInfo) == 0)
        #expect(namespaceDuplicateInfo.st_dev == currentNamespaceInfo.st_dev)
        #expect(namespaceDuplicateInfo.st_ino == currentNamespaceInfo.st_ino)

        var rootDuplicateInfo = TestStat()
        var currentRootInfo = TestStat()
        #expect(fstat(rootDuplicate, &rootDuplicateInfo) == 0)
        #expect(fstat(currentRoot, &currentRootInfo) == 0)
        #expect(rootDuplicateInfo.st_dev == currentRootInfo.st_dev)
        #expect(rootDuplicateInfo.st_ino == currentRootInfo.st_ino)
    }

    @Test func duplicateOutlivesOwningHandle() throws {
        var namespace: ProcessMountNamespace? = try ProcessMountNamespace(pid: getpid())
        var root: ProcessRoot? = try ProcessRoot(pid: getpid())
        let namespaceDuplicate = try #require(namespace).duplicate()
        let rootDuplicate = try #require(root).duplicate()
        namespace = nil
        root = nil
        defer {
            _ = Foundation.close(namespaceDuplicate)
            _ = Foundation.close(rootDuplicate)
        }

        var namespaceInfo = TestStat()
        var rootInfo = TestStat()
        #expect(fstat(namespaceDuplicate, &namespaceInfo) == 0)
        #expect(fstat(rootDuplicate, &rootInfo) == 0)
    }
}

#endif
