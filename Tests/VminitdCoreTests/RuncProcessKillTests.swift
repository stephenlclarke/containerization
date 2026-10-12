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

import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import VminitdCore

struct RuncProcessKillTests {
    @Test func exitedProcessDoesNotExecuteUnavailableRunc() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = try makeProcess(root: root, command: root.appending(path: "missing-runc").path)

        process.setExit(0)
        try await process.kill(15)
        #expect((await process.wait()).exitCode == 0)
        #expect(process.pid == nil)
    }

    @Test func nonExitedProcessSendsSignalThroughRunc() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appending(path: "fake-runc")
        let arguments = root.appending(path: "fake-runc.args")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"${0}.args\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let process = try makeProcess(root: root, command: command.path)

        try await process.kill(15)
        let invoked = try String(contentsOf: arguments, encoding: .utf8)
        #expect(invoked.contains("kill test-runc-process 15"))
    }

    private func makeProcess(root: URL, command: String) throws -> RuncProcess {
        let bundle = try ContainerizationOCI.Bundle.create(path: root.appending(path: "bundle"), spec: Spec())
        return try RuncProcess(
            id: "test-runc-process",
            stdio: HostStdio(stdin: nil, stdout: nil, stderr: nil, terminal: false),
            bundle: bundle,
            runc: Runc(command: command, root: root.path, log: root.appending(path: "runc.log").path),
            log: Logger(label: "RuncProcessKillTests")
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "runc-process-kill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

#endif
