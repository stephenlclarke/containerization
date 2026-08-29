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

import CShim
import ContainerizationError
import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// One guest loop device backed by a regular file in the trusted unified
/// virtiofs share.
struct LoopbackDevice: Sendable {
    private struct TrustedBackingFilePath {
        let root: String
        let source: String
        let relativePath: String
    }

    private static let loopControlGetFree: CUnsignedLong = 0x4C82
    private static let loopSetFileDescriptor: CUnsignedLong = 0x4C00
    private static let loopClearFileDescriptor: CUnsignedLong = 0x4C01

    let path: String
    private let descriptor: Int32

    /// Attach an ext4 image exposed by the host through a trusted virtiofs mount.
    static func attach(backingFile: String) throws -> Self {
        guard let trustedPath = trustedBackingFilePath(backingFile) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "loop backing file must be a normalized path below a trusted virtiofs mount"
            )
        }

        let rootDescriptor = open(
            trustedPath.root,
            CZ_O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw posixError("open loop backing root")
        }
        defer { _ = close(rootDescriptor) }

        let descriptorInfo: String
        let mountInfo: String
        do {
            descriptorInfo = try String(
                contentsOfFile: "/proc/self/fdinfo/\(rootDescriptor)",
                encoding: .utf8
            )
            mountInfo = try String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "read guest mount information",
                cause: error
            )
        }
        guard
            let mountID = mountID(fromDescriptorInfo: descriptorInfo),
            mountInfoContainsVirtiofs(
                mountInfo,
                mountID: mountID,
                root: trustedPath.root,
                source: trustedPath.source
            )
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "loop backing root is not an active reserved virtiofs mount"
            )
        }

        let backingDescriptor = try openBackingFile(
            rootDescriptor: rootDescriptor,
            relativePath: trustedPath.relativePath
        )
        defer { _ = close(backingDescriptor) }

        var info = stat()
        guard fstat(backingDescriptor, &info) == 0 else {
            throw posixError("stat loop backing file")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ContainerizationError(
                .invalidArgument,
                message: "loop backing path is not a regular file"
            )
        }

        let controlDescriptor = open("/dev/loop-control", O_RDWR | O_CLOEXEC)
        guard controlDescriptor >= 0 else {
            throw posixError("open loop control")
        }
        defer { _ = close(controlDescriptor) }

        let getFree: @convention(c) (CInt, CUnsignedLong) -> CInt = ioctl
        let index = getFree(controlDescriptor, loopControlGetFree)
        guard index >= 0 else {
            throw posixError("allocate loop device")
        }

        let path = "/dev/loop\(index)"
        let descriptor = open(path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError("open loop device")
        }

        let setFileDescriptor: @convention(c) (CInt, CUnsignedLong, CInt) -> CInt = ioctl
        guard setFileDescriptor(descriptor, loopSetFileDescriptor, backingDescriptor) == 0 else {
            let error = posixError("attach loop backing file")
            _ = close(descriptor)
            throw error
        }

        return Self(path: path, descriptor: descriptor)
    }

    static func isTrustedBackingFilePath(_ path: String) -> Bool {
        trustedBackingFilePath(path) != nil
    }

    private static func trustedBackingFilePath(_ path: String) -> TrustedBackingFilePath? {
        let normalized = (path as NSString).standardizingPath
        guard normalized == path else { return nil }

        let stableRoot = "/run/virtiofs"
        let stablePrefix = stableRoot + "/"
        if normalized.hasPrefix(stablePrefix) {
            let relativePath = String(normalized.dropFirst(stablePrefix.count))
            guard !relativePath.isEmpty else { return nil }
            return TrustedBackingFilePath(
                root: stableRoot,
                source: "virtiofs",
                relativePath: relativePath
            )
        }

        let prefix = "/run/runtime-virtiofs-"
        guard normalized.hasPrefix(prefix) else { return nil }
        let suffix = normalized.dropFirst(prefix.count)
        guard let separator = suffix.firstIndex(of: "/") else { return nil }
        let deviceIndex = suffix[..<separator]
        guard
            deviceIndex.utf8.count == 2,
            deviceIndex.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let deviceIndexValue = Int(deviceIndex),
            deviceIndexValue < 64
        else {
            return nil
        }

        let relativePath = String(suffix[suffix.index(after: separator)...])
        guard !relativePath.isEmpty else { return nil }
        let source = "runtime-virtiofs-\(deviceIndex)"
        return TrustedBackingFilePath(
            root: "/run/\(source)",
            source: source,
            relativePath: relativePath
        )
    }

    static func mountInfoContainsVirtiofs(
        _ mountInfo: String,
        mountID: UInt64,
        root: String,
        source: String
    ) -> Bool {
        mountInfo.split(separator: "\n").contains { line in
            let sections = String(line).components(separatedBy: " - ")
            guard sections.count == 2 else { return false }
            let mountFields = sections[0].split(separator: " ")
            let filesystemFields = sections[1].split(separator: " ")
            return mountFields.count >= 5
                && UInt64(mountFields[0]) == mountID
                && mountFields[4] == root
                && filesystemFields.count >= 2
                && filesystemFields[0] == "virtiofs"
                && filesystemFields[1] == source
        }
    }

    static func mountID(fromDescriptorInfo descriptorInfo: String) -> UInt64? {
        for line in descriptorInfo.split(separator: "\n") {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2, fields[0] == "mnt_id" else { continue }
            return UInt64(fields[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func openBackingFile(
        rootDescriptor: Int32,
        relativePath: String
    ) throws -> Int32 {
        let descriptor = relativePath.withCString { relativePath in
            var how = cz_open_how(
                flags: UInt64(O_RDWR | O_CLOEXEC | O_NOFOLLOW),
                mode: 0,
                resolve: UInt64(
                    RESOLVE_BENEATH
                        | RESOLVE_NO_MAGICLINKS
                        | RESOLVE_NO_SYMLINKS
                        | RESOLVE_NO_XDEV
                )
            )
            return CZ_openat2(
                rootDescriptor,
                relativePath,
                &how,
                MemoryLayout<cz_open_how>.size
            )
        }
        guard descriptor >= 0 else {
            throw posixError("open loop backing file")
        }
        return descriptor
    }

    /// Detach the backing file after its filesystem has been unmounted.
    func detach() throws {
        let clearFileDescriptor: @convention(c) (CInt, CUnsignedLong) -> CInt = ioctl
        guard clearFileDescriptor(descriptor, Self.loopClearFileDescriptor) == 0 else {
            throw Self.posixError("detach loop backing file")
        }
        _ = close(descriptor)
    }

    private static func posixError(_ operation: String) -> ContainerizationError {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return ContainerizationError(
            .internalError,
            message: operation,
            cause: POSIXError(code)
        )
    }
}

#endif
