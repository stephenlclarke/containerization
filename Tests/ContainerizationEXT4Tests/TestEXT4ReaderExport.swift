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
    private func selectedFixture() throws -> (URL, Data) {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        let source = FilePath(directory.appendingPathComponent("selected-source.ext4").path)
        let payload = Data("selected export payload\n".utf8)
        let formatter = try EXT4.Formatter(source, minDiskSize: 4 * 1024 * 1024)
        try formatter.create(path: FilePath("/real"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o750))
        try formatter.create(path: FilePath("/real/deep"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o750))
        let stream = InputStream(data: payload)
        stream.open()
        defer { stream.close() }
        try formatter.create(
            path: FilePath("/real/target"),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o640),
            buf: stream,
            uid: 1000,
            gid: 1001,
            xattrs: ["user.containerization.selected": Data("kept".utf8)]
        )
        try formatter.create(path: FilePath("/relative"), link: FilePath("real/target"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        try formatter.create(path: FilePath("/absolute"), link: FilePath("/real/target"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        try formatter.create(path: FilePath("/dangling"), link: FilePath("missing/target"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        try formatter.create(path: FilePath("/parent"), link: FilePath("real"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        try formatter.create(path: FilePath("/deep-parent"), link: FilePath("real/deep"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        let lexicalTarget = InputStream(data: Data("lexical target\n".utf8))
        lexicalTarget.open()
        defer { lexicalTarget.close() }
        try formatter.create(path: FilePath("/target"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: lexicalTarget)
        try formatter.link(link: FilePath("/selected-hardlink"), target: FilePath("/real/target"))
        try formatter.close()
        return (directory, payload)
    }

    private func readSingleEntry(_ archive: URL) throws -> (WriteEntry, Data) {
        let reader = try ArchiveReader(format: .pax, filter: .none, file: archive)
        var iterator = reader.makeIterator()
        let next = iterator.next()
        let item = try #require(next)
        if let extra = iterator.next() {
            Issue.record("Expected one archive entry, found extra entry \(extra.0.path ?? "<unnamed>")")
        }
        try reader.throwIfStreamFailed()
        return item
    }

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

    @Test("selected regular paths are streamed as one named archive member with metadata")
    func exportsSelectedRegularFile() throws {
        let (directory, payload) = try selectedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("selected.tar")
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("selected-source.ext4").path))

        try reader.export(archive: FilePath(archive.path), selectedPath: FilePath("/real/target"))

        let (entry, data) = try readSingleEntry(archive)
        #expect(entry.path == "target")
        #expect(entry.fileType == .regular)
        #expect(entry.permissions & 0o777 == 0o640)
        #expect(entry.owner == 1000)
        #expect(entry.group == 1001)
        #expect(entry.xattrs["user.containerization.selected"] == Data("kept".utf8))
        #expect(data == payload)
    }

    @Test("selected symlinks retain their name, resolve parents, and optionally follow the final link")
    func exportsSelectedSymlinks() throws {
        let (directory, payload) = try selectedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FilePath(directory.appendingPathComponent("selected-source.ext4").path)
        let reader = try EXT4.EXT4Reader(blockDevice: source)

        for (path, target) in [("/relative", "real/target"), ("/absolute", "/real/target")] {
            let archive = directory.appendingPathComponent("link.tar")
            try reader.export(archive: FilePath(archive.path), selectedPath: FilePath(path))
            let (entry, data) = try readSingleEntry(archive)
            #expect(entry.path == String(path.dropFirst()))
            #expect(entry.fileType == .symbolicLink)
            #expect(entry.symlinkTarget == target)
            #expect(data.isEmpty)

            try reader.export(archive: FilePath(archive.path), selectedPath: FilePath(path), followSymlink: true)
            let (followedEntry, followedData) = try readSingleEntry(archive)
            #expect(followedEntry.path == String(path.dropFirst()))
            #expect(followedEntry.fileType == .regular)
            #expect(followedData == payload)
        }

        let danglingArchive = directory.appendingPathComponent("dangling.tar")
        try reader.export(archive: FilePath(danglingArchive.path), selectedPath: FilePath("/dangling"))
        let (danglingEntry, _) = try readSingleEntry(danglingArchive)
        #expect(danglingEntry.fileType == .symbolicLink)
        #expect(danglingEntry.symlinkTarget == "missing/target")
        #expect(throws: EXT4.PathIOError.self) {
            try reader.export(archive: FilePath(danglingArchive.path), selectedPath: FilePath("/dangling"), followSymlink: true)
        }

        let parentArchive = directory.appendingPathComponent("parent.tar")
        try reader.export(archive: FilePath(parentArchive.path), selectedPath: FilePath("/parent/target"))
        let (parentEntry, parentData) = try readSingleEntry(parentArchive)
        #expect(parentEntry.path == "target")
        #expect(parentEntry.fileType == .regular)
        #expect(parentData == payload)

        let parentDotDotArchive = directory.appendingPathComponent("parent-dot-dot.tar")
        try reader.export(archive: FilePath(parentDotDotArchive.path), selectedPath: FilePath("/deep-parent/../target"))
        let (parentDotDotEntry, parentDotDotData) = try readSingleEntry(parentDotDotArchive)
        #expect(parentDotDotEntry.path == "target")
        #expect(parentDotDotData == payload)
    }

    @Test("selected hard links are emitted as standalone regular files")
    func exportsSelectedHardLinkAsRegularFile() throws {
        let (directory, payload) = try selectedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("hardlink.tar")
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("selected-source.ext4").path))

        try reader.export(archive: FilePath(archive.path), selectedPath: FilePath("/selected-hardlink"))

        let (entry, data) = try readSingleEntry(archive)
        #expect(entry.path == "selected-hardlink")
        #expect(entry.fileType == .regular)
        #expect(entry.hardlink == nil)
        #expect(data == payload)
    }

    @Test(arguments: [59, 60, 61])
    func exportsSymlinkTargetsAcrossInlineStorageBoundary(length: Int) throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = FilePath(directory.appendingPathComponent("symlink-boundary.ext4").path)
        let target = String(repeating: "x", count: length)
        let formatter = try EXT4.Formatter(image, minDiskSize: 1.mib())
        try formatter.create(
            path: FilePath("/selected-link"),
            link: FilePath(target),
            mode: EXT4.Inode.Mode(.S_IFLNK, 0o777)
        )
        try formatter.close()

        let archive = directory.appendingPathComponent("symlink-boundary.tar")
        let reader = try EXT4.EXT4Reader(blockDevice: image)
        try reader.export(archive: FilePath(archive.path), selectedPath: FilePath("/selected-link"))

        let (entry, data) = try readSingleEntry(archive)
        #expect(entry.path == "selected-link")
        #expect(entry.fileType == .symbolicLink)
        #expect(entry.symlinkTarget == target)
        #expect(data.isEmpty)
    }

    @Test("selected export rejects truncated extent-backed symlink targets")
    func rejectsTruncatedExtentBackedSymlink() throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = FilePath(directory.appendingPathComponent("truncated-symlink.ext4").path)
        let formatter = try EXT4.Formatter(image, minDiskSize: 1.mib())
        try formatter.create(path: FilePath("/real"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/real/target"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: nil)
        let validPrefix = "/real/target"
        let target = validPrefix + String(repeating: "x", count: 60)
        try formatter.create(
            path: FilePath("/selected-link"),
            link: FilePath(target),
            mode: EXT4.Inode.Mode(.S_IFLNK, 0o777)
        )
        try formatter.close()

        let originalReader = try EXT4.EXT4Reader(blockDevice: image)
        let inodeNumber = try originalReader.stat(FilePath("/selected-link"), followSymlinks: false).inodeNumber
        let extent = try #require(try originalReader.getLogicalExtents(inode: inodeNumber).first)
        let lastBlock = UInt64(originalReader.superBlock.blocksCountLow) - 1
        let group = try originalReader.getGroupDescriptor((inodeNumber - 1) / originalReader.superBlock.inodesPerGroup)
        let inodeOffset =
            UInt64(group.inodeTableLow) * originalReader.blockSize
            + UInt64((inodeNumber - 1) % originalReader.superBlock.inodesPerGroup)
            * UInt64(originalReader.superBlock.inodeSize)
        let inodeBlockOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \.block))
        let startHighOffset = try #require(MemoryLayout<EXT4.ExtentLeaf>.offset(of: \.startHigh))
        let startLowOffset = try #require(MemoryLayout<EXT4.ExtentLeaf>.offset(of: \.startLow))
        let extentStartHighOffset = MemoryLayout<EXT4.ExtentHeader>.size + startHighOffset
        let extentStartLowOffset = MemoryLayout<EXT4.ExtentHeader>.size + startLowOffset
        #expect(extent.physicalBlock < lastBlock)

        let handle = try FileHandle(forUpdating: image.url)
        var startHigh = UInt16(0).littleEndian
        var startLow = UInt32(lastBlock).littleEndian
        try handle.seek(toOffset: inodeOffset + UInt64(inodeBlockOffset + extentStartHighOffset))
        try handle.write(contentsOf: withUnsafeBytes(of: &startHigh) { Data($0) })
        try handle.seek(toOffset: inodeOffset + UInt64(inodeBlockOffset + extentStartLowOffset))
        try handle.write(contentsOf: withUnsafeBytes(of: &startLow) { Data($0) })
        let lastBlockOffset = lastBlock * originalReader.blockSize
        try handle.seek(toOffset: lastBlockOffset)
        try handle.write(contentsOf: Data(validPrefix.utf8))
        try handle.truncate(atOffset: lastBlockOffset + UInt64(validPrefix.utf8.count))
        try handle.close()

        let reader = try EXT4.EXT4Reader(blockDevice: image)
        #expect(throws: EXT4.Error.invalidExtents) {
            try reader.export(
                archive: FilePath(directory.appendingPathComponent("selected.tar").path),
                selectedPath: FilePath("/selected-link")
            )
        }
        #expect(throws: EXT4.Error.invalidExtents) {
            try reader.export(
                archive: FilePath(directory.appendingPathComponent("followed.tar").path),
                selectedPath: FilePath("/selected-link"),
                followSymlink: true
            )
        }
    }

    @Test("selected export rejects root, directory, and missing paths")
    func rejectsInvalidSelectedPaths() throws {
        let (directory, _) = try selectedFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = FilePath(directory.appendingPathComponent("invalid.tar").path)
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("selected-source.ext4").path))

        #expect(throws: EXT4.PathIOError.self) {
            try reader.export(archive: archive, selectedPath: FilePath("/"))
        }
        #expect(throws: EXT4.PathIOError.self) {
            try reader.export(archive: archive, selectedPath: FilePath("/real"))
        }
        #expect(throws: EXT4.PathIOError.self) {
            try reader.export(archive: archive, selectedPath: FilePath("/missing"))
        }
    }

    @Test("clean-journal requirement rejects a recovery-marked superblock before reading groups")
    func rejectsJournalRecoveryBeforeTreeRead() throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("recovery.ext4")
        try EXT4.Formatter(FilePath(image.path), minDiskSize: 1.mib()).close()

        let file = try FileHandle(forUpdating: image)
        defer { try? file.close() }
        try file.seek(toOffset: EXT4.SuperBlockOffset)
        let superBlockSize = MemoryLayout<EXT4.SuperBlock>.size
        let superBlockRead = try file.read(upToCount: superBlockSize)
        var superBlockData = try #require(superBlockRead)
        var superBlock = superBlockData.withUnsafeBytes { $0.loadUnaligned(as: EXT4.SuperBlock.self) }
        superBlock.featureIncompat |= EXT4.IncompatFeature.recover.rawValue
        superBlockData = withUnsafeBytes(of: &superBlock) { Data($0) }
        try file.seek(toOffset: EXT4.SuperBlockOffset)
        try file.write(contentsOf: superBlockData)
        try file.truncate(atOffset: EXT4.SuperBlockOffset + UInt64(superBlockSize))
        try file.close()

        #expect(throws: EXT4.Error.journalRecoveryRequired) {
            try EXT4.EXT4Reader(blockDevice: FilePath(image.path), requireCleanJournal: true)
        }
    }

    @Test("truncated superblocks fail with an error before decoding")
    func rejectsTruncatedSuperBlock() throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("short-ext4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: image) }
        let shortLength = Int(EXT4.SuperBlockOffset) + MemoryLayout<EXT4.SuperBlock>.size - 1
        try Data(repeating: 0, count: shortLength).write(to: image)

        #expect(throws: EXT4.Error.couldNotReadSuperBlock(image.path, EXT4.SuperBlockOffset, MemoryLayout<EXT4.SuperBlock>.size)) {
            try EXT4.EXT4Reader(blockDevice: FilePath(image.path))
        }
    }

    @Test("selected export rejects inode sizes that cannot be represented by archive metadata")
    func rejectsOversizedInode() throws {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("oversized.ext4")
        let source = FilePath(image.path)
        let formatter = try EXT4.Formatter(source, minDiskSize: 1.mib())
        try formatter.create(path: FilePath("/oversized"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: nil)
        try formatter.close()

        let inodeOffset: UInt64
        do {
            let reader = try EXT4.EXT4Reader(blockDevice: source)
            let inode = try reader.stat(FilePath("/oversized")).inodeNumber
            let group = try reader.getGroupDescriptor((inode - 1) / reader.superBlock.inodesPerGroup)
            inodeOffset =
                UInt64(group.inodeTableLow) * reader.blockSize
                + UInt64((inode - 1) % reader.superBlock.inodesPerGroup) * UInt64(reader.superBlock.inodeSize)
        }

        let sizeHighOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \.sizeHigh))
        var high = UInt32(0x8000_0000).littleEndian
        let highBytes = withUnsafeBytes(of: &high) { Data($0) }
        let handle = try FileHandle(forUpdating: image)
        try handle.seek(toOffset: inodeOffset + UInt64(sizeHighOffset))
        try handle.write(contentsOf: highBytes)
        try handle.close()

        let reader = try EXT4.EXT4Reader(blockDevice: source)
        #expect(throws: EXT4.Error.invalidExtents) {
            try reader.export(archive: FilePath(directory.appendingPathComponent("oversized.tar").path), selectedPath: FilePath("/oversized"))
        }
    }
}
