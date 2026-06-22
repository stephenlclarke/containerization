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
import Foundation
import Synchronization
import Testing

import struct ContainerizationOCI.ImageConfig
import struct ContainerizationOCI.Mount
import struct ContainerizationOCI.Spec

@testable import Containerization

struct LinuxContainerTests {

    @Test func processInitFromImageConfigWithAllFields() {
        let imageConfig = ImageConfig(
            user: "appuser",
            env: ["NODE_ENV=production", "PORT=3000"],
            entrypoint: ["/usr/bin/node"],
            cmd: ["app.js", "--verbose"],
            workingDir: "/app"
        )

        let process = LinuxProcessConfiguration(from: imageConfig)

        #expect(process.workingDirectory == "/app")
        #expect(process.environmentVariables == ["NODE_ENV=production", "PORT=3000"])
        #expect(process.arguments == ["/usr/bin/node", "app.js", "--verbose"])
        #expect(process.user.username == "appuser")
    }

    @Test func processInitFromImageConfigWithNilValues() {
        let imageConfig = ImageConfig(
            user: nil,
            env: nil,
            entrypoint: nil,
            cmd: nil,
            workingDir: nil
        )

        let process = LinuxProcessConfiguration(from: imageConfig)

        #expect(process.workingDirectory == "/")
        #expect(process.environmentVariables == [])
        #expect(process.arguments == [])
        #expect(process.user.username == "")  // Default User() has empty string username
    }

    @Test func processInitFromImageConfigEntrypointAndCmdConcatenation() {
        let imageConfig = ImageConfig(
            entrypoint: ["/bin/sh", "-c"],
            cmd: ["echo 'hello'", "&&", "sleep 10"]
        )

        let process = LinuxProcessConfiguration(from: imageConfig)

        #expect(process.arguments == ["/bin/sh", "-c", "echo 'hello'", "&&", "sleep 10"])
    }

    @Test func runtimeSpecIncludesConfiguredBlockIO() throws {
        let blockIO = LinuxBlockIO(
            weight: 500,
            leafWeight: 300,
            weightDevice: [
                LinuxWeightDevice(major: 8, minor: 0, weight: 700, leafWeight: 400)
            ],
            throttleReadBpsDevice: [
                LinuxThrottleDevice(major: 8, minor: 16, rate: 1_048_576)
            ],
            throttleWriteBpsDevice: [
                LinuxThrottleDevice(major: 8, minor: 32, rate: 2_097_152)
            ],
            throttleReadIOPSDevice: [
                LinuxThrottleDevice(major: 8, minor: 48, rate: 1_000)
            ],
            throttleWriteIOPSDevice: [
                LinuxThrottleDevice(major: 8, minor: 64, rate: 2_000)
            ]
        )

        let container = try LinuxContainer(
            "blkio-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init(process: .init(), blockIO: blockIO)
        )

        let resources = try #require(container.generateRuntimeSpec().linux?.resources)
        let specBlockIO = try #require(resources.blockIO)

        #expect(specBlockIO.weight == 500)
        #expect(specBlockIO.leafWeight == 300)
        #expect(specBlockIO.weightDevice.first?.major == 8)
        #expect(specBlockIO.weightDevice.first?.minor == 0)
        #expect(specBlockIO.weightDevice.first?.weight == 700)
        #expect(specBlockIO.weightDevice.first?.leafWeight == 400)
        #expect(specBlockIO.throttleReadBpsDevice.first?.rate == 1_048_576)
        #expect(specBlockIO.throttleWriteBpsDevice.first?.rate == 2_097_152)
        #expect(specBlockIO.throttleReadIOPSDevice.first?.rate == 1_000)
        #expect(specBlockIO.throttleWriteIOPSDevice.first?.rate == 2_000)
    }

    @Test func pauseAndResumeTransitionRunningContainer() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "pause-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init()
        )

        try await container.create()
        try await container.start()

        let vm = try #require(manager.vm)

        try await container.pause()
        #expect(vm.state == .running)
        #expect(vm.pauseCalls == 1)
        #expect(vm.resumeCalls == 0)

        try await container.resume()
        #expect(vm.state == .running)
        #expect(vm.pauseCalls == 1)
        #expect(vm.resumeCalls == 1)
    }

    @Test func pauseRequiresRunningContainer() async throws {
        let container = try LinuxContainer(
            "pause-invalid",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init()
        )

        await expectInvalidState {
            try await container.pause()
        }
    }

    @Test func resumeRequiresPausedContainer() async throws {
        let container = try LinuxContainer(
            "resume-invalid",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init()
        )

        await expectInvalidState {
            try await container.resume()
        }
    }
}

