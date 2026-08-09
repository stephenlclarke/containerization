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
    private static let loopControlGetFree: CUnsignedLong = 0x4C82
    private static let loopSetFileDescriptor: CUnsignedLong = 0x4C00
    private static let loopClearFileDescriptor: CUnsignedLong = 0x4C01

    let path: String
    private let descriptor: Int32

    /// Attach an ext4 image exposed by the host through `/run/virtiofs`.
    static func attach(backingFile: String) throws -> Self {
        let normalized = (backingFile as NSString).standardizingPath
        guard normalized == backingFile, normalized.hasPrefix("/run/virtiofs/") else {
            throw ContainerizationError(
                .invalidArgument,
                message: "loop backing file must be a normalized path below /run/virtiofs"
            )
        }

        let backingDescriptor = open(backingFile, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard backingDescriptor >= 0 else {
            throw posixError("open loop backing file")
        }
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
