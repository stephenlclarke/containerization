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

#if os(macOS)
import Foundation
import Logging
import Virtualization
import ContainerizationError

extension VZVirtualMachine {
    nonisolated func connect(queue: DispatchQueue, port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.sync {
                guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                    let error = ContainerizationError(.invalidArgument, message: "no vsock device")
                    cont.resume(throwing: error)
                    return
                }
                vsock.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        // `conn` isn't used concurrently.
                        nonisolated(unsafe) let conn = conn
                        cont.resume(returning: conn)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func listen(queue: DispatchQueue, port: UInt32, listener: VZVirtioSocketListener) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(.invalidArgument, message: "no vsock device")
            }
            vsock.setSocketListener(listener, forPort: port)
        }
    }

    func removeListener(queue: DispatchQueue, port: UInt32) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock device to remove"
                )
            }
            vsock.removeSocketListener(forPort: port)
        }
    }

    func start(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.start { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func stop(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func pause(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.pause { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func resume(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.resume { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func memoryBalloonTarget(queue: DispatchQueue) throws -> UInt64 {
        try queue.sync {
            guard let balloon = self.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
                throw ContainerizationError(.unsupported, message: "no virtio memory balloon device")
            }
            return balloon.targetVirtualMachineMemorySize
        }
    }

    func setMemoryBalloonTarget(queue: DispatchQueue, memoryInBytes: UInt64) throws {
        try queue.sync {
            guard let balloon = self.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
                throw ContainerizationError(.unsupported, message: "no virtio memory balloon device")
            }
            balloon.targetVirtualMachineMemorySize = memoryInBytes
        }
    }
}

extension VZVirtualMachine {
    func waitForAgent(queue: DispatchQueue) async throws -> FileHandle {
        // Preserve the previous 201-attempt, 20 ms sleep budget while adding
        // earlier connection attempts inside each original 20 ms interval.
        var remainingRetryDelay: Duration = .milliseconds(4020)
        var pollBackoff = PollBackoff(
            initialDelay: .milliseconds(5),
            maximumDelay: .milliseconds(20)
        )
        var lastError: (any Error)?

        while remainingRetryDelay > .zero {
            do {
                return try await self.connect(queue: queue, port: Vminitd.port).dupHandle()
            } catch {
                lastError = error
                let delay = min(pollBackoff.next(), remainingRetryDelay)
                try await Task.sleep(for: delay)
                remainingRetryDelay -= delay
            }
        }
        throw ContainerizationError(
            .timeout,
            message: "failed to get a connection to agent socket",
            cause: lastError
        )
    }
}

extension VZVirtioSocketConnection {
    func dupHandle() throws -> FileHandle {
        let fd = dup(self.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        retainConnectionOwner(self, for: handle)
        return handle
    }
}

#endif
