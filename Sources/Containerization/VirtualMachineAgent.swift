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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation

public struct WriteFileFlags {
    public var createParentDirectories = false
    public var append = false
    public var create = false
}

public enum FilesystemOperation: Sendable {
    case freeze
    case thaw
    case trim
}

/// A protocol for the agent running inside a virtual machine. If an operation isn't
/// supported the implementation MUST return a ContainerizationError with a code of
/// `.unsupported`.
public protocol VirtualMachineAgent: Sendable {
    /// Perform a platform specific standard setup
    /// of the runtime environment.
    func standardSetup() async throws
    /// Close any resources held by the agent.
    func close() async throws
    // Perform a filesystem operation on the given path.
    func filesystemOperation(operation: FilesystemOperation, path: String) async throws

    // POSIX-y
    func getenv(key: String) async throws -> String
    func setenv(key: String, value: String) async throws
    func mount(_ mount: ContainerizationOCI.Mount) async throws
    func umount(path: String, flags: Int32) async throws
    func mkdir(path: String, all: Bool, perms: UInt32) async throws
    @discardableResult
    func kill(pid: Int32, signal: Int32) async throws -> Int32
    func sync() async throws
    func writeFile(path: String, data: Data, flags: WriteFileFlags, mode: UInt32) async throws
    func stat(path: URL) async throws -> ContainerizationOS.Stat

    // Process lifecycle
    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        ociRuntimePath: String?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws
    func startProcess(id: String, containerID: String?) async throws -> Int32
    func signalProcess(id: String, containerID: String?, signal: Int32) async throws
    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws
    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> ExitStatus
    func deleteProcess(id: String, containerID: String?) async throws
    func closeProcessStdin(id: String, containerID: String?) async throws

    // Networking
    func up(name: String, mtu: UInt32?) async throws
    func down(name: String) async throws
    func rename(name: String, to newName: String) async throws
    func addressAdd(name: String, address: InterfaceAddress) async throws
    func addressAdd(name: String, address: CIDR) async throws
    func routeAddLink(name: String, route: LinkRoute) async throws
    func routeAddDefault(name: String, route: DefaultRoute) async throws
    func configureDNS(config: DNS, location: String) async throws
    func configureHosts(config: Hosts, location: String) async throws

    // Container statistics
    func containerStatistics(containerIDs: [String], categories: StatCategory) async throws -> [ContainerStatistics]
    func containerProcesses(containerID: String) async throws -> [Int32]
    func containerProcessInfo(containerID: String) async throws -> [ContainerProcessInfo]

}

extension VirtualMachineAgent {
    /// Add a single IPv4 or IPv6 address to a network interface.
    public func addressAdd(name: String, address: CIDR) async throws {
        switch address {
        case .v4(let ipv4Address, let prefix):
            try await addressAdd(
                name: name,
                address: .init(ipv4Address: try CIDRv4(ipv4Address, prefix: prefix))
            )
        case .v6:
            throw ContainerizationError(.unsupported, message: "adding IPv6-only interface addresses")
        }
    }

    public func rename(name: String, to newName: String) async throws {
        throw ContainerizationError(.unsupported, message: "rename interface")
    }

    public func closeProcessStdin(id: String, containerID: String?) async throws {
        throw ContainerizationError(.unsupported, message: "closeProcessStdin")
    }

    public func configureHosts(config: Hosts, location: String) async throws {
        throw ContainerizationError(.unsupported, message: "configureHosts")
    }

    public func writeFile(path: String, data: Data, flags: WriteFileFlags, mode: UInt32) async throws {
        throw ContainerizationError(.unsupported, message: "writeFile")
    }

    public func containerStatistics(containerIDs: [String], categories: StatCategory) async throws -> [ContainerStatistics] {
        throw ContainerizationError(.unsupported, message: "containerStatistics")
    }

    public func containerProcesses(containerID: String) async throws -> [Int32] {
        throw ContainerizationError(.unsupported, message: "containerProcesses")
    }

    public func containerProcessInfo(containerID: String) async throws -> [ContainerProcessInfo] {
        throw ContainerizationError(.unsupported, message: "containerProcessInfo")
    }

    public func sync() async throws {
        throw ContainerizationError(.unsupported, message: "sync")
    }

    public func stat(path: URL) async throws -> ContainerizationOS.Stat {
        throw ContainerizationError(.unsupported, message: "stat")
    }

}
