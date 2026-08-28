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

import Cgroup
import Containerization
import ContainerizationError
import ContainerizationNetlink
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization

final class ManagedProcess: ContainerProcess, Sendable {
    // swiftlint: disable type_name
    protocol IO {
        func attach(pid: Int32, fd: Int32) throws
        func start(process: inout Command) throws
        func resize(size: Terminal.Size) throws
        func close() throws
        func closeStdin() throws
        func closeAfterExec() throws
    }
    // swiftlint: enable type_name

    private struct State {
        init(io: IO) {
            self.io = io
        }

        let io: IO
        var waiters: [CheckedContinuation<ContainerExitStatus, Never>] = []
        var exitStatus: ContainerExitStatus? = nil
        var pid: Int32?
        var mountNamespace: ProcessMountNamespace?
        var hostNetworkConfigured = false
    }

    private static let ackPid = "AckPid"
    private static let ackConsole = "AckConsole"

    let id: String

    private let log: Logger
    private let command: Command
    private let state: Mutex<State>
    private let owningPid: Int32?
    private let ackPipe: Pipe
    private let syncPipe: Pipe
    private let errorPipe: Pipe
    private let terminal: Bool
    private let bundle: ContainerizationOCI.Bundle
    private let networkEndpoints: [WorkloadNetworkEndpoint]

    var pid: Int32? {
        self.state.withLock {
            $0.exitStatus == nil ? $0.pid : nil
        }
    }

    func duplicateMountNamespace() throws -> Int32 {
        try self.state.withLock {
            guard $0.exitStatus == nil, let mountNamespace = $0.mountNamespace else {
                throw ContainerizationError(.invalidState, message: "process mount namespace is not available")
            }
            return try mountNamespace.duplicate()
        }
    }

    init(
        id: String,
        stdio: HostStdio,
        bundle: ContainerizationOCI.Bundle,
        spec: ContainerizationOCI.Spec? = nil,
        owningPid: Int32? = nil,
        log: Logger
    ) throws {
        self.id = id
        var log = log
        log[metadataKey: "id"] = "\(id)"
        self.log = log
        self.owningPid = owningPid

        let syncPipe = Pipe()
        try syncPipe.setCloexec()
        self.syncPipe = syncPipe

        let ackPipe = Pipe()
        try ackPipe.setCloexec()
        self.ackPipe = ackPipe

        let errorPipe = Pipe()
        try errorPipe.setCloexec()
        self.errorPipe = errorPipe

        let args: [String]
        if let owningPid {
            args = [
                "exec",
                "--parent-pid",
                "\(owningPid)",
                "--process-path",
                bundle.getExecSpecPath(id: id).path,
            ]
        } else {
            args = ["run", "--bundle-path", bundle.path.path]
        }

        var command = Command(
            "/sbin/vmexec",
            arguments: args,
            extraFiles: [
                syncPipe.fileHandleForWriting,
                ackPipe.fileHandleForReading,
                errorPipe.fileHandleForWriting,
            ]
        )

        var io: IO
        if stdio.terminal {
            log.info("setting up terminal I/O")
            let attrs = Command.Attrs(setsid: false, setctty: false)
            command.attrs = attrs
            io = try TerminalIO(
                stdio: stdio,
                log: log
            )
        } else {
            command.attrs = .init(setsid: false)
            io = StandardIO(
                stdio: stdio,
                log: log
            )
        }

        log.info("starting I/O")

        // Setup IO early. We expect the host to be listening already.
        try io.start(process: &command)

        self.command = command
        self.terminal = stdio.terminal
        self.bundle = bundle
        if let encoded = spec?.annotations?[WorkloadNetworkPlan.annotationKey] {
            let endpoints = try WorkloadNetworkPlan.decode(encoded)
            try WorkloadNetworkPlan.validate(endpoints)
            self.networkEndpoints = endpoints
        } else {
            self.networkEndpoints = []
        }
        self.state = Mutex(State(io: io))
    }
}

