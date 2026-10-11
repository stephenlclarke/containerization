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
    public enum PathIOError: Swift.Error, CustomStringConvertible {
        case notFound(String)
        case notAFile(String)
        case isDirectory(String)
        case notADirectory(String)
        case symlinkLoop(String)
        case invalidPath(String)

        public var description: String {
            switch self {
            case .notFound(let p): return "no such file or directory: \(p)"
            case .notAFile(let p): return "not a regular file: \(p)"
            case .isDirectory(let p): return "is a directory: \(p)"
            case .notADirectory(let p): return "not a directory: \(p)"
            case .symlinkLoop(let p): return "symlink loop while resolving: \(p)"
            case .invalidPath(let p): return "invalid path: \(p)"
            }
        }
    }
}

// MARK: - Public API

extension EXT4.EXT4Reader {
    /// Return true if a path exists (file or directory) in this ext4 device.
    public func exists(_ path: FilePath, followSymlinks: Bool = true) -> Bool {
        (try? resolvePath(path, followSymlinks: followSymlinks).inode) != nil
    }

    /// Get the total number of blocks in the filesystem
    private var totalBlocks: UInt64 {
        let lo = UInt64(_superBlock.blocksCountLow)
        let hi = UInt64(_superBlock.blocksCountHigh)
        return lo | (hi << 32)
    }

    /// Metadata (inode + inode number) for a path.
    public func stat(_ path: FilePath, followSymlinks: Bool = true) throws -> (inodeNumber: EXT4.InodeNumber, inode: EXT4.Inode) {
        let resolved = try resolvePath(path, followSymlinks: followSymlinks)
        return (resolved.inodeNum, try getInode(number: resolved.inodeNum))
    }

    /// List a directory's entries (names only). Does not include "." or "..".
    public func listDirectory(_ path: FilePath) throws -> [String] {
        let (inoNum, ino) = try stat(path)
        guard ino.mode.isDir() else {
            throw EXT4.PathIOError.notADirectory(path.description)
        }
        let children = try children(of: inoNum)
        return
            children
            .map { $0.0 }
            .filter { $0 != "." && $0 != ".." }
            .sorted()
    }

    /// Read bytes from a regular file at `path` into `buffer`, starting at `offset`.
    /// Returns the number of bytes written to `buffer` (may be less than `buffer.count` at EOF).
    /// - Note: Semantics mirror `read(2)`: partial reads are possible.
    @discardableResult
    public func readFile(
        at path: FilePath,
        into buffer: UnsafeMutableRawBufferPointer,
        offset: UInt64 = 0,
        followSymlinks: Bool = true
    ) throws -> Int {
        let context = try prepareRead(path: path, offset: offset, followSymlinks: followSymlinks)
        if buffer.count == 0 || context.maxReadable == 0 {
            return 0
        }

        let want = min(UInt64(buffer.count), context.maxReadable)
        return try performRead(
            inodeNumber: context.inodeNumber,
            start: context.start,
            wantedBytes: want,
            into: buffer
        )
    }

    /// Read bytes from a regular file at `path` starting at `offset`.
    /// If `count` is nil, reads to EOF. Returns exactly the requested bytes (or less at EOF).
    public func readFile(
        at path: FilePath,
        offset: UInt64 = 0,
        count: Int? = nil,
        followSymlinks: Bool = true
    ) throws -> Data {
        let context = try prepareRead(path: path, offset: offset, followSymlinks: followSymlinks)
        let want = count.map { min(UInt64($0), context.maxReadable) } ?? context.maxReadable
        if want == 0 {
            return Data()
        }

        var out = Data(count: Int(want))
        let wrote = try out.withUnsafeMutableBytes {
            try performRead(
                inodeNumber: context.inodeNumber,
                start: context.start,
                wantedBytes: want,
                into: $0
            )
        }
        if wrote < Int(want) {
            out.removeSubrange(wrote..<Int(want))
        }
        return out
    }

    private func prepareRead(
        path: FilePath,
        offset: UInt64,
        followSymlinks: Bool
    ) throws -> (inodeNumber: EXT4.InodeNumber, start: UInt64, maxReadable: UInt64) {
        let (inoNum, inode) = try stat(path, followSymlinks: followSymlinks)

        if inode.mode.isDir() {
            throw EXT4.PathIOError.isDirectory(path.description)
        }

        if !inode.mode.isReg() {
            throw EXT4.PathIOError.notAFile(path.description)
        }

        let fileSize: UInt64 = inodeFileSize(inode)
        let start = min(offset, fileSize)
        let maxReadable = fileSize - start
        return (inodeNumber: inoNum, start: start, maxReadable: maxReadable)
    }

