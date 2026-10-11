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

import Foundation
import SystemPackage

extension EXT4 {
    /// The `EXT4Reader` opens a block device, parses the superblock, and loads group descriptors & inodes.
    public class EXT4Reader {
        public var superBlock: EXT4.SuperBlock {
            self._superBlock
        }

        let handle: FileHandle
        let _superBlock: EXT4.SuperBlock

        private var groupDescriptors: [UInt32: EXT4.GroupDescriptor] = [:]
        private var inodes: [InodeNumber: EXT4.Inode] = [:]

        var hardlinks: [FilePath: InodeNumber] = [:]
        var tree: EXT4.FileTree = EXT4.FileTree(EXT4.RootInode, ".")
        var blockSize: UInt64 { UInt64(_superBlock.blockSize) }

        private var groupDescriptorSize: UInt16 {
            if _superBlock.featureIncompat & EXT4.IncompatFeature.bit64.rawValue != 0 {
                return _superBlock.descSize
            }
            return UInt16(MemoryLayout<EXT4.GroupDescriptor>.size)
        }

        public init(blockDevice: FilePath) throws {
            guard FileManager.default.fileExists(atPath: blockDevice.description) else {
                throw EXT4.Error.notFound(blockDevice.description)
            }

            guard let fileHandle = FileHandle(forReadingAtPath: blockDevice) else {
                throw Error.notFound(blockDevice.description)
            }
            self.handle = fileHandle
            try handle.seek(toOffset: EXT4.SuperBlockOffset)

            let superBlockSize = MemoryLayout<EXT4.SuperBlock>.size
            guard let data = try? self.handle.read(upToCount: superBlockSize) else {
                throw EXT4.Error.couldNotReadSuperBlock(blockDevice.description, EXT4.SuperBlockOffset, superBlockSize)
            }
            let sb = data.withUnsafeBytes { ptr in
                ptr.loadLittleEndian(as: EXT4.SuperBlock.self)
            }
            guard sb.magic == EXT4.SuperBlockMagic, sb.logBlockSize <= 6 else {
                throw EXT4.Error.invalidSuperBlock
            }
            self._superBlock = sb
            var items: [(item: Ptr<EXT4.FileTree.FileTreeNode>, inode: InodeNumber)] = [
                (self.tree.root, EXT4.RootInode)
            ]
            while items.count > 0 {
                guard let item = items.popLast() else {
                    break
                }
                let (itemPtr, inodeNum) = item
                let childItems = try self.children(of: inodeNum)
                let root = itemPtr.pointee
                for (itemName, itemInodeNum) in childItems {
                    if itemName == "." || itemName == ".." {
                        continue
                    }

                    if self.inodes[itemInodeNum] != nil {
                        // we have seen this inode before, we will hard link this file to it
                        guard let parentPath = itemPtr.pointee.path else {
                            continue
                        }
                        let path = parentPath.join(itemName)
                        self.hardlinks[path] = itemInodeNum
                        continue
                    }

                    let blocks = try self.getExtents(inode: itemInodeNum)
                    let itemTreeNode = FileTree.FileTreeNode(
                        inode: itemInodeNum,
                        name: itemName,
                        parent: itemPtr,
                        children: []
                    )
                    if let blocks {
                        if blocks.count > 1 {
                            itemTreeNode.additionalBlocks = Array(blocks.dropFirst())
                        }
                        itemTreeNode.blocks = blocks.first
                    }
                    let itemTreeNodePtr = Ptr(itemTreeNode)
                    root.addChild(itemTreeNodePtr)
                    itemPtr.pointee = root
                    let itemInode = try self.getInode(number: itemInodeNum)
                    if itemInode.mode.isDir() {
                        items.append((itemTreeNodePtr, itemInodeNum))
                    }
                }
            }
        }

        deinit {
            try? self.handle.close()
        }

        private func readGroupDescriptor(_ number: UInt32) throws -> GroupDescriptor {
            let bs = self.blockSize
            let offset = bs + UInt64(number) * UInt64(self.groupDescriptorSize)
            try self.handle.seek(toOffset: offset)
            guard let data = try? self.handle.read(upToCount: MemoryLayout<EXT4.GroupDescriptor>.size) else {
                throw EXT4.Error.couldNotReadGroup(number)
            }
            let gd = data.withUnsafeBytes { ptr in
                ptr.loadLittleEndian(as: EXT4.GroupDescriptor.self)
            }
            return gd
        }

        private func readInode(_ number: UInt32) throws -> Inode {
            let inodeGroupNumber = ((number - 1) / self._superBlock.inodesPerGroup)
            let numberInGroup = UInt64((number - 1) % self._superBlock.inodesPerGroup)

            let gd = try getGroupDescriptor(inodeGroupNumber)
            let inodeTableStart = UInt64(gd.inodeTableLow) * self.blockSize

            let inodeOffset: UInt64 = inodeTableStart + numberInGroup * UInt64(_superBlock.inodeSize)
            try self.handle.seek(toOffset: inodeOffset)
            guard let inodeData = try self.handle.read(upToCount: MemoryLayout<EXT4.Inode>.size) else {
                throw EXT4.Error.couldNotReadInode(number)
            }
            let inode = inodeData.withUnsafeBytes { ptr in
                ptr.loadLittleEndian(as: EXT4.Inode.self)
            }
            return inode
        }