extension ManagedProcess {
    func start() async throws -> Int32 {
        do {
            return try self.state.withLock {
                log.info(
                    "starting managed process",
                    metadata: [
                        "id": "\(id)"
                    ])

                // Start the underlying process.
                try command.start()

                defer {
                    try? self.ackPipe.fileHandleForWriting.close()
                    try? self.syncPipe.fileHandleForReading.close()
                    try? self.ackPipe.fileHandleForReading.close()
                    try? self.syncPipe.fileHandleForWriting.close()
                    try? self.errorPipe.fileHandleForWriting.close()
                }

                // Close our side of any pipes.
                try $0.io.closeAfterExec()
                try self.ackPipe.fileHandleForReading.close()
                try self.syncPipe.fileHandleForWriting.close()
                try self.errorPipe.fileHandleForWriting.close()

                let size = MemoryLayout<Int32>.size
                guard let piddata = try syncPipe.fileHandleForReading.read(upToCount: size) else {
                    throw ContainerizationError(.internalError, message: "no PID data from sync pipe")
                }

                guard piddata.count == size else {
                    throw ContainerizationError(.internalError, message: "invalid payload")
                }

                let pid = piddata.withUnsafeBytes { ptr in
                    ptr.load(as: Int32.self)
                }

                log.info(
                    "got back pid data",
                    metadata: [
                        "pid": "\(pid)"
                    ])
                let mountNamespace = try ProcessMountNamespace(pid: pid)
                $0.pid = pid
                $0.mountNamespace = mountNamespace

                // This should probably happen in vmexec, but we don't need to set any cgroup
                // toggles so the problem is much simpler to just do it here.
                if let owningPid {
                    let cgManager = try Cgroup2Manager.loadFromPid(pid: owningPid)
                    try cgManager.addProcess(pid: pid)
                }

                try self.configureHostNetwork(peerNamespacePID: pid)
                $0.hostNetworkConfigured = !self.networkEndpoints.isEmpty

                log.info(
                    "sending pid acknowledgement",
                    metadata: [
                        "pid": "\(pid)"
                    ])
                try self.ackPipe.fileHandleForWriting.write(contentsOf: Self.ackPid.data(using: .utf8)!)

                if self.terminal {
                    log.info(
                        "wait for PTY FD",
                        metadata: [
                            "id": "\(id)"
                        ])

                    // Wait for a new write that will contain the pty fd if we asked for one.
                    guard let ptyFd = try self.syncPipe.fileHandleForReading.read(upToCount: size) else {
                        throw ContainerizationError(
                            .internalError,
                            message: "no PTY data from sync pipe"
                        )
                    }
                    let fd = ptyFd.withUnsafeBytes { ptr in
                        ptr.load(as: Int32.self)
                    }
                    log.info(
                        "received PTY FD from container, attaching",
                        metadata: [
                            "id": "\(id)"
                        ])

                    try $0.io.attach(pid: pid, fd: fd)
                    try self.ackPipe.fileHandleForWriting.write(contentsOf: Self.ackConsole.data(using: .utf8)!)
                }

                // Wait for the errorPipe to close (after exec).
                if let errorData = try? self.errorPipe.fileHandleForReading.readToEnd(),
                    let errorString = String(data: errorData, encoding: .utf8),
                    !errorString.isEmpty
                {
                    throw ContainerizationError(
                        .internalError,
                        message: "vmexec error: \(errorString.trimmingCharacters(in: .whitespacesAndNewlines))"
                    )
                }

                log.info(
                    "started managed process",
                    metadata: [
                        "pid": "\(pid)",
                        "id": "\(id)",
                    ])

                return pid
            }
        } catch {
            self.cleanupHostNetwork()
            self.state.withLock {
                $0.hostNetworkConfigured = false
                $0.mountNamespace = nil
                $0.pid = nil
            }
            if let errorData = try? self.errorPipe.fileHandleForReading.readToEnd(),
                let errorString = String(data: errorData, encoding: .utf8),
                !errorString.isEmpty
            {
                throw ContainerizationError(
                    .internalError,
                    message: "vmexec error: \(errorString.trimmingCharacters(in: .whitespacesAndNewlines))",
                    cause: error
                )
            }
            throw error
        }
    }

