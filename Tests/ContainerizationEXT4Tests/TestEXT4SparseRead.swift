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

@Suite
struct EXT4SparseReadTests {
    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func fixture(allHoles: Bool = false, invalidPhysical: Bool = false, invalidMagic: Bool = false) throws -> (URL, Data, Int) {
        let directory = FileManager.default.uniqueTemporaryDirectory()
        let image = directory.appendingPathComponent("source.ext4")
        let formatter = try EXT4.Formatter(FilePath(image.path), minDiskSize: 4 * 1024 * 1024)
        let blockSize = 4096
        let backing = Data(repeating: 0x41, count: blockSize) + Data(repeating: 0x7f, count: blockSize) + Data(repeating: 0x43, count: blockSize)
        let stream = InputStream(data: backing)
        stream.open()
        defer { stream.close() }
        try formatter.create(path: "/z-outside/data", mode: EXT4.Inode.Mode(.S_IFREG, 0o640), buf: stream)
        try formatter.link(link: "/a-selected/alias", target: "/z-outside/data")
        try formatter.link(link: "/a-selected/second", target: "/z-outside/data")
        try formatter.close()
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path))
        let info = try reader.stat("/z-outside/data")
        let physical = invalidPhysical ? reader.superBlock.blocksCountLow : try #require(try reader.getExtents(inode: info.inodeNumber)?.first).start
        #expect(reader.blockSize == UInt64(blockSize))
        let descriptor = try reader.getGroupDescriptor((info.inodeNumber - 1) / reader.superBlock.inodesPerGroup)
        let inodeOffset =
            UInt64(descriptor.inodeTableLow) * reader.blockSize
            + UInt64((info.inodeNumber - 1) % reader.superBlock.inodesPerGroup) * UInt64(reader.superBlock.inodeSize)
        let blockOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \.block))
        let sizeOffset = try #require(MemoryLayout<EXT4.Inode>.offset(of: \.sizeLow))
        let size = 6 * blockSize + 17
        var extents = littleEndian(UInt16(invalidMagic ? 0 : 0xf30a)) + littleEndian(UInt16(allHoles ? 0 : 3))
        extents += littleEndian(UInt16(4)) + littleEndian(UInt16(0)) + littleEndian(UInt32(0))
        if !allHoles {
            for (logical, length, physicalBlock) in [(UInt32(1), UInt16(1), physical), (3, 0x8001, physical + 1), (4, 1, physical + 2)] {
                extents += littleEndian(logical) + littleEndian(length) + littleEndian(UInt16(0)) + littleEndian(physicalBlock)
            }
        }
        extents += Data(repeating: 0, count: 60 - extents.count)
        let handle = try FileHandle(forUpdating: image)
        defer { try? handle.close() }
        try handle.seek(toOffset: inodeOffset + UInt64(blockOffset))
        try handle.write(contentsOf: extents)
        try handle.seek(toOffset: inodeOffset + UInt64(sizeOffset))
        try handle.write(contentsOf: littleEndian(UInt32(size)))
        var expected = Data(count: size)
        if !allHoles {
            expected.replaceSubrange(blockSize..<2 * blockSize, with: Data(repeating: 0x41, count: blockSize))
            expected.replaceSubrange(4 * blockSize..<5 * blockSize, with: Data(repeating: 0x43, count: blockSize))
        }
        return (directory, expected, blockSize)
    }

    @Test(arguments: [false, true])
    func readsLogicalHolesAndUnwrittenExtents(allHoles: Bool) throws {
        let (directory, expected, blockSize) = try fixture(allHoles: allHoles)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("source.ext4").path))
        #expect(try reader.readFile(at: "/z-outside/data") == expected)
        for offset in [0, blockSize - 7, blockSize + 13, 2 * blockSize - 2, 3 * blockSize + 5, 4 * blockSize + 19, 6 * blockSize, expected.count, expected.count + 20] {
            let count = blockSize + 21
            let start = min(offset, expected.count)
            let wanted = Data(expected[start..<min(start + count, expected.count)])
            #expect(try reader.readFile(at: "/a-selected/alias", offset: UInt64(offset), count: count) == wanted)
            var buffer = [UInt8](repeating: 0xee, count: count)
            let read = try buffer.withUnsafeMutableBytes { try reader.readFile(at: "/z-outside/data", into: $0, offset: UInt64(offset)) }
            #expect(read == wanted.count)
            #expect(Data(buffer.prefix(read)) == wanted)
            #expect(buffer.dropFirst(read).allSatisfy { $0 == 0xee })
        }
    }

    @Test(arguments: [false, true])
    func exportsLogicalContentAndHardlinks(allHoles: Bool) async throws {
        let (directory, expected, _) = try fixture(allHoles: allHoles)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("source.ext4").path))
        for subtree in ["/", "/a-selected"] {
            let name = subtree == "/" ? "full" : "subtree"
            let archive = directory.appendingPathComponent(name + ".tar")
            try reader.export(archive: FilePath(archive.path), subtree: FilePath(subtree))
            let destination = directory.appendingPathComponent(name + ".ext4")
            let formatter = try EXT4.Formatter(FilePath(destination.path), minDiskSize: 4 * 1024 * 1024)
            try await formatter.unpack(source: archive, compression: .none)
            try formatter.close()
            let exported = try EXT4.EXT4Reader(blockDevice: FilePath(destination.path))
            let alias = FilePath(subtree == "/" ? "/a-selected/alias" : "/alias")
            let second = FilePath(subtree == "/" ? "/a-selected/second" : "/second")
            #expect(try exported.readFile(at: alias) == expected)
            #expect(try exported.readFile(at: second) == expected)
            #expect(try exported.stat(alias).inodeNumber == exported.stat(second).inodeNumber)
            if subtree == "/" { #expect(try exported.readFile(at: "/z-outside/data") == expected) }
        }
    }
    @Test
    func rejectsOutOfDeviceExtentsBeforeWritingBuffer() throws {
        let (directory, _, _) = try fixture(invalidPhysical: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("source.ext4").path))
        var buffer = [UInt8](repeating: 0xee, count: 4096)
        #expect(throws: EXT4.Error.invalidExtents) {
            try buffer.withUnsafeMutableBytes { _ = try reader.readFile(at: "/z-outside/data", into: $0) }
        }
        #expect(buffer.allSatisfy { $0 == 0xee })
        #expect(throws: EXT4.Error.invalidExtents) {
            try reader.export(archive: FilePath(directory.appendingPathComponent("invalid.tar").path))
        }
    }

    @Test
    func truncatedMediaAllowsPartialReadButCannotProduceSuccessfulExport() throws {
        let (directory, expected, blockSize) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("source.ext4")
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path))
        let inode = try reader.stat("/z-outside/data").inodeNumber
        let physical = try #require(try reader.getExtents(inode: inode)?.first).start
        let handle = try FileHandle(forUpdating: image)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(physical + 2) * UInt64(blockSize))
        let partial = try reader.readFileBytesFromExtents(inodeNum: inode, offset: 0, count: UInt64(expected.count))
        #expect(partial == Data(expected.prefix(4 * blockSize)))
        #expect(throws: EXT4.Error.invalidExtents) {
            try reader.export(archive: FilePath(directory.appendingPathComponent("truncated.tar").path))
        }
    }

    @Test
    func corruptMappingCannotBeMistakenForAnAllHoleFile() throws {
        let (directory, _, _) = try fixture(invalidMagic: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(directory.appendingPathComponent("source.ext4").path))
        #expect(throws: EXT4.Error.invalidExtents) {
            _ = try reader.readFile(at: "/z-outside/data")
        }
        #expect(throws: EXT4.Error.invalidExtents) {
            try reader.export(archive: FilePath(directory.appendingPathComponent("corrupt.tar").path))
        }
    }

}