        private func getDirTree(_ number: InodeNumber) throws -> [(String, InodeNumber)] {
            var children: [(String, InodeNumber)] = []
            let extents = try getExtents(inode: number) ?? []
            for (start, end) in extents {
                try self.seek(block: start)
                for i in 0..<(end - start) {
                    guard let dirEntryBlock = try self.handle.read(upToCount: Int(self.blockSize)) else {
                        throw EXT4.Error.couldNotReadBlock(start + i)
                    }
                    let childEntries = try getDirEntries(dirTree: dirEntryBlock)
                    children.append(contentsOf: childEntries)
                }
            }
            return children.sorted { a, b in
                a.0 < b.0
            }
        }

        internal func getDirEntries(dirTree: Data) throws -> [(String, InodeNumber)] {
            var children: [(String, InodeNumber)] = []
            var offset = 0
            let entrySize = MemoryLayout<DirectoryEntry>.size
            while offset < dirTree.count {
                // A malformed image may leave fewer than `entrySize` bytes at the
                // tail of the block. Stop before reading a fixed-size header that
                // would run past the buffer and trap in `subdata`.
                guard offset + entrySize <= dirTree.count else {
                    break
                }
                let dirEntry = dirTree.subdata(in: offset..<offset + entrySize).withUnsafeBytes {
                    $0.loadLittleEndian(as: DirectoryEntry.self)
                }
                guard dirEntry.recordLength >= entrySize else {
                    break
                }
                if dirEntry.inode == 0 {
                    offset += Int(dirEntry.recordLength)
                    continue
                }
                // `nameLength` and `recordLength` are attacker-controlled. Reject an
                // entry whose name would extend past its record or past the block,
                // which would otherwise trap in `subdata` on the read below.
                let nameStart = offset + entrySize
                let nameLength = Int(dirEntry.nameLength)
                guard Int(dirEntry.recordLength) >= entrySize + nameLength,
                    nameStart + nameLength <= dirTree.count
                else {
                    break
                }
                let nameData = dirTree.subdata(in: nameStart..<nameStart + nameLength)
                let name = String(data: nameData, encoding: .utf8) ?? ""
                children.append((name, dirEntry.inode))
                offset += Int(dirEntry.recordLength)
            }
            return children.sorted { a, b in
                a.0 < b.0
            }
        }

        func getExtents(inode: InodeNumber) throws -> [(start: UInt32, end: UInt32)]? {
            let inode = try self.getInode(number: inode)
            let inodeBlock = Data(tupleToArray(inode.block))
            return try self.decodeExtents(inodeBlock: inodeBlock)
        }

        /// Convert untrusted block coordinates without trapping on malformed geometry.
        static func checkedByteOffset(block: UInt64, blockSize: UInt64, offset: UInt64 = 0) throws -> UInt64 {
            let (base, multiplicationOverflow) = block.multipliedReportingOverflow(by: blockSize)
            let (result, additionOverflow) = base.addingReportingOverflow(offset)
            guard !multiplicationOverflow, !additionOverflow else { throw Error.invalidExtents }
            return result
        }

        struct LogicalExtent {
            let logicalBlock: UInt64
            let physicalBlock: UInt64
            let blockCount: UInt64
            let unwritten: Bool
        }

        func getLogicalExtents(inode: InodeNumber) throws -> [LogicalExtent] {
            let inode = try self.getInode(number: inode)
            let block = Data(tupleToArray(inode.block))
            guard inode.flags & InodeFlag.extents.rawValue != 0,
                block.withUnsafeBytes({ $0.loadLittleEndian(as: ExtentHeader.self) }).magic == EXT4.ExtentHeaderMagic
            else { throw Error.invalidExtents }
            return try decodeLogicalExtents(inodeBlock: block)
        }

        internal func decodeExtents(inodeBlock: Data) throws -> [(start: UInt32, end: UInt32)] {
            try decodeLogicalExtents(inodeBlock: inodeBlock).map { extent in
                guard let start = UInt32(exactly: extent.physicalBlock),
                    let end = UInt32(exactly: extent.physicalBlock + extent.blockCount)
                else { throw Error.invalidExtents }
                return (start, end)
            }
        }

        private func logicalExtent(_ leaf: ExtentLeaf) throws -> LogicalExtent {
            // ee_len == 0x8000 is an initialized 32768-block extent; only
            // values greater than 0x8000 encode unwritten extents.
            let unwritten = leaf.length > 0x8000
            let count = UInt64(unwritten ? leaf.length - 0x8000 : leaf.length)
            let logical = UInt64(leaf.block)
            let physical = UInt64(leaf.startLow) | (UInt64(leaf.startHigh) << 32)
            guard count > 0, logical + count <= UInt64(UInt32.max) + 1 else {
                throw Error.invalidExtents
            }
            return LogicalExtent(logicalBlock: logical, physicalBlock: physical, blockCount: count, unwritten: unwritten)
        }

