//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

extension EXT4.EXT4Reader {
    /// Exports the complete filesystem as a portable archive.
    public func export(archive: FilePath) throws {
        try export(archive: archive, subtree: FilePath("/"))
    }

    /// Exports the contents of a directory in this filesystem as a portable archive.
    ///
    /// The selected directory is the archive root, so its children appear at the
    /// archive root instead of beneath the directory's original path. This keeps
    /// the operation useful for materializing a filesystem subtree elsewhere.
    public func export(archive: FilePath, subtree: FilePath) throws {
        let source = subtree.lexicallyNormalized()
        let (_, sourceInode) = try stat(source, followSymlinks: false)
        guard sourceInode.mode.isDir() else {
            throw EXT4.PathIOError.notADirectory(source.description)
        }
        guard let sourceNode = tree.lookup(path: source) else {
            throw EXT4.PathIOError.notFound(source.description)
        }

        let config = ArchiveWriterConfiguration(
            format: .paxRestricted, filter: .none, options: [Options.xattrformat(.schily)])
        let writer = try ArchiveWriter(configuration: config)
        try writer.open(file: archive.url)
        var items = sourceNode.pointee.children.map { (node: $0, archivePath: FilePath($0.pointee.name)) }
        var hardlinkTargets: [EXT4.InodeNumber: FilePath] = [:]

        while items.count > 0 {
            let (itemPtr, archivePath) = items.removeFirst()
            let item = itemPtr.pointee
            let inode = try self.getInode(number: item.inode)
            let entry = try archiveEntry(for: inode, path: archivePath)
            let mode = inode.mode
            let size: UInt64 = (UInt64(inode.sizeHigh) << 32) | UInt64(inode.sizeLow)
            hardlinkTargets[item.inode] = archivePath

            if mode.isDir() {
                entry.fileType = .directory
                for child in item.children {
                    items.append((node: child, archivePath: archivePath.join(child.pointee.name)))
                }
                try writer.writeEntry(entry: entry, data: nil)
            } else if mode.isReg() {
                entry.fileType = .regular
                var data = Data()
                var remaining: UInt64 = size
                if let block = item.blocks {
                    for dataBlock in block.start..<block.end {
                        try self.seek(block: dataBlock)
                        var count: UInt64
                        if remaining > self.blockSize {
                            count = self.blockSize
                        } else {
                            count = remaining
                        }
                        guard let dataBytes = try self.handle.read(upToCount: Int(count)) else {
                            throw EXT4.Error.couldNotReadBlock(dataBlock)
                        }
                        data.append(dataBytes)
                        remaining -= UInt64(dataBytes.count)
                    }
                }
                if let additionalBlocks = item.additionalBlocks {
                    for block in additionalBlocks {
                        for dataBlock in block.start..<block.end {
                            try self.seek(block: dataBlock)
                            var count: UInt64
                            if remaining > self.blockSize {
                                count = self.blockSize
                            } else {
                                count = remaining
                            }
                            guard let dataBytes = try self.handle.read(upToCount: Int(count)) else {
                                throw EXT4.Error.couldNotReadBlock(dataBlock)
                            }
                            data.append(dataBytes)
                            remaining -= UInt64(dataBytes.count)
                        }
                    }
                }
                try writer.writeEntry(entry: entry, data: data)
            } else if mode.isLink() {
                entry.fileType = .symbolicLink
                if size < 60 {
                    let linkBytes = EXT4.tupleToArray(inode.block)
                    entry.symlinkTarget = String(bytes: linkBytes.prefix(Int(size)), encoding: .utf8) ?? ""
                } else {
                    if let block = item.blocks {
                        try self.seek(block: block.start)
                        guard let linkBytes = try self.handle.read(upToCount: Int(size)) else {
                            throw EXT4.Error.couldNotReadBlock(block.start)
                        }
                        entry.symlinkTarget = String(bytes: linkBytes, encoding: .utf8) ?? ""
                    }
                }
                try writer.writeEntry(entry: entry, data: nil)
            } else {  // do not process sockets, fifo, character and block devices
                continue
            }
        }
        for (path, number) in self.hardlinks.sorted(by: { $0.key.description < $1.key.description }) {
            guard let archivePath = archivePath(for: path, beneath: source) else {
                continue
            }
            let inode = try self.getInode(number: number)
            let entry = try archiveEntry(for: inode, path: archivePath)
            if let targetPath = hardlinkTargets[number] {
                entry.hardlink = targetPath.description
                try writer.writeEntry(entry: entry, data: nil)
            } else {
                // The primary name for a hard link can live outside the selected
                // subtree. Materialize its first in-subtree name as a regular file
                // so the archive does not reference a path that it does not contain.
                entry.fileType = .regular
                let size = (UInt64(inode.sizeHigh) << 32) | UInt64(inode.sizeLow)
                try writer.writeEntry(entry: entry, data: try fileData(inode: number, size: size))
                hardlinkTargets[number] = archivePath
            }
        }
        try writer.finishEncoding()
    }

