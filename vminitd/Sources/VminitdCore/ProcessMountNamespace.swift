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

import Foundation

struct ProcessFilesystemDescriptors: Sendable {
    let mountNamespace: Int32
    let root: Int32
}

/// Pins a process mount namespace independently of the process numeric PID.
final class ProcessMountNamespace: Sendable {
    private let fileDescriptor: Int32

    init(pid: Int32) throws {
        let fileDescriptor = Foundation.open("/proc/\(pid)/ns/mnt", O_RDONLY | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Foundation.close(self.fileDescriptor)
    }

    /// Returns a close-on-exec descriptor owned by the caller.
    func duplicate() throws -> Int32 {
        let fileDescriptor = Foundation.fcntl(self.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        return fileDescriptor
    }
}

/// Pins a process filesystem root independently of the process numeric PID.
final class ProcessRoot: Sendable {
    private let fileDescriptor: Int32

    init(pid: Int32) throws {
        let fileDescriptor = Foundation.open("/proc/\(pid)/root", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Foundation.close(self.fileDescriptor)
    }

    /// Returns a close-on-exec descriptor owned by the caller.
    func duplicate() throws -> Int32 {
        let fileDescriptor = Foundation.fcntl(self.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        return fileDescriptor
    }
}

#endif