    func setExit(_ status: Int32) {
        self.state.withLock { state in
            self.log.info(
                "managed process exit",
                metadata: [
                    "status": "\(status)"
                ])

            let exitStatus = ContainerExitStatus(exitCode: status, exitedAt: Date.now)
            state.exitStatus = exitStatus
            state.mountNamespace = nil
            state.pid = nil

            do {
                try state.io.close()
            } catch {
                self.log.error("failed to close I/O for process: \(error)")
            }

            for waiter in state.waiters {
                waiter.resume(returning: exitStatus)
            }

            self.log.debug("\(state.waiters.count) managed process waiters signaled")
            state.waiters.removeAll()
        }
    }

    /// Wait on the process to exit
    func wait() async -> ContainerExitStatus {
        await withCheckedContinuation { cont in
            self.state.withLock {
                if let status = $0.exitStatus {
                    cont.resume(returning: status)
                    return
                }
                $0.waiters.append(cont)
            }
        }
    }

    func kill(_ signal: Int32) async throws {
        try self.state.withLock {
            guard let pid = $0.pid else {
                throw ContainerizationError(.invalidState, message: "process PID is required")
            }

            guard $0.exitStatus == nil else {
                return
            }

            self.log.info("sending signal \(signal) to process \(pid)")
            guard Foundation.kill(pid, signal) == 0 else {
                throw POSIXError.fromErrno()
            }
        }
    }

    func resize(size: Terminal.Size) throws {
        try self.state.withLock {
            guard $0.exitStatus == nil else {
                return
            }
            try $0.io.resize(size: size)
        }
    }

    func closeStdin() throws {
        let io = self.state.withLock { $0.io }
        try io.closeStdin()
    }

    func delete() async throws {
        // vmexec doesn't require explicit cleanup - the process is cleaned up
        // when it exits and IO is closed via setExit()
        let shouldCleanup = self.state.withLock { state in
            defer { state.hostNetworkConfigured = false }
            return state.hostNetworkConfigured
        }
        if shouldCleanup {
            self.cleanupHostNetwork()
        }
    }

    private func configureHostNetwork(peerNamespacePID: Int32) throws {
        guard !networkEndpoints.isEmpty else { return }
        let session = NetlinkSession(socket: try DefaultNetlinkSocket(), log: log)
        var created: [String] = []
        do {
            for endpoint in networkEndpoints {
                try session.linkAddVeth(
                    hostName: endpoint.hostInterfaceName,
                    peerName: endpoint.interface.name,
                    peerNamespacePID: peerNamespacePID
                )
                created.append(endpoint.hostInterfaceName)
                if let bridge = endpoint.bridgeInterfaceName {
                    try session.linkSetAttributes(
                        interface: endpoint.hostInterfaceName,
                        master: bridge
                    )
                }
                try session.linkSet(
                    interface: endpoint.hostInterfaceName,
                    up: true,
                    mtu: endpoint.interface.mtu
                )
            }
        } catch {
            for name in created.reversed() {
                try? session.linkDel(name: name)
            }
            throw error
        }
    }

    private func cleanupHostNetwork() {
        guard !networkEndpoints.isEmpty,
            let socket = try? DefaultNetlinkSocket()
        else { return }
        let session = NetlinkSession(socket: socket, log: log)
        for endpoint in networkEndpoints.reversed() {
            try? session.linkDel(name: endpoint.hostInterfaceName)
        }
    }
}

#endif
