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

import CArchive
import Foundation
import SystemPackage

#if os(macOS)
private let archiveSeekData: CInt = 4
private let archiveSeekHole: CInt = 3
#else
private let archiveSeekData: CInt = 3
private let archiveSeekHole: CInt = 4
#endif

/// A class responsible for writing archives in various formats.
public final class ArchiveWriter {
    private static let chunkSize = 4 * 1024 * 1024

    var underlying: OpaquePointer?
    private var hardlinks: [FileIdentity: String] = [:]

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// Initialize a new `ArchiveWriter` with the given configuration.
    /// This method attempts to initialize an empty archive in memory, failing which it throws a `unableToCreateArchive` error.
    public init(configuration: ArchiveWriterConfiguration) throws {
        // because for some bizarre reason, UTF8 paths won't work unless this process explicitly sets a locale like en_US.UTF-8
        try Self.attemptSetLocales(locales: configuration.locales)

        guard let underlying = archive_write_new() else { throw ArchiveError.unableToCreateArchive }
        self.underlying = underlying

        try setFormat(configuration.format)
        try addFilter(configuration.filter)
        try setOptions(configuration.options)
    }

    /// Initialize a new `ArchiveWriter` for writing into the specified file with the given configuration options.
    public convenience init(format: Format, filter: Filter, options: [Options] = [], locales: [String] = ArchiveWriterConfiguration.defaultLocales, file: URL) throws {
        let config = ArchiveWriterConfiguration(
            format: format,
            filter: filter,
            options: options,
            locales: locales
        )
        try self.init(configuration: config)
        try self.open(file: file)
    }

    /// Opens the given file for writing data into
    public func open(file: URL) throws {
        guard let underlying = underlying else { throw ArchiveError.noUnderlyingArchive }
        let res = archive_write_open_filename(underlying, file.path)
        try wrap(res, ArchiveError.unableToOpenArchive, underlying: underlying)
    }

    /// Opens the given fd for writing data into
    public func open(fileDescriptor: Int32) throws {
        guard let underlying = underlying else { throw ArchiveError.noUnderlyingArchive }
        let res = archive_write_open_fd(underlying, fileDescriptor)
        try wrap(res, ArchiveError.unableToOpenArchive, underlying: underlying)
    }

    /// Performs any necessary finalizations on the archive and releases resources.
    public func finishEncoding() throws {
        guard let u = underlying else { return }
        underlying = nil
        let r = archive_free(u)
        guard r == ARCHIVE_OK else {
            throw ArchiveError.unableToCloseArchive(r)
        }
    }

    deinit {
        if let u = underlying {
            archive_free(u)
            underlying = nil
        }
    }

    private static func attemptSetLocales(locales: [String]) throws {
        for locale in locales {
            if setlocale(LC_ALL, locale) != nil {
                return
            }
        }
        throw ArchiveError.failedToSetLocale(locales: locales)
    }
}

public class ArchiveWriterTransaction {
    private let writer: ArchiveWriter

    fileprivate init(writer: ArchiveWriter) {
        self.writer = writer
    }

    public func writeHeader(entry: WriteEntry) throws {
        try writer.writeHeader(entry: entry)
    }

    public func writeChunk(data: UnsafeRawBufferPointer) throws {
        try writer.writeData(data: data)
    }

    public func finish() throws {
        try writer.finishEntry()
    }
}

extension ArchiveWriter {
    public func makeTransactionWriter() -> ArchiveWriterTransaction {
        ArchiveWriterTransaction(writer: self)
    }

    /// Create a new entry in the archive with the given properties.
    /// - Parameters:
    ///   - entry: A `WriteEntry` object describing the metadata of the entry to be created
    ///            (e.g., name, modification date, permissions).
    ///   - data: The `Data` object containing the content for the new entry.
    public func writeEntry(entry: WriteEntry, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            try writeEntry(entry: entry, data: bytes)
        }
    }

    /// Creates a new entry in the archive with the given properties.
    ///
    /// This method performs the following:
    /// 1. Writes the archive header using the provided `WriteEntry` metadata.
    /// 2. Writes the content from the `UnsafeRawBufferPointer` into the archive.
    /// 3. Finalizes the entry in the archive.
    ///
    /// - Parameters:
    ///   - entry: A `WriteEntry` object describing the metadata of the entry to be created
    ///            (e.g., name, modification date, permissions, type).
    ///   - data: An optional `UnsafeRawBufferPointer` containing the raw bytes for the new entry's
    ///           content. Pass `nil` for entries that do not have content data (e.g., directories, symlinks).
    public func writeEntry(entry: WriteEntry, data: UnsafeRawBufferPointer?) throws {
        try writeHeader(entry: entry)
        if let data = data {
            try writeData(data: data)
        }
        try finishEntry()
    }

    fileprivate func writeHeader(entry: WriteEntry) throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }

        try wrap(
            archive_write_header(underlying, entry.underlying), ArchiveError.unableToWriteEntryHeader,
            underlying: underlying)
    }

    fileprivate func finishEntry() throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }

        archive_write_finish_entry(underlying)
    }

    fileprivate func writeData(data: UnsafeRawBufferPointer) throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }

        var offset = 0
        while offset < data.count {
            guard let baseAddress = data.baseAddress?.advanced(by: offset) else {
                throw ArchiveError.invalidBaseAddressArchiveWrite
            }
            let result = archive_write_data(underlying, baseAddress, data.count - offset)
            guard result > 0 else {
                throw ArchiveError.unableToWriteData(result)
            }
            offset += Int(result)
        }
    }
}