private struct StubVirtualMachineManager: VirtualMachineManager {
    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        fatalError("StubVirtualMachineManager.create should not be called by LinuxContainerTests")
    }
}

private func expectInvalidState(operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected invalidState error")
    } catch let error as ContainerizationError {
        #expect(error.code == .invalidState)
    } catch {
        Issue.record("expected ContainerizationError, got \(error)")
    }
}

private final class RecordingVirtualMachineManager: VirtualMachineManager, @unchecked Sendable {
    private let state = Mutex<RecordingVirtualMachineInstance?>(nil)

    var vm: RecordingVirtualMachineInstance? {
        state.withLock { $0 }
    }

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        let vm = RecordingVirtualMachineInstance(configuration: config.configuration)
        state.withLock { $0 = vm }
        return vm
    }
}

private final class RecordingVirtualMachineInstance: VirtualMachineInstance, @unchecked Sendable {
    typealias Agent = RecordingVirtualMachineAgent

    private struct State {
        var value: VirtualMachineInstanceState = .unknown
        var pauseCalls = 0
        var resumeCalls = 0
    }

    private let storage = Mutex<State>(State())
    private let agent = RecordingVirtualMachineAgent()

    let mounts: [String: [AttachedFilesystem]]

    var state: VirtualMachineInstanceState {
        storage.withLock { $0.value }
    }

    var pauseCalls: Int {
        storage.withLock { $0.pauseCalls }
    }

    var resumeCalls: Int {
        storage.withLock { $0.resumeCalls }
    }

    init(configuration: VMConfiguration) {
        self.mounts = configuration.mountsByID.mapValues { mounts in
            mounts.map {
                AttachedFilesystem(
                    type: $0.type,
                    source: $0.source,
                    destination: $0.destination,
                    options: $0.options
                )
            }
        }
    }

    func dialAgent() async throws -> RecordingVirtualMachineAgent {
        agent
    }

    func dial(_ port: UInt32) async throws -> FileHandle {
        throw ContainerizationError(.internalError, message: "dial should not be called by LinuxContainerTests")
    }

    func listen(_ port: UInt32) throws -> VsockListener {
        throw ContainerizationError(.internalError, message: "listen should not be called by LinuxContainerTests")
    }

    func start() async throws {
        storage.withLock { $0.value = .running }
    }

    func stop() async throws {
        storage.withLock { $0.value = .stopped }
    }

    func pause() async throws {
        storage.withLock {
            $0.pauseCalls += 1
            $0.value = .running
        }
    }

    func resume() async throws {
        storage.withLock {
            $0.resumeCalls += 1
            $0.value = .running
        }
    }
}

private final class RecordingVirtualMachineAgent: VirtualMachineAgent, @unchecked Sendable {
    func standardSetup() async throws {}

    func close() async throws {}

    func getenv(key: String) async throws -> String {
        ""
    }

    func setenv(key: String, value: String) async throws {}

    func mount(_ mount: ContainerizationOCI.Mount) async throws {}

    func umount(path: String, flags: Int32) async throws {}

    func mkdir(path: String, all: Bool, perms: UInt32) async throws {}

    func kill(pid: Int32, signal: Int32) async throws -> Int32 {
        0
    }

    func sync() async throws {}

    func writeFile(path: String, data: Data, flags: WriteFileFlags, mode: UInt32) async throws {}

    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        ociRuntimePath: String?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws {}

    func startProcess(id: String, containerID: String?) async throws -> Int32 {
        1
    }

    func signalProcess(id: String, containerID: String?, signal: Int32) async throws {}

    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws {}

    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> Containerization.ExitStatus {
        Containerization.ExitStatus(exitCode: 0)
    }

    func deleteProcess(id: String, containerID: String?) async throws {}

    func closeProcessStdin(id: String, containerID: String?) async throws {}

    func up(name: String, mtu: UInt32?) async throws {}

    func down(name: String) async throws {}

    func addressAdd(name: String, address: InterfaceAddress) async throws {}

    func routeAddLink(name: String, route: LinkRoute) async throws {}

    func routeAddDefault(name: String, route: DefaultRoute) async throws {}

    func configureDNS(config: DNS, location: String) async throws {}

    func configureHosts(config: Hosts, location: String) async throws {}

    func containerStatistics(containerIDs: [String], categories: StatCategory) async throws -> [ContainerStatistics] {
        []
    }
}
