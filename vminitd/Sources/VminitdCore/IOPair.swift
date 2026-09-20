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

import ContainerizationOS
import Foundation
import Logging
import Synchronization

final class IOPair: Sendable {
    private let io: Mutex<IO>
    private let logger: Logger?
    private let reason: String

    private struct IO {
        let from: IOCloser
        let to: IOCloser
        let buffer: UnsafeMutableBufferPointer<UInt8>
        var pending: Range<Int> = 0..<0
        var closed = false
        var closing = false
        var inputEnded = false
        var readerRegistered = false
        var writerRegistered = false
        var writerFD: Int32?

        mutating func finish(logger: Logger?) {
            guard !closed else { return }
            closed = true
            if readerRegistered {
                do {
                    try ProcessSupervisor.default.unregisterFd(from.fileDescriptor)
                } catch {
                    logger?.error("failed to unregister stdio reader: \(error)")
                }
                readerRegistered = false
            }
            if let writerFD {
                if writerRegistered {
                    do {
                        try ProcessSupervisor.default.unregisterFd(writerFD)
                    } catch {
                        logger?.error("failed to unregister stdio writer: \(error)")
                    }
                    writerRegistered = false
                }
                _ = Foundation.close(writerFD)
                self.writerFD = nil
            }
            do {
                try from.close()
            } catch {
                logger?.error("failed to close stdio reader: \(error)")
            }
            do {
                try to.close()
            } catch {
                logger?.error("failed to close stdio writer: \(error)")
            }
            buffer.deallocate()
        }

        mutating func pump(logger: Logger?) {
            guard !closed, let writerFD else { return }
            let source = OSFile(fd: from.fileDescriptor)
            let destination = OSFile(fd: writerFD)
            while true {
                if !pending.isEmpty {
                    let view = UnsafeMutableBufferPointer(
                        start: buffer.baseAddress?.advanced(by: pending.lowerBound),
                        count: pending.count
                    )
                    let result = destination.write(view)
                    pending = (pending.lowerBound + result.wrote)..<pending.upperBound
                    switch result.action {
                    case .error, .brokenPipe, .eof:
                        finish(logger: logger)
                        return
                    case .again:
                        // Keep the unwritten suffix until EPOLLOUT. Do not
                        // consume further input while these bytes are pending.
                        return
                    case .success:
                        break
                    }
                }
                if inputEnded {
                    finish(logger: logger)
                    return
                }
                let result = source.read(buffer)
                pending = 0..<result.read
                switch result.action {
                case .eof, .error, .brokenPipe:
                    inputEnded = true
                case .again:
                    inputEnded = closing
                case .success:
                    break
                }
                if pending.isEmpty {
                    if inputEnded {
                        finish(logger: logger)
                    }
                    return
                }
            }
        }
    }

    init(
        readFrom: IOCloser,
        writeTo: IOCloser,
        reason: String,
        logger: Logger? = nil
    ) {
        self.io = Mutex(
            IO(
                from: readFrom,
                to: writeTo,
                buffer: .allocate(capacity: Int(getpagesize()))
            ))
        self.reason = reason
        self.logger = logger
    }

    func relay(ignoreHup: Bool = false) throws {
        self.logger?.info("setting up relay for \(reason)")
        try self.io.withLock { io in
            guard !io.closed, io.writerFD == nil else {
                throw POSIXError(.EINVAL)
            }
            // A terminal's master is another IOPair's source too. A duplicate
            // keeps write readiness from replacing that pair's read handler.
            do {
                let writerFD = fcntl(io.to.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard writerFD >= 0 else {
                    throw POSIXError.fromErrno()
                }
                io.writerFD = writerFD
                try ProcessSupervisor.default.registerFd(writerFD, mask: .output) { mask in
                    self.io.withLock { io in
                        guard !io.closed else { return }
                        // A lost destination cannot accept the pending suffix,
                        // even when source-side PTY hangups are ignored.
                        if mask.isHangup {
                            io.finish(logger: self.logger)
                            return
                        }
                        io.pump(logger: self.logger)
                    }
                }
                io.writerRegistered = true
                try ProcessSupervisor.default.registerFd(io.from.fileDescriptor, mask: .input) { mask in
                    self.io.withLock { io in
                        guard !io.closed else { return }
                        if mask.isHangup && !ignoreHup {
                            io.closing = true
                        }
                        io.pump(logger: self.logger)
                    }
                }
                io.readerRegistered = true
            } catch {
                io.finish(logger: self.logger)
                throw error
            }
        }
    }

    func close() {
        self.io.withLock { io in
            guard !io.closed else { return }
            self.logger?.info("closing relay for \(reason)")
            io.closing = true
            if io.readerRegistered {
                // Exit can precede the last readable edge. Drain without
                // blocking the reaper or discarding a buffered suffix.
                io.pump(logger: self.logger)
            } else {
                io.finish(logger: self.logger)
            }
        }
    }
}

#endif