extension ArchiveWriter {
    private func archive(
        _ relativePath: FilePath,
        dirPath: FilePath,
        includeExternalSymlinks: Bool
    ) throws {
        let fm = FileManager.default

        let fullPath = dirPath.appending(relativePath.string)

        var statInfo = stat()
        guard lstat(fullPath.string, &statInfo) == 0 else {
            let errNo = errno
            let err = POSIXErrorCode(rawValue: errNo) ?? .EINVAL
            throw ArchiveError.failedToCreateArchive("lstat failed for '\(fullPath)': \(POSIXError(err))")
        }

        let mode = statInfo.st_mode
        let uid = statInfo.st_uid
        let gid = statInfo.st_gid
        var size: Int64 = 0
        let type: URLFileResourceType

        if (mode & S_IFMT) == S_IFREG {
            type = .regular
            size = Int64(statInfo.st_size)
        } else if (mode & S_IFMT) == S_IFDIR {
            type = .directory
        } else if (mode & S_IFMT) == S_IFLNK {
            type = .symbolicLink
        } else {
            return
        }

        #if os(macOS)
        let created = Self.date(statInfo.st_ctimespec)
        let access = Self.date(statInfo.st_atimespec)
        let modified = Self.date(statInfo.st_mtimespec)
        #else
        let created = Self.date(statInfo.st_ctim)
        let access = Self.date(statInfo.st_atim)
        let modified = Self.date(statInfo.st_mtim)
        #endif

        let entry = WriteEntry()
        if type == .symbolicLink {
            let targetPath = try fm.destinationOfSymbolicLink(atPath: fullPath.string)
            // Resolve the target relative to the symlink's parent, not the archive root.
            let symlinkParent = fullPath.removingLastComponent()
            let resolvedFull = symlinkParent.appending(targetPath).lexicallyNormalized()
            guard includeExternalSymlinks || resolvedFull.starts(with: dirPath) else {
                return
            }
            entry.symlinkTarget = targetPath
        }

        entry.path = relativePath.string
        entry.size = size
        entry.creationDate = created
        entry.modificationDate = modified
        entry.contentAccessDate = access
        entry.fileType = type
        entry.group = gid
        entry.owner = uid
        entry.permissions = mode
        if type == .regular {
            let identity = FileIdentity(
                device: UInt64(statInfo.st_dev),
                inode: UInt64(statInfo.st_ino)
            )
            if statInfo.st_nlink > 1, let target = hardlinks[identity] {
                entry.hardlink = target
                entry.size = 0
                try self.writeEntry(entry: entry, data: nil)
                return
            }
            if statInfo.st_nlink > 1 {
                hardlinks[identity] = relativePath.string
            }

            let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
            guard let baseAddress = buf.baseAddress else {
                throw ArchiveError.failedToCreateArchive("cannot create temporary buffer of size \(Self.chunkSize)")
            }
            defer { buf.deallocate() }
            let fd = Foundation.open(fullPath.string, O_RDONLY)
            guard fd >= 0 else {
                let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                throw ArchiveError.failedToCreateArchive("cannot open file \(fullPath.string) for reading: \(err)")
            }
            defer { close(fd) }
            for extent in try Self.sparseDataExtents(fd: fd, size: size) ?? [] {
                entry.addSparseData(offset: extent.offset, length: extent.length)
            }
            _ = lseek(fd, 0, SEEK_SET)
            try self.writeHeader(entry: entry)
            while true {
                let n = read(fd, baseAddress, Self.chunkSize)
                if n == 0 { break }
                if n < 0, errno == EINTR {
                    continue
                }
                if n < 0 {
                    let err = POSIXErrorCode(rawValue: errno) ?? .EIO
                    throw ArchiveError.failedToCreateArchive("failed to read from file \(fullPath.string): \(err)")
                }
                try self.writeData(data: UnsafeRawBufferPointer(start: baseAddress, count: n))
            }
            try self.finishEntry()
        } else {
            try self.writeEntry(entry: entry, data: nil)
        }
    }