        /// Decode the extent tree rooted in an inode's block region.
        ///
        /// `inodeBlock` is untrusted (it comes from an ext4 image), so the entry
        /// count in each extent header is validated against the bytes actually
        /// available before every fixed-size read. Without these checks a crafted
        /// `entries` count drives `subdata` past the end of the buffer and traps
        /// the process.
        internal func decodeLogicalExtents(inodeBlock: Data) throws -> [LogicalExtent] {
            var offset = 0
            var extents: [LogicalExtent] = []

            let extentHeaderSize = MemoryLayout<ExtentHeader>.size
            let extentIndexSize = MemoryLayout<ExtentIndex>.size
            let extentLeafSize = MemoryLayout<ExtentLeaf>.size
            // read extent header
            guard offset + extentHeaderSize <= inodeBlock.count else {
                return []
            }
            let header = inodeBlock.subdata(in: offset..<offset + extentHeaderSize).withUnsafeBytes {
                $0.loadLittleEndian(as: ExtentHeader.self)
            }
            guard header.magic == EXT4.ExtentHeaderMagic else {
                return []
            }
            guard header.entries <= header.max else { throw Error.invalidExtents }
            offset += extentHeaderSize  // Jump to entries
            switch header.depth {
            case 0:
                // When depth is 0 the extent header is followed by extent leaves
                for _ in 0..<header.entries {
                    guard offset + extentLeafSize <= inodeBlock.count else {
                        throw Error.invalidExtents
                    }
                    let leaf = inodeBlock.subdata(in: offset..<offset + extentLeafSize).withUnsafeBytes {
                        $0.loadLittleEndian(as: ExtentLeaf.self)
                    }
                    extents.append(try logicalExtent(leaf))
                    offset += extentLeafSize
                }
            case 1:
                // When depth is 1 the extent header is followed by extent indices which point to leaves
                for _ in 0..<header.entries {
                    guard offset + extentIndexSize <= inodeBlock.count else {
                        throw Error.invalidExtents
                    }
                    let indexNode = inodeBlock.subdata(in: offset..<offset + extentIndexSize).withUnsafeBytes {
                        $0.loadLittleEndian(as: ExtentIndex.self)
                    }
                    let indexBlock = UInt64(indexNode.leafLow) | (UInt64(indexNode.leafHigh) << 32)
                    let totalBlocks = UInt64(_superBlock.blocksCountLow) | (UInt64(_superBlock.blocksCountHigh) << 32)
                    guard indexBlock < totalBlocks else { throw Error.invalidExtents }
                    try self.handle.seek(toOffset: Self.checkedByteOffset(block: indexBlock, blockSize: self.blockSize))
                    guard let block = try self.handle.read(upToCount: Int(self.blockSize)) else {
                        throw EXT4.Error.couldNotReadBlock(indexNode.leafLow)
                    }
                    var blockOffset = 0
                    guard blockOffset + extentHeaderSize <= block.count else {
                        throw Error.invalidExtents
                    }
                    let leafHeader = block.subdata(in: blockOffset..<blockOffset + extentHeaderSize).withUnsafeBytes {
                        $0.loadLittleEndian(as: ExtentHeader.self)
                    }
                    guard leafHeader.magic == EXT4.ExtentHeaderMagic, leafHeader.depth == 0,
                        leafHeader.entries <= leafHeader.max
                    else {
                        throw Error.invalidExtents
                    }
                    blockOffset += extentHeaderSize
                    for _ in 0..<leafHeader.entries {
                        guard blockOffset + extentLeafSize <= block.count else {
                            throw Error.invalidExtents
                        }
                        let leaf = block.subdata(in: blockOffset..<blockOffset + extentLeafSize).withUnsafeBytes {
                            $0.loadLittleEndian(as: ExtentLeaf.self)
                        }
                        extents.append(try logicalExtent(leaf))
                        blockOffset += extentLeafSize
                    }
                    offset += extentIndexSize
                }
            default:
                throw Error.deepExtentsUnimplemented
            }
            var previousEnd: UInt64 = 0
            for extent in extents {
                guard extent.logicalBlock >= previousEnd else { throw Error.invalidExtents }
                previousEnd = extent.logicalBlock + extent.blockCount
            }
            return extents
        }

        // MARK: Internal functions
        func getInode(number: UInt32) throws -> Inode {
            if let inode = self.inodes[number] {
                return inode
            }

            let inode = try readInode(number)
            self.inodes[number] = inode
            return inode
        }

        func getGroupDescriptor(_ number: UInt32) throws -> GroupDescriptor {
            if let gd = self.groupDescriptors[number] {
                return gd
            }
            let gd = try readGroupDescriptor(number)
            self.groupDescriptors[number] = gd
            return gd
        }

        func children(of number: EXT4.InodeNumber) throws -> [(String, InodeNumber)] {
            try getDirTree(number)
        }
    }
}