    private func performRead(
        inodeNumber: EXT4.InodeNumber,
        start: UInt64,
        wantedBytes: UInt64,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        let desiredBytes = Int(min(wantedBytes, UInt64(buffer.count)))
        guard desiredBytes > 0, let base = buffer.baseAddress else { return 0 }
        let extents = try getLogicalExtents(inode: inodeNumber)
        for extent in extents {
            guard extent.physicalBlock < totalBlocks,
                extent.blockCount <= totalBlocks - extent.physicalBlock
            else { throw EXT4.Error.invalidExtents }
            // Validate even non-overlapping ranges before touching the caller's buffer.
            _ = try Self.checkedByteOffset(block: extent.physicalBlock, blockSize: blockSize)
            _ = try Self.checkedByteOffset(
                block: extent.physicalBlock + extent.blockCount - 1, blockSize: blockSize, offset: blockSize - 1)
        }

        let requestEnd = start + UInt64(desiredBytes)
        var bytesWritten = 0
        func zeros(_ count: Int) {
            base.advanced(by: bytesWritten).initializeMemory(as: UInt8.self, repeating: 0, count: count)
            bytesWritten += count
        }
        for extent in extents {
            let logicalStart = try Self.checkedByteOffset(block: extent.logicalBlock, blockSize: blockSize)
            let logicalEnd = try Self.checkedByteOffset(block: extent.logicalBlock + extent.blockCount, blockSize: blockSize)
            if logicalEnd <= start { continue }
            if logicalStart >= requestEnd { break }
            let overlapStart = max(start, logicalStart)
            let overlapEnd = min(requestEnd, logicalEnd)
            zeros(Int(overlapStart - start) - bytesWritten)
            var remaining = overlapEnd - overlapStart
            if extent.unwritten {
                zeros(Int(remaining))
                continue
            }
            let physicalOffset = try Self.checkedByteOffset(block: extent.physicalBlock, blockSize: blockSize, offset: overlapStart - logicalStart)
            do {
                try handle.seek(toOffset: physicalOffset)
                while remaining > 0 {
                    let chunk = Int(min(remaining, 1 << 20))
                    guard let data = try handle.read(upToCount: chunk), !data.isEmpty else {
                        if bytesWritten > 0 { return bytesWritten }
                        throw EXT4.Error.couldNotReadBlock(UInt32(truncatingIfNeeded: extent.physicalBlock))
                    }
                    data.withUnsafeBytes { bytes in
                        UnsafeMutableRawBufferPointer(start: base.advanced(by: bytesWritten), count: data.count).copyMemory(from: bytes)
                    }
                    bytesWritten += data.count
                    remaining -= UInt64(data.count)
                    if data.count < chunk { return bytesWritten }
                }
            } catch {
                if bytesWritten > 0 { return bytesWritten }
                throw error
            }
        }
        zeros(desiredBytes - bytesWritten)
        return bytesWritten
    }

    // MARK: - Internals inside EXT4Reader
    public struct ResolvedPath {
        let inodeNum: EXT4.InodeNumber
        let inode: EXT4.Inode
    }