    /// Recursively archives the content of a directory. Regular files, symlinks and directories are added into the archive.
    /// Note: Symlinks are added to the archive if both the source and target for the symlink are both contained in the top level directory.
    public func archiveDirectory(
        _ dir: URL,
        includeExternalSymlinks: Bool = false
    ) throws {
        let fm = FileManager.default
        let dirPath = FilePath(dir.path)

        guard let enumerator = fm.enumerator(atPath: dirPath.string) else {
            throw POSIXError(.ENOTDIR)
        }

        // Emit a leading "./" entry for the root directory, matching GNU/BSD tar behavior.
        var rootStat = stat()
        guard lstat(dirPath.string, &rootStat) == 0 else {
            let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
            throw ArchiveError.failedToCreateArchive("lstat failed for '\(dirPath)': \(POSIXError(err))")
        }
        let rootEntry = WriteEntry()
        rootEntry.path = "./"
        rootEntry.size = 0
        rootEntry.fileType = .directory
        rootEntry.owner = rootStat.st_uid
        rootEntry.group = rootStat.st_gid
        rootEntry.permissions = rootStat.st_mode
        #if os(macOS)
        rootEntry.creationDate = Self.date(rootStat.st_ctimespec)
        rootEntry.contentAccessDate = Self.date(rootStat.st_atimespec)
        rootEntry.modificationDate = Self.date(rootStat.st_mtimespec)
        #else
        rootEntry.creationDate = Self.date(rootStat.st_ctim)
        rootEntry.contentAccessDate = Self.date(rootStat.st_atim)
        rootEntry.modificationDate = Self.date(rootStat.st_mtim)
        #endif
        try self.writeEntry(entry: rootEntry, data: nil)

        for case let relativePath as String in enumerator {
            try archive(
                FilePath(relativePath),
                dirPath: dirPath,
                includeExternalSymlinks: includeExternalSymlinks
            )
        }
    }

    public func archive(
        _ paths: [FilePath],
        base: FilePath,
        includeExternalSymlinks: Bool = false
    ) throws {
        let fm = FileManager.default
        let base = base.lexicallyNormalized()

        for path in paths {
            guard path.starts(with: base) else {
                throw ArchiveError.failedToCreateArchive("'\(path.string)' is not under '\(base.string)'")
            }

            let relativePath = path.components.dropFirst(base.components.count)
                .reduce(into: FilePath("")) { $0.append($1) }

            var pathStat = stat()
            guard lstat(path.string, &pathStat) == 0 else {
                let err = POSIXErrorCode(rawValue: errno) ?? .EINVAL
                throw ArchiveError.failedToCreateArchive(
                    "lstat failed for '\(path)': \(POSIXError(err))"
                )
            }
            if (pathStat.st_mode & S_IFMT) == S_IFDIR {
                guard let enumerator = fm.enumerator(atPath: path.string) else {
                    throw POSIXError(.ENOTDIR)
                }

                try archive(
                    relativePath,
                    dirPath: base,
                    includeExternalSymlinks: includeExternalSymlinks
                )
                for case let child as String in enumerator {
                    let childPath = relativePath.appending(child)

                    try archive(
                        childPath,
                        dirPath: base,
                        includeExternalSymlinks: includeExternalSymlinks
                    )
                }
            } else {
                try archive(
                    relativePath,
                    dirPath: base,
                    includeExternalSymlinks: includeExternalSymlinks
                )
            }
        }
    }

    private static func date(_ value: timespec) -> Date {
        Date(
            timeIntervalSince1970:
                TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
        )
    }

    private static func sparseDataExtents(
        fd: Int32,
        size: Int64
    ) throws -> [(offset: Int64, length: Int64)]? {
        guard size > 0 else {
            return nil
        }

        var extents: [(offset: Int64, length: Int64)] = []
        var position: Int64 = 0
        while position < size {
            errno = 0
            let dataOffset = lseek(fd, off_t(position), archiveSeekData)
            if dataOffset < 0 {
                if errno == ENXIO {
                    if extents.isEmpty {
                        return [(offset: size, length: 0)]
                    }
                    break
                }
                if errno == EINVAL || errno == ENOTSUP {
                    return nil
                }
                throw ArchiveError.failedToCreateArchive(
                    "failed to locate sparse-file data: \(POSIXErrorCode(rawValue: errno) ?? .EIO)"
                )
            }

            let holeOffset = lseek(fd, dataOffset, archiveSeekHole)
            guard holeOffset >= 0 else {
                if errno == EINVAL || errno == ENOTSUP {
                    return nil
                }
                throw ArchiveError.failedToCreateArchive(
                    "failed to locate sparse-file hole: \(POSIXErrorCode(rawValue: errno) ?? .EIO)"
                )
            }

            let end = Swift.min(Int64(holeOffset), size)
            extents.append((offset: Int64(dataOffset), length: end - Int64(dataOffset)))
            position = end
        }

        guard
            !extents.isEmpty,
            extents.count != 1 || extents[0].offset != 0 || extents[0].length != size
        else {
            return nil
        }
        return extents
    }
}
