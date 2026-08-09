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

import CArchive
import ContainerizationError
import ContainerizationOS
import Foundation
import SystemPackage

/// A protocol for reading data in chunks, compatible with both `InputStream` and zero-allocation archive readers.
public protocol ReadableStream {
    /// Reads up to `maxLength` bytes into the provided buffer.
    /// Returns the number of bytes actually read, 0 for EOF, or -1 for error.
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int
}

extension InputStream: ReadableStream {}

/// Small wrapper type to read data from an archive entry.
public struct ArchiveEntryReader: ReadableStream {
    private weak var reader: ArchiveReader?

    init(reader: ArchiveReader) {
        self.reader = reader
    }

    /// Reads up to `maxLength` bytes into the provided buffer.
    /// Returns the number of bytes actually read, 0 for EOF, or -1 for error.
    public func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        guard let archive = reader?.underlying else { return -1 }
        let bytesRead = archive_read_data(archive, buffer, maxLength)
        return bytesRead < 0 ? -1 : bytesRead
    }
}

/// A class responsible for reading entries from an archive file.
public final class ArchiveReader {
    private static let chunkSize = 4 * 1024 * 1024

    /// A pointer to the underlying `archive` C structure.
    var underlying: OpaquePointer?
    /// The file handle associated with the archive file being read.
    let fileHandle: FileHandle?
    /// Temporary decompressed file URL if the input was zstd-compressed
    private var tempDecompressedFile: URL?

