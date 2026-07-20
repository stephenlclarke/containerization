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

import ContainerizationArchive
import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

struct EXT4ReaderExportTests {
    @Test("exporting a directory materializes only its contents at the archive root")
    func exportsDirectoryContents() async throws {
        let temporaryDirectory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let source = FilePath(temporaryDirectory.appendingPathComponent("source.ext4").path)
        let archive = FilePath(temporaryDirectory.appendingPathComponent("subtree.tar").path)
        let fullArchive = FilePath(temporaryDirectory.appendingPathComponent("full.tar").path)
        let destination = FilePath(temporaryDirectory.appendingPathComponent("destination.ext4").path)
        let fullDestination = FilePath(temporaryDirectory.appendingPathComponent("full-destination.ext4").path)
        let seed = Data("image-data-seed\n".utf8)

        let sourceFormatter = try EXT4.Formatter(source, minDiskSize: 1.mib())
        try sourceFormatter.create(path: FilePath("/image-data"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o750), uid: 1000, gid: 1001)
        let seedStream = InputStream(data: seed)
        seedStream.open()
        defer { seedStream.close() }
        try sourceFormatter.create(
            path: FilePath("/image-data/seed.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o640),
            buf: seedStream,
            uid: 1000,
            gid: 1001,
            xattrs: ["user.containerization.export": Data("retained".utf8)],
        )
        try sourceFormatter.link(link: FilePath("/image-data/seed-link.txt"), target: FilePath("/image-data/seed.txt"))
        try sourceFormatter.create(path: FilePath("/outside"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try sourceFormatter.create(
            path: FilePath("/outside/ignored.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o644),
            buf: nil,
        )
        let linkedSeed = Data("linked-from-outside\n".utf8)
        let linkedSeedStream = InputStream(data: linkedSeed)
        linkedSeedStream.open()
        defer { linkedSeedStream.close() }
        try sourceFormatter.create(
            path: FilePath("/outside/linked.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o640),
            buf: linkedSeedStream,
        )
        try sourceFormatter.link(link: FilePath("/image-data/linked-from-outside.txt"), target: FilePath("/outside/linked.txt"))
        try sourceFormatter.close()

        let sourceReader = try EXT4.EXT4Reader(blockDevice: source)
        try sourceReader.export(archive: archive, subtree: FilePath("/image-data"))
        try sourceReader.export(archive: fullArchive)

        let destinationFormatter = try EXT4.Formatter(destination, minDiskSize: 1.mib())
        try await destinationFormatter.unpack(source: archive.url, compression: .none)
        try destinationFormatter.close()

        let destinationReader = try EXT4.EXT4Reader(blockDevice: destination)
        #expect(try destinationReader.readFile(at: FilePath("/seed.txt")) == seed)
        #expect(try destinationReader.stat(FilePath("/seed.txt")).inode.mode & 0o777 == 0o640)
        #expect(try destinationReader.stat(FilePath("/seed.txt")).inode.uid == 1000)
        #expect(try destinationReader.stat(FilePath("/seed.txt")).inode.gid == 1001)
        #expect(try destinationReader.stat(FilePath("/seed.txt")).inodeNumber == destinationReader.stat(FilePath("/seed-link.txt")).inodeNumber)
        #expect(try destinationReader.readFile(at: FilePath("/linked-from-outside.txt")) == linkedSeed)
        let seedXattrs = try EXT4.EXT4Reader.readInlineExtendedAttributes(
            from: EXT4.tupleToArray(try destinationReader.stat(FilePath("/seed.txt")).inode.inlineXattrs))
        #expect(seedXattrs.contains { $0.fullName == "user.containerization.export" && Data($0.value) == Data("retained".utf8) })
        #expect(!destinationReader.exists(FilePath("/image-data")))
        #expect(!destinationReader.exists(FilePath("/outside")))

        let fullDestinationFormatter = try EXT4.Formatter(fullDestination, minDiskSize: 1.mib())
        try await fullDestinationFormatter.unpack(source: fullArchive.url, compression: .none)
        try fullDestinationFormatter.close()
        let fullDestinationReader = try EXT4.EXT4Reader(blockDevice: fullDestination)
        #expect(try fullDestinationReader.readFile(at: FilePath("/image-data/seed.txt")) == seed)
        #expect(fullDestinationReader.exists(FilePath("/outside/ignored.txt")))
    }

    @Test("exporting a non-directory reports the directory requirement")
    func rejectsNonDirectorySubtree() throws {
        let temporaryDirectory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let source = FilePath(temporaryDirectory.appendingPathComponent("source.ext4").path)
        let archive = FilePath(temporaryDirectory.appendingPathComponent("subtree.tar").path)
        let formatter = try EXT4.Formatter(source, minDiskSize: 1.mib())
        try formatter.create(
            path: FilePath("/file.txt"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o644),
            buf: nil,
        )
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: source)
        do {
            try reader.export(archive: archive, subtree: FilePath("/file.txt"))
            Issue.record("Expected notADirectory error")
        } catch let error as EXT4.PathIOError {
            guard case .notADirectory(let path) = error else {
                Issue.record("Expected notADirectory, got \(error)")
                return
            }
            #expect(path == "/file.txt")
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }
}