    /// Resolve a path to an inode, following symlinks in parent components and
    /// optionally following a symlink in the final component.
    /// Paths may be absolute ("/...") or relative (from "/").
    public func resolvePath(_ path: FilePath, followSymlinks: Bool, maxSymlinks: Int = 40) throws -> ResolvedPath {
        var components: [String] = normalize(path: path)
        var current: EXT4.InodeNumber = EXT4.RootInode
        var parentStack: [EXT4.InodeNumber] = []  // Track parent chain for proper ".." handling

        var symlinkHops = 0

        // Process components one at a time to handle symlinks in the middle of paths
        var componentIndex = 0

        while componentIndex < components.count {
            let name = components[componentIndex]

            if name == "." {
                componentIndex += 1
                continue
            }

            if name == ".." {
                // Handle parent directory traversal
                if current == EXT4.RootInode {
                    // At root, ".." points to itself
                    componentIndex += 1
                    continue
                }

                // Use parent stack if available
                if !parentStack.isEmpty {
                    current = parentStack.removeLast()
                } else {
                    // Fallback: look up ".." entry in filesystem
                    let entries = try children(of: current)
                    if let parent = entries.first(where: { $0.0 == ".." })?.1 {
                        current = parent
                    }
                }
                componentIndex += 1
                continue
            }

            // Regular component: verify current is a directory and look up child
            let currentInode = try getInode(number: current)
            guard currentInode.mode.isDir() else {
                throw EXT4.PathIOError.notADirectory(name)
            }

            let entries = try children(of: current)
            guard let child = entries.first(where: { $0.0 == name }) else {
                throw EXT4.PathIOError.notFound(name)
            }

            // Check if child is a symlink
            let childInode = try getInode(number: child.1)
            let isFinalComponent = componentIndex == components.count - 1
            if childInode.mode.isLink() && (followSymlinks || !isFinalComponent) {
                // Enforce max symlink depth
                symlinkHops += 1
                if symlinkHops > maxSymlinks {
                    throw EXT4.PathIOError.symlinkLoop(FilePath(components.joined(separator: "/")).description)
                }

                // Read symlink target
                let linkBytes = try readFileFromInode(inodeNum: child.1)
                guard let linkTarget = String(data: linkBytes, encoding: .utf8), !linkTarget.isEmpty else {
                    throw EXT4.PathIOError.invalidPath("empty symlink target")
                }

                // Parse symlink target into components
                let targetComponents = normalize(path: FilePath(linkTarget))

                // Replace current component with symlink target components and continue
                if linkTarget.hasPrefix("/") {
                    // Absolute symlink: reset to root
                    current = EXT4.RootInode
                    parentStack = []
                    // Replace the symlink component with target components + remaining path
                    components = targetComponents + Array(components[(componentIndex + 1)...])
                    componentIndex = 0  // Start from beginning with new path
                } else {
                    // Relative symlink: continue from current directory
                    // Replace the symlink component with target components + remaining path
                    components = Array(components[0..<componentIndex]) + targetComponents + Array(components[(componentIndex + 1)...])
                    // Don't change componentIndex - continue from same position with expanded path
                }
            } else {
                // Not a symlink or not following symlinks - descend into directory
                parentStack.append(current)
                current = child.1
                componentIndex += 1
            }
        }

        // All components processed - return final inode
        let finalInode = try getInode(number: current)
        return ResolvedPath(inodeNum: current, inode: finalInode)
    }

    /// Normalize a path into components, handling absolute and relative paths.
    private func normalize(path: FilePath) -> [String] {
        let s = path.description
        let trimmed = s.hasPrefix("/") ? String(s.dropFirst()) : s
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: "/").map(String.init)
    }

    /// Read entire file content of a regular file given an inode (used for symlink targets).
    private func readFileFromInode(inodeNum: EXT4.InodeNumber) throws -> Data {
        let ino = try getInode(number: inodeNum)
        guard ino.mode.isReg() || ino.mode.isLink() else {
            return Data()
        }
        let size = inodeFileSize(ino)
        if size == 0 { return Data() }

        // Handle fast symlinks (target stored directly in inode block field)
        if ino.mode.isLink() && size < 60 {
            // Extract target from inode block field
            let blockData = withUnsafeBytes(of: ino.block) { Data($0) }
            return blockData.prefix(Int(size))
        }

        return try readFileBytesFromExtents(inodeNum: inodeNum, offset: 0, count: size)
    }

    /// Common logical-range reader for file data, long symlinks and archive export.
    func readFileBytesFromExtents(inodeNum: EXT4.InodeNumber, offset: UInt64, count: UInt64) throws -> Data {
        let size = inodeFileSize(try getInode(number: inodeNum))
        let start = min(offset, size)
        let wanted = min(count, size - start)
        guard let length = Int(exactly: wanted) else { throw EXT4.Error.invalidExtents }
        var data = Data(count: length)
        let read = try data.withUnsafeMutableBytes {
            try performRead(inodeNumber: inodeNum, start: start, wantedBytes: wanted, into: $0)
        }
        if read < length { data.removeSubrange(read..<length) }
        return data
    }

    /// Compute 64-bit file size from the inode fields (i_size).
    /// ext4 stores low 32 bits in i_size_lo and the high 32 bits in i_size_high when 64-bit sizes are enabled.
    private func inodeFileSize(_ inode: EXT4.Inode) -> UInt64 {
        // The Containerization EXT4 Inode struct exposes mode and block fields; size fields
        // are commonly named sizeLo/sizeHigh in this codebase.
        // EXT4 supports 64-bit file sizes - always use both low and high parts.
        let lo = UInt64(inode.sizeLow)
        let hi = UInt64(inode.sizeHigh)
        return lo | (hi << 32)
    }
}