    private func archiveEntry(for inode: EXT4.Inode, path: FilePath) throws -> WriteEntry {
        let entry = WriteEntry()
        var attributes: [EXT4.ExtendedAttribute] = []
        let inlineAttributes: [UInt8] = EXT4.tupleToArray(inode.inlineXattrs)
        if !inlineAttributes.allZeros {
            try attributes.append(contentsOf: Self.readInlineExtendedAttributes(from: inlineAttributes))
        }
        if inode.xattrBlockLow != 0 {
            let block = inode.xattrBlockLow
            try self.seek(block: block)
            guard let buffer = try self.handle.read(upToCount: Int(self.blockSize)) else {
                throw EXT4.Error.couldNotReadBlock(block)
            }
            try attributes.append(contentsOf: Self.readBlockExtendedAttributes(from: [UInt8](buffer)))
        }

        var xattrs: [String: Data] = [:]
        for attribute in attributes where attribute.fullName != "system.data" {
            xattrs[attribute.fullName] = Data(attribute.value)
        }

        let size = (UInt64(inode.sizeHigh) << 32) | UInt64(inode.sizeLow)
        entry.path = path.description
        entry.size = Int64(size)
        entry.permissions = mode_t(inode.mode)
        entry.group = gid_t(inode.gidHigh) << 16 | gid_t(inode.gid)
        entry.owner = uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)
        entry.creationDate = Date(fsTimestamp: UInt64(inode.crtimeExtra) << 32 | UInt64(inode.crtime))
        entry.modificationDate = Date(fsTimestamp: UInt64(inode.mtimeExtra) << 32 | UInt64(inode.mtime))
        entry.contentAccessDate = Date(fsTimestamp: UInt64(inode.atimeExtra) << 32 | UInt64(inode.atime))
        entry.xattrs = xattrs
        return entry
    }

    private func fileData(inode: EXT4.InodeNumber, size: UInt64) throws -> Data {
        var data = Data()
        var remaining = size
        for blockRange in try getExtents(inode: inode) ?? [] {
            for dataBlock in blockRange.start..<blockRange.end {
                guard remaining > 0 else {
                    return data
                }
                try seek(block: dataBlock)
                let count = min(remaining, blockSize)
                guard let dataBytes = try handle.read(upToCount: Int(count)) else {
                    throw EXT4.Error.couldNotReadBlock(dataBlock)
                }
                data.append(dataBytes)
                remaining -= UInt64(dataBytes.count)
            }
        }
        return data
    }

    /// Returns an archive-relative path when `path` is inside `root`.
    private func archivePath(for path: FilePath, beneath root: FilePath) -> FilePath? {
        let rootComponents = normalizedPathComponents(root)
        let pathComponents = normalizedPathComponents(path)
        guard pathComponents.starts(with: rootComponents) else {
            return nil
        }
        let relativeComponents = pathComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.isEmpty else {
            return nil
        }
        return FilePath(relativeComponents.joined(separator: "/"))
    }

    /// Normalizes FilePath components for containment comparisons.
    private func normalizedPathComponents(_ path: FilePath) -> [String] {
        path.lexicallyNormalized().items.filter { component in
            component != "/" && component != "." && !component.isEmpty
        }
    }

    @available(*, deprecated, renamed: "readInlineExtendedAttributes(from:)")
    public static func readInlineExtenedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        try readInlineExtendedAttributes(from: buffer)
    }

    public static func readInlineExtendedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        let header = buffer[0..<4].withUnsafeBytes { $0.loadLittleEndian(as: UInt32.self) }
        if header != EXT4.XAttrHeaderMagic {
            throw EXT4.FileXattrsState.Error.missingXAttrHeader
        }
        return try EXT4.FileXattrsState.read(buffer: buffer, start: 4, offset: 4)
    }

    @available(*, deprecated, renamed: "readBlockExtendedAttributes(from:)")
    public static func readBlockExtenedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        try readBlockExtendedAttributes(from: buffer)
    }

    public static func readBlockExtendedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        let header = buffer[0..<4].withUnsafeBytes { $0.loadLittleEndian(as: UInt32.self) }
        if header != EXT4.XAttrHeaderMagic {
            throw EXT4.FileXattrsState.Error.missingXAttrHeader
        }

        return try EXT4.FileXattrsState.read(buffer: [UInt8](buffer), start: 32, offset: 0)
    }

    func seek(block: UInt32) throws {
        try self.handle.seek(toOffset: UInt64(block) * blockSize)
    }
}

extension Date {
    init(fsTimestamp: UInt64) {
        if fsTimestamp == 0 {
            self = Date.distantPast
            return
        }

        // 32 bits - base: seconds since January 1, 1970, signed (negative for pre-1970 dates)
        // 2 bits - epoch: overflow counter (0-3), how many times the 32-bit seconds field has wrapped
        // 30 bits - nanoseconds (0-999,999,999)
        let base = Int32(truncatingIfNeeded: fsTimestamp)
        let epoch = Int64(fsTimestamp & 0x3_0000_0000)
        let seconds = Int64(base) + epoch
        let nanoseconds = Double(fsTimestamp >> 34) / 1_000_000_000

        self = Date(timeIntervalSince1970: Double(seconds) + nanoseconds)
    }
}
