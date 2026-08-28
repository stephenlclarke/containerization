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

import Dispatch
import Foundation
import Synchronization
import Testing

@testable import vmexec

struct MountTests {
    @Test func concurrentConsoleConfigurationIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dev = root.appendingPathComponent("dev")
        let ptmx = dev.appendingPathComponent("ptmx")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data().write(to: ptmx)
        defer { try? FileManager.default.removeItem(at: root) }

        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                try ContainerMount(rootfs: root.path, mounts: []).configureConsole()
            } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }

        #expect(failures.withLock { $0 }.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: ptmx.path) == "pts/ptmx")
    }
}