    /// Initializes an `ArchiveReader` to read from a specified file URL with an explicit `Format` and `Filter`.
    /// Note: This method must be used when it is known that the archive at the specified URL follows the specified
    /// `Format` and `Filter`.
    public convenience init(format: Format, filter: Filter, file: URL) throws {
        // If filter is zstd, decompress it and use filter .none
        let fileToRead: URL
        let tempFile: URL?
        let actualFilter: Filter

        if filter == .zstd {
            let decompressed = try Self.decompressZstd(file)
            tempFile = decompressed
            fileToRead = decompressed
            actualFilter = .none
        } else {
            tempFile = nil
            fileToRead = file
            actualFilter = filter
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: fileToRead)
            try self.init(format: format, filter: actualFilter, fileHandle: fileHandle)
        } catch {
            if let tempFile {
                try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent())
            }
            throw error
        }
        self.tempDecompressedFile = tempFile
    }

    /// Initializes an `ArchiveReader` to read from the provided file descriptor with an explicit `Format` and `Filter`.
    /// Note: This method must be used when it is known that the archive pointed to by the file descriptor follows the specified
    /// `Format` and `Filter`.
    public init(format: Format, filter: Filter, fileHandle: FileHandle) throws {
        self.underlying = archive_read_new()
        self.fileHandle = fileHandle

        try archive_read_set_format(underlying, format.code)
            .checkOk(elseThrow: .unableToSetFormat(format.code, format))
        try archive_read_append_filter(underlying, filter.code)
            .checkOk(elseThrow: .unableToAddFilter(filter.code, filter))

        let fd = fileHandle.fileDescriptor
        try archive_read_open_fd(underlying, fd, 4096)
            .checkOk(elseThrow: { .unableToOpenArchive($0) })
    }

    /// Initializes an archive reader for a stream whose format and compression
    /// are not known in advance.
    public init(fileHandle: FileHandle) throws {
        self.underlying = archive_read_new()
        self.fileHandle = fileHandle

        try archive_read_support_filter_all(underlying)
            .checkOk(elseThrow: .failedToDetectFilter)
        try archive_read_support_format_all(underlying)
            .checkOk(elseThrow: .failedToDetectFormat)

        try archive_read_open_fd(underlying, fileHandle.fileDescriptor, 4096)
            .checkOk(elseThrow: { .unableToOpenArchive($0) })
    }

    /// Initialize the `ArchiveReader` to read from a specified file URL
    /// by trying to auto determine the archives `Format` and `Filter`.
    public init(file: URL) throws {
        self.underlying = archive_read_new()

        // Try to decompress as zstd first, fall back to original if it fails
        let fileToRead: URL
        if let decompressed = try? Self.decompressZstd(file) {
            self.tempDecompressedFile = decompressed
            fileToRead = decompressed
        } else {
            fileToRead = file
        }

        let fileHandle = try FileHandle(forReadingFrom: fileToRead)
        self.fileHandle = fileHandle
        try archive_read_support_filter_all(underlying)
            .checkOk(elseThrow: .failedToDetectFilter)
        try archive_read_support_format_all(underlying)
            .checkOk(elseThrow: .failedToDetectFormat)
        let fd = fileHandle.fileDescriptor
        try archive_read_open_fd(underlying, fd, 4096)
            .checkOk(elseThrow: { .unableToOpenArchive($0) })
    }

    /// Decompress a zstd file to a temporary location
    public static func decompressZstd(_ source: URL) throws -> URL {
        guard let tempDir = createTemporaryDirectory(baseName: "zstd-decompress") else {
            throw ArchiveError.failedToDetectFormat
        }
        let tempFile = tempDir.appendingPathComponent(
            source.deletingPathExtension().lastPathComponent
        )

        do {
            let srcPath = source.path
            let srcFd = open(srcPath, O_RDONLY)
            guard srcFd >= 0 else { throw ArchiveError.failedToDetectFormat }
            defer { close(srcFd) }

            let dstFd = open(tempFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard dstFd >= 0 else { throw ArchiveError.failedToDetectFormat }
            defer { close(dstFd) }

            guard zstd_decompress_fd(srcFd, dstFd) == 0 else {
                throw ArchiveError.failedToDetectFormat
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
        return tempFile
    }

    /// Clean up the temporary directory created by `decompressZstd`.
    /// The decompressed file is placed inside a unique temporary directory,
    /// so removing that directory cleans up everything.
    public static func cleanUpDecompressedZstd(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    deinit {
        archive_read_free(underlying)
        try? fileHandle?.close()

        if let tempFile = tempDecompressedFile {
            Self.cleanUpDecompressedZstd(tempFile)
        }
    }
}

extension CInt {
    fileprivate func checkOk(elseThrow error: @autoclosure () -> ArchiveError) throws {
        guard self == ARCHIVE_OK else { throw error() }
    }
    fileprivate func checkOk(elseThrow error: (CInt) -> ArchiveError) throws {
        guard self == ARCHIVE_OK else { throw error(self) }
    }

}

extension ArchiveReader: Sequence {
    public func makeIterator() -> Iterator {
        Iterator(reader: self)
    }

    public struct Iterator: IteratorProtocol {
        var reader: ArchiveReader

        public mutating func next() -> (WriteEntry, Data)? {
            let entry = WriteEntry()
            let result = archive_read_next_header2(reader.underlying, entry.underlying)
            if result == ARCHIVE_EOF {
                return nil
            }
            let data = reader.readDataForEntry(entry)
            return (entry, data)
        }
    }

    /// Returns an iterator that yields archive entries.
    public func makeStreamingIterator() -> StreamingIterator {
        StreamingIterator(reader: self)
    }

    public struct StreamingIterator: Sequence, IteratorProtocol {
        var reader: ArchiveReader

        public func makeIterator() -> StreamingIterator {
            self
        }

        public mutating func next() -> (WriteEntry, ArchiveEntryReader)? {
            let entry = WriteEntry()
            let result = archive_read_next_header2(reader.underlying, entry.underlying)
            if result == ARCHIVE_EOF {
                return nil
            }
            let streamReader = ArchiveEntryReader(reader: reader)
            return (entry, streamReader)
        }
    }

    internal func readDataForEntry(_ entry: WriteEntry) -> Data {
        let bufferSize = Int(Swift.min(entry.size ?? 4096, 4096))
        var entry = Data()
        var part = Data(count: bufferSize)
        while true {
            let c = part.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return archive_read_data(self.underlying, baseAddress, buffer.count)
            }
            guard c > 0 else { break }
            part.count = c
            entry.append(part)
        }
        return entry
    }
}

extension ArchiveReader {
    public convenience init(name: String, bundle: Data, tempDirectoryBaseName: String? = nil) throws {
        let baseName = tempDirectoryBaseName ?? "Unarchiver"
        guard let tempDir = createTemporaryDirectory(baseName: baseName) else {
            throw ArchiveError.failedToExtractArchive("failed to create temporary directory")
        }
        let url = tempDir.appendingPathComponent(name)
        do {
            try bundle.write(to: url, options: .atomic)
            try self.init(format: .zip, filter: .none, file: url)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
        // Register for cleanup in deinit (only needed when the zstd path didn't already set it)
        if self.tempDecompressedFile == nil {
            self.tempDecompressedFile = url
        }
    }

    /// Extracts the contents of an archive to the provided directory.
    /// Rejects member paths that escape the root directory or traverse
    /// symbolic links, and uses a "last entry wins" replacement policy
    /// for an existing file at a path to be extracted.
    public func extractContents(to directory: URL, preserveOwnership: Bool = true) throws -> [String] {
        try extractContents(
            to: directory,
            preserveOwnership: preserveOwnership,
            including: { _ in true }
        )
    }

    /// Extracts archive members whose paths satisfy `shouldExtract` to the
    /// provided directory. Rejected paths are reported only for selected
    /// members. Throws when the archive contains no matching members.
    public func extractContents(
        to directory: URL,
        preserveOwnership: Bool = true,
        including shouldExtract: (String) -> Bool
    ) throws -> [String] {
        // Create the root directory with standard permissions
        // and create a FileDescriptor for secure path traversal.
        let fm = FileManager.default
        let rootFilePath = FilePath(directory.path)
        try fm.createDirectory(atPath: directory.path, withIntermediateDirectories: true)
        let rootFileDescriptor = try FileDescriptor.open(rootFilePath, .readOnly)
        defer { try? rootFileDescriptor.close() }

        // Iterate and extract archive entries, collecting rejected paths.
        var foundEntry = false
        var rejectedPaths = [String]()
        var deferredDirAttrs: [(path: FilePath, entry: WriteEntry)] = []
        var deferredHardlinks: [(path: FilePath, target: FilePath, sequence: Int)] = []
        var lastMemberSequence: [String: Int] = [:]
        var sequence = 0
        for (entry, _) in self.makeStreamingIterator() {
            guard let path = entry.path, shouldExtract(path) else {
                try archive_read_data_skip(self.underlying).checkOk(
                    elseThrow: ArchiveError.failedToExtractArchive("failed to skip archive member data")
                )
                continue
            }
            let memberPath = FilePath(path)
            foundEntry = true
            sequence += 1
            lastMemberSequence[memberPath.string] = sequence

            if let hardlink = entry.hardlink {
                deferredHardlinks.append((memberPath, FilePath(hardlink), sequence))
                try archive_read_data_skip(self.underlying).checkOk(
                    elseThrow: ArchiveError.failedToExtractArchive("failed to skip hard-link member data")
                )
                continue
            }

            // Try to extract the entry, catching path validation errors
            let extracted = try extractEntry(
                entry: entry,
                memberPath: memberPath,
                rootFileDescriptor: rootFileDescriptor,
                preserveOwnership: preserveOwnership
            )

            if extracted, entry.fileType == .directory {
                deferredDirAttrs.append((memberPath, entry))
            }

            if !extracted {
                rejectedPaths.append(memberPath.string)
            }
        }
        guard foundEntry else {
            throw ArchiveError.failedToExtractArchive("no entries found in archive")
        }

        var pendingHardlinks = deferredHardlinks.filter {
            lastMemberSequence[$0.path.string] == $0.sequence
        }
        while !pendingHardlinks.isEmpty {
            var remaining: [(path: FilePath, target: FilePath, sequence: Int)] = []
            for hardlink in pendingHardlinks {
                if !(try extractHardlink(
                    memberPath: hardlink.path,
                    targetPath: hardlink.target,
                    rootFileDescriptor: rootFileDescriptor
                )) {
                    remaining.append(hardlink)
                }
            }
            guard remaining.count < pendingHardlinks.count else {
                rejectedPaths.append(contentsOf: remaining.map(\.path.string))
                break
            }
            pendingHardlinks = remaining
        }

        // Apply directory permissions after all children are extracted, deepest first,
        // so a restrictive parent cannot block access to its children.
        for deferred in deferredDirAttrs.sorted(by: { $0.path.components.count > $1.path.components.count }) {
            do {
                try FileDescriptorOps.withOpenDirectory(rootFileDescriptor, deferred.path) { fd in
                    setFileAttributes(
                        fd: fd.rawValue,
                        entry: deferred.entry,
                        preserveOwnership: preserveOwnership
                    )
                }
            } catch let error as FileDescriptorOps.Error {
                switch error {
                case .invalidPathComponent, .cannotFollowSymlink:
                    // A later archive entry replaced this directory. Last entry wins.
                    continue
                case .invalidRelativePath, .systemError:
                    throw error
                }
            }
        }

        return rejectedPaths
    }

    /// This method extracts a given file from the archive.
    /// This operation modifies the underlying file descriptor's position within the archive,
    /// meaning subsequent reads will start from a new location.
    /// To reset the underlying file descriptor to the beginning of the archive, close and
    /// reopen the archive.
    public func extractFile(path: String) throws -> (WriteEntry, Data) {
        let entry = WriteEntry()
        while archive_read_next_header2(self.underlying, entry.underlying) != ARCHIVE_EOF {
            guard let entryPath = entry.path else { continue }
            let trimCharSet = CharacterSet(charactersIn: "./")
            let trimmedEntry = entryPath.trimmingCharacters(in: trimCharSet)
            let trimmedRequired = path.trimmingCharacters(in: trimCharSet)
            guard trimmedEntry == trimmedRequired else { continue }
            let data = readDataForEntry(entry)
            return (entry, data)
        }
        throw ArchiveError.failedToExtractArchive(" \(path) not found in archive")
    }

    /// Extracts a single archive entry.
    /// Returns false if the entry was rejected due to path validation errors.
    /// Throws on system errors.
    private func extractEntry(
        entry: WriteEntry,
        memberPath: FilePath,
        rootFileDescriptor: FileDescriptor,
        preserveOwnership: Bool
    ) throws -> Bool {
        guard let lastComponent = memberPath.lastComponent else {
            return false
        }
        let relativePath = memberPath.removingLastComponent()
        let type = entry.fileType

        do {
            switch type {
            case .regular:
                try FileDescriptorOps.mkdir(rootFileDescriptor, relativePath, makeIntermediates: true) { fd in
                    // Remove existing entry if present (mimics containerd's "last entry wins" behavior)
                    try? FileDescriptorOps.unlinkRecursive(fd, filename: lastComponent)

                    // Open file for writing using openat with O_NOFOLLOW to prevent TOC-TOU attacks
                    let fileMode = entry.permissions & 0o777  // Mask to permission bits only
                    let fileFd = openat(fd.rawValue, lastComponent.string, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, fileMode)
                    guard fileFd >= 0 else {
                        throw ArchiveError.failedToExtractArchive("failed to create file: \(memberPath)")
                    }
                    defer { close(fileFd) }

                    try copyEntryDataToFd(entry: entry, fileFd: fileFd, memberPath: memberPath)
                    setFileAttributes(
                        fd: fileFd,
                        entry: entry,
                        preserveOwnership: preserveOwnership
                    )
                }
            case .directory:
                try FileDescriptorOps.mkdir(rootFileDescriptor, memberPath, makeIntermediates: true) { _ in }
            case .symbolicLink:
                guard let targetPath = (entry.symlinkTarget.map { FilePath($0) }) else {
                    return false
                }
                var symlinkCreated = false
                try FileDescriptorOps.mkdir(rootFileDescriptor, relativePath, makeIntermediates: true) { fd in
                    // Remove existing entry if present (mimics containerd's "last entry wins" behavior)
                    try? FileDescriptorOps.unlinkRecursive(fd, filename: lastComponent)

                    guard symlinkat(targetPath.string, fd.rawValue, lastComponent.string) == 0 else {
                        throw ArchiveError.failedToExtractArchive("failed to create symlink: \(targetPath) <- \(memberPath)")
                    }
                    symlinkCreated = true
                }
                return symlinkCreated
            default:
                return false
            }

            return true
        } catch let error as FileDescriptorOps.Error {
            // Just reject path validation errors, don't fail the extraction
            switch error {
            case .systemError:
                // Fail for system errors
                throw error
            case .invalidRelativePath, .invalidPathComponent, .cannotFollowSymlink:
                return false
            }
        }
    }

    private func extractHardlink(
        memberPath: FilePath,
        targetPath: FilePath,
        rootFileDescriptor: FileDescriptor
    ) throws -> Bool {
        guard
            let memberName = memberPath.lastComponent,
            let targetName = targetPath.lastComponent
        else {
            return false
        }

        let memberParent = memberPath.removingLastComponent()
        let targetParent = targetPath.removingLastComponent()

        do {
            var linked = false
            try FileDescriptorOps.withOpenDirectory(rootFileDescriptor, targetParent) { targetParentFd in
                var targetStat = stat()
                guard
                    fstatat(
                        targetParentFd.rawValue,
                        targetName.string,
                        &targetStat,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0,
                    (targetStat.st_mode & S_IFMT) == S_IFREG
                else {
                    return
                }

                try FileDescriptorOps.mkdir(
                    rootFileDescriptor,
                    memberParent,
                    makeIntermediates: true
                ) { memberParentFd in
                    try? FileDescriptorOps.unlinkRecursive(memberParentFd, filename: memberName)
                    guard
                        linkat(
                            targetParentFd.rawValue,
                            targetName.string,
                            memberParentFd.rawValue,
                            memberName.string,
                            0
                        ) == 0
                    else {
                        throw ArchiveError.failedToExtractArchive(
                            "failed to create hard link: \(targetPath) <- \(memberPath)"
                        )
                    }
                    linked = true
                }
            }
            return linked
        } catch let error as FileDescriptorOps.Error {
            switch error {
            case .systemError:
                throw error
            case .invalidRelativePath, .invalidPathComponent, .cannotFollowSymlink:
                return false
            }
        }
    }

    private func setFileAttributes(fd: Int32, entry: WriteEntry, preserveOwnership: Bool) {
        if preserveOwnership, let owner = entry.owner, let group = entry.group {
            fchown(fd, owner, group)
        }
        fchmod(fd, entry.permissions & 0o7777)

        guard entry.contentAccessDate != nil || entry.modificationDate != nil else {
            return
        }
        var times = [
            entry.contentAccessDate.map(Self.makeTimespec) ?? Self.omittedTimespec,
            entry.modificationDate.map(Self.makeTimespec) ?? Self.omittedTimespec,
        ]
        _ = futimens(fd, &times)
    }

    private static var omittedTimespec: timespec {
        #if os(Linux)
        let utimeOmit = (1 << 30) - 2
        #else
        let utimeOmit = Int(UTIME_OMIT)
        #endif
        return timespec(tv_sec: 0, tv_nsec: utimeOmit)
    }

    private static func makeTimespec(_ date: Date) -> timespec {
        let interval = date.timeIntervalSince1970
        let seconds = floor(interval)
        return timespec(
            tv_sec: time_t(seconds),
            tv_nsec: Int((interval - seconds) * 1_000_000_000)
        )
    }

    private func copyEntryDataToFd(entry: WriteEntry, fileFd: Int32, memberPath: FilePath) throws {
        var finalSize: Int64 = 0
        while true {
            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            let result = archive_read_data_block(underlying, &buffer, &size, &offset)
            if result == ARCHIVE_EOF {
                break
            }
            guard result == ARCHIVE_OK, let buffer else {
                throw ArchiveError.failedToExtractArchive(
                    "failed to read data block for: \(memberPath)"
                )
            }

            var written = 0
            while written < size {
                let count = pwrite(
                    fileFd,
                    buffer.advanced(by: written),
                    size - written,
                    off_t(offset + Int64(written))
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw ArchiveError.failedToExtractArchive(
                        "failed to write data block for: \(memberPath)"
                    )
                }
                written += count
            }
            finalSize = Swift.max(finalSize, offset + Int64(size))
        }

        let expectedSize = entry.size ?? finalSize
        guard ftruncate(fileFd, off_t(expectedSize)) == 0 else {
            throw ArchiveError.failedToExtractArchive(
                "failed to set file size for: \(memberPath)"
            )
        }
    }
}
