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

import ContainerizationError
import Foundation
import Testing

#if canImport(Musl)
import Musl
#else
import Glibc
#endif

@testable import VminitdCore

struct LoopbackDevicePathTests {
    @Test func acceptsStableVirtiofsPath() {
        #expect(LoopbackDevice.isTrustedBackingFilePath("/run/virtiofs/root/rootfs.ext4"))
    }

    @Test func acceptsReservedRuntimeVirtiofsPath() {
        #expect(LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-00/root/rootfs.ext4"))
        #expect(LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-63/rootfs.ext4"))
    }

    @Test func rejectsUntrustedAndMalformedPaths() {
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/virtiofs"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/virtiofs-old/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/virtiofs/root/../rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-0/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-000/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-aa/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-64/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-99/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-00"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-00/"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/run/runtime-virtiofs-00-old/rootfs.ext4"))
        #expect(!LoopbackDevice.isTrustedBackingFilePath("/tmp/rootfs.ext4"))
    }

    @Test func verifiesActiveVirtiofsMountIdentity() {
        let mountInfo = """
            36 25 0:32 / /run/virtiofs rw - virtiofs virtiofs rw
            37 25 0:33 / /run/runtime-virtiofs-00 rw - virtiofs runtime-virtiofs-00 rw
            38 25 0:34 / /run/runtime-virtiofs-01 rw - tmpfs tmpfs rw
            39 25 0:35 / /run/runtime-virtiofs-00 rw - tmpfs tmpfs rw
            """

        #expect(
            LoopbackDevice.mountInfoContainsVirtiofs(
                mountInfo,
                mountID: 36,
                root: "/run/virtiofs",
                source: "virtiofs"
            )
        )
        #expect(
            LoopbackDevice.mountInfoContainsVirtiofs(
                mountInfo,
                mountID: 37,
                root: "/run/runtime-virtiofs-00",
                source: "runtime-virtiofs-00"
            )
        )
        #expect(
            !LoopbackDevice.mountInfoContainsVirtiofs(
                mountInfo,
                mountID: 38,
                root: "/run/runtime-virtiofs-01",
                source: "runtime-virtiofs-01"
            )
        )
        #expect(
            !LoopbackDevice.mountInfoContainsVirtiofs(
                mountInfo,
                mountID: 37,
                root: "/run/runtime-virtiofs-00",
                source: "runtime-virtiofs-01"
            )
        )
        #expect(
            !LoopbackDevice.mountInfoContainsVirtiofs(
                mountInfo,
                mountID: 39,
                root: "/run/runtime-virtiofs-00",
                source: "runtime-virtiofs-00"
            )
        )
    }

    @Test func readsMountIDFromDescriptorInfo() {
        let descriptorInfo = """
            pos:\t0
            flags:\t012000000
            mnt_id:\t37
            ino:\t1
            """

        #expect(LoopbackDevice.mountID(fromDescriptorInfo: descriptorInfo) == 37)
        #expect(LoopbackDevice.mountID(fromDescriptorInfo: "pos:\t0\n") == nil)
    }

    @Test func opensOnlyFilesBelowRootWithoutSymlinks() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedDirectory = temporaryRoot.appendingPathComponent("nested", isDirectory: true)
        let backingFile = nestedDirectory.appendingPathComponent("rootfs.ext4")
        let escapedFile = temporaryRoot.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).ext4")
        let symlink = temporaryRoot.appendingPathComponent("escape", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: escapedFile)
        }

        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("rootfs".utf8).write(to: backingFile)
        try Data("escape".utf8).write(to: escapedFile)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: escapedFile.deletingLastPathComponent()
        )

        let rootDescriptor = open(temporaryRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(rootDescriptor >= 0)
        guard rootDescriptor >= 0 else { return }
        defer { _ = close(rootDescriptor) }

        let backingDescriptor = try LoopbackDevice.openBackingFile(
            rootDescriptor: rootDescriptor,
            relativePath: "nested/rootfs.ext4"
        )
        _ = close(backingDescriptor)

        #expect(throws: ContainerizationError.self) {
            try LoopbackDevice.openBackingFile(
                rootDescriptor: rootDescriptor,
                relativePath: "escape/\(escapedFile.lastPathComponent)"
            )
        }
    }
}

#endif
