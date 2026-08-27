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

#if os(macOS)

import ContainerizationError
import ContainerizationExtras
import Foundation
import Testing
import Virtualization

@testable import Containerization

struct VZHotplugProviderTests {
    @Test func ordinaryVZConfigurationReservesRuntimeShareDevices() throws {
        let configuration = VZVirtualMachineInstance.withDefaultRuntimeDirectoryShare(
            .init()
        )
        let runtimeShare = try #require(
            configuration.extensions.first as? VZPreexposedDirectoryShare
        )

        #expect(runtimeShare.roots.isEmpty)
        #expect(runtimeShare.runtimeDeviceTags.count == 16)
    }

    @Test func preexposedGuestPathUsesMostSpecificContainingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("containers", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = nested.appendingPathComponent("alpha/rootfs.ext4")
        try FileManager.default.createDirectory(
            at: image.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: image)

        let guestPath = VZHotplugProvider.preexposedGuestPath(
            for: image.path,
            in: [
                .init(tag: "broad", source: root.path, readOnly: false),
                .init(tag: "specific", source: nested.path, readOnly: false),
            ],
            requiresWrite: true
        )

        #expect(guestPath == "/run/virtiofs/specific/alpha/rootfs.ext4")
    }

    @Test func preexposedGuestPathRejectsPrefixSiblingAndReadOnlyWrite() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("containers", isDirectory: true)
        let sibling = parent.appendingPathComponent("containers-old/rootfs.ext4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sibling.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: sibling)
        defer { try? FileManager.default.removeItem(at: parent) }

        let readOnly = VZHotplugProvider.PreexposedDirectory(
            tag: "runtime",
            source: root.path,
            readOnly: true
        )
        #expect(
            VZHotplugProvider.preexposedGuestPath(
                for: sibling.path,
                in: [readOnly],
                requiresWrite: false
            ) == nil
        )
        #expect(
            VZHotplugProvider.preexposedGuestPath(
                for: root.path,
                in: [readOnly],
                requiresWrite: true
            ) == nil
        )
        #expect(
            VZHotplugProvider.preexposedGuestPath(
                for: root.path,
                in: [readOnly],
                requiresWrite: false
            ) == "/run/virtiofs/runtime"
        )
    }

    @Test func extensionAddsWritableRootToBootShare() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = VZVirtualMachineConfiguration()
        let device = VZVirtioFileSystemDeviceConfiguration(tag: "virtiofs")
        device.share = VZMultipleDirectoryShare(directories: [:])
        configuration.directorySharingDevices = [device]

        try VZPreexposedDirectoryShare(
            roots: [root],
            runtimeDeviceCount: 2
        ).configureVZ(
            &configuration,
            allocator: Character.blockDeviceTagAllocator(),
            storageDeviceCount: 0,
            mountsByID: [:]
        )

        let tag = try hashFilePath(path: root.path)
        let unified = try #require(device.share as? VZMultipleDirectoryShare)
        let sharedRoot = try #require(unified.directories[tag])
        #expect(sharedRoot.url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        #expect(!sharedRoot.isReadOnly)
        #expect(
            configuration.directorySharingDevices
                .compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
                .map(\.tag)
                .sorted()
                == ["runtime-virtiofs-00", "runtime-virtiofs-01", "virtiofs"]
        )
    }

    @Test func runtimeSharePoolDoesNotReplaceReferencedDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var pool = VZRuntimeDirectorySharePool(
            deviceTags: ["runtime-virtiofs-01", "runtime-virtiofs-00"]
        )
        let firstReadOnly = VZRuntimeDirectorySharePool.Reference(
            tag: "first",
            readOnly: true
        )
        let firstWritable = VZRuntimeDirectorySharePool.Reference(
            tag: "first",
            readOnly: false
        )
        let secondWritable = VZRuntimeDirectorySharePool.Reference(
            tag: "second",
            readOnly: false
        )

        #expect(
            try pool.acquire(firstReadOnly, source: first.path)
                == .init(deviceTag: "runtime-virtiofs-00", newlyAssigned: true)
        )
        #expect(
            try pool.acquire(firstReadOnly, source: first.path)
                == .init(deviceTag: "runtime-virtiofs-00", newlyAssigned: false)
        )
        #expect(
            try pool.acquire(firstWritable, source: first.path)
                == .init(deviceTag: "runtime-virtiofs-01", newlyAssigned: true)
        )
        #expect(throws: ContainerizationError.self) {
            try pool.acquire(secondWritable, source: second.path)
        }
        #expect(pool.devicesReleased(by: [firstReadOnly]).isEmpty)
        #expect(
            pool.devicesReleased(by: [firstReadOnly, firstReadOnly])
                == ["runtime-virtiofs-00"]
        )

        #expect(pool.release([firstReadOnly]).isEmpty)
        #expect(pool.release([firstReadOnly]) == ["runtime-virtiofs-00"])
        #expect(
            try pool.acquire(secondWritable, source: second.path)
                == .init(deviceTag: "runtime-virtiofs-00", newlyAssigned: true)
        )
    }
}

#endif
