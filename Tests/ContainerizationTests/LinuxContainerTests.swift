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
import ContainerizationOS
import Foundation
import Synchronization
import Testing

import struct ContainerizationOCI.ImageConfig
import struct ContainerizationOCI.LinuxDevice
import struct ContainerizationOCI.LinuxDeviceCgroup
import enum ContainerizationOCI.LinuxNamespaceType
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

    @Test func defaultCapabilitiesAreRestrictedOCISet() {
        // Regression guard against shipping `.allCapabilities` as the default.
        // A default container must not receive CAP_SYS_ADMIN, which would let it
        // write /proc/sys/kernel/core_pattern and escape to guest-root. Cover both
        // construction paths: the no-argument init and the memberwise init.
        let viaProperty = LinuxProcessConfiguration()
        let viaInit = LinuxProcessConfiguration(arguments: ["/bin/sh"])

        for caps in [viaProperty.capabilities, viaInit.capabilities] {
            for set in [caps.bounding, caps.effective, caps.permitted, caps.inheritable, caps.ambient] {
                #expect(!set.contains(.sysAdmin), "default capabilities must not include CAP_SYS_ADMIN")
            }
        }

        let expected = LinuxCapabilities.defaultOCICapabilities
        #expect(viaProperty.capabilities.bounding == expected.bounding)
        #expect(viaProperty.capabilities.effective == expected.effective)
        #expect(viaProperty.capabilities.permitted == expected.permitted)
        #expect(viaProperty.capabilities.inheritable == expected.inheritable)
        #expect(viaProperty.capabilities.ambient == expected.ambient)
        #expect(viaInit.capabilities.bounding == expected.bounding)
    }

    @Test func defaultMaskedAndReadonlyPathsAreOCISet() {
        // Regression guard: masked/readonly paths must default to the OCI
        // standard set now that capabilities default to the restricted baseline.
        // Without CAP_SYS_ADMIN a workload can't unmount these, so the defaults
        // are meaningful defense-in-depth — shipping empty defaults would leave
        // /proc/kcore and friends exposed. Cover both construction paths and
        // both configuration types.
        let expectedMasked = LinuxContainer.defaultMaskedPaths()
        let expectedReadonly = LinuxContainer.defaultReadonlyPaths()

        // Sensitive kernel paths must actually be in the defaults.
        #expect(expectedMasked.contains("/proc/kcore"))
        #expect(expectedMasked.contains("/sys/firmware"))
        #expect(expectedReadonly.contains("/proc/sys"))

        let containerViaProperty = LinuxContainer.Configuration()
        let containerViaInit = LinuxContainer.Configuration(process: LinuxProcessConfiguration(arguments: ["/bin/sh"]))
        let pod = LinuxPod.ContainerConfiguration()

        for config in [containerViaProperty, containerViaInit] {
            #expect(config.maskedPaths == expectedMasked)
            #expect(config.readonlyPaths == expectedReadonly)
        }
        #expect(pod.maskedPaths == expectedMasked)
        #expect(pod.readonlyPaths == expectedReadonly)
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

    @Test func runtimeSpecIncludesConfiguredPidsLimit() throws {
        let container = try LinuxContainer(
            "pids-limit-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init(process: .init(), pidsLimit: 128)
        )

        let resources = try #require(container.generateRuntimeSpec().linux?.resources)

        #expect(resources.pids?.limit == 128)
    }

    @Test func runtimeSpecIncludesConfiguredDeviceCgroupRules() throws {
        let deviceRules = [
            LinuxDeviceCgroup(allow: true, type: "c", major: 1, minor: 3, access: "mr"),
            LinuxDeviceCgroup(allow: true, type: "a", major: nil, minor: nil, access: "rwm"),
        ]

        let container = try LinuxContainer(
            "device-cgroup-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init(process: .init(), deviceCgroupRules: deviceRules)
        )

        let resources = try #require(container.generateRuntimeSpec().linux?.resources)

        #expect(resources.devices.count == 2)
        #expect(resources.devices[0].allow)
        #expect(resources.devices[0].type == "c")
        #expect(resources.devices[0].major == 1)
        #expect(resources.devices[0].minor == 3)
        #expect(resources.devices[0].access == "mr")
        #expect(resources.devices[1].allow)
        #expect(resources.devices[1].type == "a")
        #expect(resources.devices[1].major == nil)
        #expect(resources.devices[1].minor == nil)
        #expect(resources.devices[1].access == "rwm")
    }

    @Test func runtimeSpecIncludesConfiguredDeviceNodes() throws {
        let devices = [
            LinuxDevice(
                path: "/dev/xnull",
                type: "c",
                major: 1,
                minor: 3,
                fileMode: 0o666,
                uid: 0,
                gid: 0
            )
        ]

        let container = try LinuxContainer(
            "device-node-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init(process: .init(), devices: devices)
        )

        let specDevices = try #require(container.generateRuntimeSpec().linux?.devices)

        #expect(specDevices.count == 1)
        #expect(specDevices[0].path == "/dev/xnull")
        #expect(specDevices[0].type == "c")
        #expect(specDevices[0].major == 1)
        #expect(specDevices[0].minor == 3)
        #expect(specDevices[0].fileMode == 0o666)
        #expect(specDevices[0].uid == 0)
        #expect(specDevices[0].gid == 0)
    }

    @Test func runtimeSpecCanUseHostPIDNamespace() throws {
        let isolatedContainer = try LinuxContainer(
            "pid-isolated-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init()
        )
        let hostPIDContainer = try LinuxContainer(
            "pid-host-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: StubVirtualMachineManager(),
            configuration: .init(process: .init(), hostPIDNamespace: true)
        )

        let isolatedNamespaces = try #require(isolatedContainer.generateRuntimeSpec().linux?.namespaces)
        let hostPIDNamespaces = try #require(hostPIDContainer.generateRuntimeSpec().linux?.namespaces)

        #expect(isolatedNamespaces.contains { $0.type == .pid })
        #expect(!hostPIDNamespaces.contains { $0.type == .pid })
        #expect(
            hostPIDNamespaces.map { $0.type } == [
                LinuxNamespaceType.cgroup,
                LinuxNamespaceType.ipc,
                LinuxNamespaceType.mount,
                LinuxNamespaceType.uts,
            ])
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

    @Test func graphicsConfigurationIsForwardedToVM() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "graphics-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init(
                process: .init(),
                graphics: .display()
            )
        )

        try await container.create()

        let configuration = try #require(manager.vm?.configuration)
        #expect(configuration.graphics == .display())
        #expect(configuration.graphics.isEnabled)
        #expect(configuration.graphics.hasDisplay)
    }

    @Test func graphicsConfigurationCanRetainTheMandatoryVZScanout() {
        var configuration = LinuxContainer.Configuration()

        configuration.graphics = .display()

        #expect(configuration.graphics == .display())
        #expect(configuration.graphics.isEnabled)
        #expect(configuration.graphics.hasDisplay)

        configuration.graphics = .virtioDevice

        #expect(configuration.graphics == .virtioDevice)
        #expect(configuration.graphics.isEnabled)
        #expect(!configuration.graphics.hasDisplay)
    }

    @available(*, deprecated)
    @Test func legacyGraphicsDeviceOnlyCaseRemainsUsable() {
        var configuration = LinuxContainer.Configuration()
        configuration.graphics = .deviceOnly

        #expect(configuration.graphics.isEnabled)
        #expect(!configuration.graphics.hasDisplay)
    }

    @Test func startDiscoversConfiguredGuestDeviceNodes() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "guest-device-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init(
                process: .init(),
                guestDevices: [
                    LinuxGuestDeviceRequest(path: "/dev/dri/card0"),
                    LinuxGuestDeviceRequest(path: "/dev/dri/renderD128"),
                ]
            )
        )

        try await container.create()
        let vm = try #require(manager.vm)
        vm.agent.stats = [
            "/dev/dri/card0": characterDeviceStat(major: 226, minor: 0, uid: 0, gid: 44, mode: 0o660),
            "/dev/dri/renderD128": characterDeviceStat(major: 226, minor: 128, uid: 0, gid: 104, mode: 0o660),
        ]

        try await container.start()

        let spec = try #require(vm.agent.createdProcessSpec)
        let devices = try #require(spec.linux?.devices)
        let rules = try #require(spec.linux?.resources?.devices)
        #expect(devices.map(\.path) == ["/dev/dri/card0", "/dev/dri/renderD128"])
        #expect(devices.map(\.type) == ["c", "c"])
        #expect(devices.map(\.major) == [226, 226])
        #expect(devices.map(\.minor) == [0, 128])
        #expect(devices.map(\.fileMode) == [0o660, 0o660])
        #expect(devices.map(\.gid) == [44, 104])
        #expect(rules.map(\.major) == [226, 226])
        #expect(rules.map(\.minor) == [0, 128])
        #expect(rules.map(\.access) == ["rwm", "rwm"])
    }

    @Test func guestDeviceDiscoveryDeduplicatesNodesAndMapsTheirGroups() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "guest-device-deduplication-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init(
                process: .init(
                    arguments: ["sleep", "infinity"],
                    user: .init(uid: 1000, gid: 1000, additionalGids: [2000])
                ),
                deviceCgroupRules: [
                    LinuxDeviceCgroup(allow: true, type: "c", major: 226, minor: 128, access: "r")
                ],
                devices: [
                    LinuxDevice(
                        path: "/dev/dri/renderD128",
                        type: "c",
                        major: 226,
                        minor: 128,
                        fileMode: 0o600,
                        uid: 0,
                        gid: 0
                    )
                ],
                guestDevices: [
                    LinuxGuestDeviceRequest(path: "/dev/dri/renderD128"),
                    LinuxGuestDeviceRequest(path: "/dev/dri/renderD128"),
                ]
            )
        )

        try await container.create()
        let vm = try #require(manager.vm)
        vm.agent.stats = [
            "/dev/dri/renderD128": characterDeviceStat(major: 226, minor: 128, uid: 0, gid: 104, mode: 0o660)
        ]

        try await container.start()

        let spec = try #require(vm.agent.createdProcessSpec)
        #expect(spec.linux?.devices.map(\.path) == ["/dev/dri/renderD128"])
        #expect(spec.linux?.devices.first?.gid == 104)
        #expect(spec.linux?.resources?.devices.count == 1)
        #expect(spec.linux?.resources?.devices.first?.access == "rwm")
        #expect(spec.process?.user.additionalGids == [2000, 104])
    }

    @Test func duplicateGuestDeviceRequestsKeepTheRequiredContract() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "guest-device-required-deduplication-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init(
                process: .init(),
                guestDevices: [
                    LinuxGuestDeviceRequest(path: "/dev/dri/renderD128"),
                    LinuxGuestDeviceRequest(path: "/dev/dri/renderD128", required: false),
                ]
            )
        )

        try await container.create()

        do {
            try await container.start()
            Issue.record("expected missing required guest device error")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("required guest device not found: /dev/dri/renderD128"))
        }
    }

    @Test func optionalGuestDeviceNodeCanBeMissing() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "guest-device-optional-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init(
                process: .init(),
                guestDevices: [
                    LinuxGuestDeviceRequest(path: "/dev/dri/card0"),
                    LinuxGuestDeviceRequest(path: "/dev/dri/renderD128", required: false),
                ]
            )
        )

        try await container.create()
        let vm = try #require(manager.vm)
        vm.agent.stats = [
            "/dev/dri/card0": characterDeviceStat(major: 226, minor: 0)
        ]

        try await container.start()

        let spec = try #require(vm.agent.createdProcessSpec)
        #expect(spec.linux?.devices.map(\.path) == ["/dev/dri/card0"])
        #expect(spec.linux?.resources?.devices.map(\.minor) == [0])
    }

    @Test func requiredGuestDeviceNodeMissingFailsStart() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "guest-device-missing-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init(
                process: .init(),
                guestDevices: [LinuxGuestDeviceRequest(path: "/dev/dri/card0")]
            )
        )

        try await container.create()

        do {
            try await container.start()
            Issue.record("expected notFound error")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("required guest device not found: /dev/dri/card0"))
        }
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

    @Test func processIdentifiersAreReadFromTheAgent() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "processes-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init()
        )

        try await container.create()
        try await container.start()

        let vm = try #require(manager.vm)
        vm.agent.processIdentifiers = [42, 7, 99]

        let identifiers = try await container.processIdentifiers()

        #expect(identifiers == [42, 7, 99])
        #expect(vm.agent.processContainerID == "processes-test")

        try await container.pause()
        vm.agent.processIdentifiers = [42, 99]

        let pausedIdentifiers = try await container.processIdentifiers()

        #expect(pausedIdentifiers == [42, 99])
    }

    @Test func processInfoRowsAreReadFromTheAgent() async throws {
        let manager = RecordingVirtualMachineManager()
        let container = try LinuxContainer(
            "process-info-test",
            rootfs: .block(format: "ext4", source: "/tmp/rootfs.img", destination: "/"),
            vmm: manager,
            configuration: .init()
        )

        try await container.create()
        try await container.start()

        let vm = try #require(manager.vm)
        vm.agent.processInfo = [
            ContainerProcessInfo(
                uid: "root",
                pid: 42,
                ppid: 7,
                cpu: 0,
                startTime: "15:33",
                tty: "?",
                time: "00:00:00",
                command: "sleep 60"
            )
        ]

        let processes = try await container.processes()

        #expect(processes == vm.agent.processInfo)
        #expect(vm.agent.processInfoContainerID == "process-info-test")

        try await container.pause()
        vm.agent.processInfo = [
            ContainerProcessInfo(
                uid: "root",
                pid: 99,
                ppid: 42,
                cpu: 1,
                startTime: "15:34",
                tty: "?",
                time: "00:00:01",
                command: "sh"
            )
        ]

        let pausedProcesses = try await container.processes()

        #expect(pausedProcesses == vm.agent.processInfo)
    }

    @Test func ownedFileMountUsesGuestPrivateMaterialization() async throws {
        let directory = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("config.txt")
        let contents = Data("private configuration".utf8)
        try contents.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: source.path)

        var context = try FileMountContext.prepare(mounts: [
            .share(
                source: source.path,
                destination: "/etc/config.txt",
                options: ["ro"],
                fileOwnership: .init(uid: 1000, gid: 1001)
            )
        ])
        #expect(context.transformedMounts.isEmpty)

        let agent = RecordingVirtualMachineAgent()
        try await context.materializeOwnedFiles(containerID: "owned-file-test", agent: agent)

        #expect(
            agent.writeRequests == [
                .init(
                    path: "/run/container/owned-file-test/file-mounts/0",
                    data: contents,
                    mode: 0o440,
                    ownerUID: 1000,
                    ownerGID: 1001
                )
            ])
        let mounts = context.ociBindMounts()
        #expect(mounts.count == 1)
        let mount = try #require(mounts.first)
        #expect(mount.type == "none")
        #expect(mount.source == "/run/container/owned-file-test/file-mounts/0")
        #expect(mount.destination == "/etc/config.txt")
        #expect(mount.options == ["bind", "ro"])
    }

    @Test func emptyFileOwnershipKeepsTheUsualFileMountBehavior() throws {
        let directory = FileManager.default.uniqueTemporaryDirectory(create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("config.txt")
        try Data("configuration".utf8).write(to: source)

        let context = try FileMountContext.prepare(mounts: [
            .share(
                source: source.path,
                destination: "/etc/config.txt",
                fileOwnership: .init()
            )
        ])

        #expect(context.transformedMounts.count == 1)
        #expect(context.preparedMounts.count == 1)
        #expect(context.preparedMounts[0].ownership == nil)
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

private func characterDeviceStat(
    major: UInt64,
    minor: UInt64,
    uid: UInt32 = 0,
    gid: UInt32 = 0,
    mode: UInt32 = 0o666
) -> Stat {
    Stat(
        dev: 0,
        ino: 1,
        mode: UInt32(S_IFCHR) | mode,
        nlink: 1,
        uid: uid,
        gid: gid,
        rdev: linuxDeviceID(major: major, minor: minor),
        size: 0,
        blksize: 4096,
        blocks: 0,
        atime: TimeSpec(seconds: 0, nanoseconds: 0),
        mtime: TimeSpec(seconds: 0, nanoseconds: 0),
        ctime: TimeSpec(seconds: 0, nanoseconds: 0)
    )
}

private func linuxDeviceID(major: UInt64, minor: UInt64) -> UInt64 {
    ((major & 0xfff) << 8)
        | (minor & 0xff)
        | ((minor & ~UInt64(0xff)) << 12)
        | ((major & ~UInt64(0xfff)) << 32)
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
    let agent = RecordingVirtualMachineAgent()

    let configuration: VMConfiguration
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
        self.configuration = configuration
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
    struct WriteRequest: Equatable {
        var path: String
        var data: Data
        var mode: UInt32
        var ownerUID: UInt32?
        var ownerGID: UInt32?
    }

    private struct State {
        var processIdentifiers: [Int32] = []
        var processContainerID: String?
        var processInfo: [ContainerProcessInfo] = []
        var processInfoContainerID: String?
        var stats: [String: Stat] = [:]
        var createdProcessSpec: Spec?
        var writeRequests: [WriteRequest] = []
    }

    private let storage = Mutex<State>(State())

    var processIdentifiers: [Int32] {
        get {
            storage.withLock { $0.processIdentifiers }
        }
        set {
            storage.withLock { $0.processIdentifiers = newValue }
        }
    }

    var processInfo: [ContainerProcessInfo] {
        get {
            storage.withLock { $0.processInfo }
        }
        set {
            storage.withLock { $0.processInfo = newValue }
        }
    }

    var processContainerID: String? {
        storage.withLock { $0.processContainerID }
    }

    var processInfoContainerID: String? {
        storage.withLock { $0.processInfoContainerID }
    }

    var stats: [String: Stat] {
        get {
            storage.withLock { $0.stats }
        }
        set {
            storage.withLock { $0.stats = newValue }
        }
    }

    var createdProcessSpec: Spec? {
        storage.withLock { $0.createdProcessSpec }
    }

    var writeRequests: [WriteRequest] {
        storage.withLock { $0.writeRequests }
    }

    func standardSetup() async throws {}

    func close() async throws {}

    func filesystemOperation(operation: FilesystemOperation, path: String) async throws {}

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

    func writeFile(
        path: String,
        data: Data,
        flags: WriteFileFlags,
        mode: UInt32,
        ownerUID: UInt32?,
        ownerGID: UInt32?
    ) async throws {
        storage.withLock {
            $0.writeRequests.append(
                .init(path: path, data: data, mode: mode, ownerUID: ownerUID, ownerGID: ownerGID)
            )
        }
    }

    func stat(path: URL) async throws -> Stat {
        guard let stat = storage.withLock({ $0.stats[path.path] }) else {
            throw ContainerizationError(.notFound, message: "stat: path not found '\(path.path)'")
        }
        return stat
    }

    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        ociRuntimePath: String?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws {
        storage.withLock { $0.createdProcessSpec = configuration }
    }

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

    func containerProcesses(containerID: String) async throws -> [Int32] {
        storage.withLock {
            $0.processContainerID = containerID
            return $0.processIdentifiers
        }
    }

    func containerProcessInfo(containerID: String) async throws -> [ContainerProcessInfo] {
        storage.withLock {
            $0.processInfoContainerID = containerID
            return $0.processInfo
        }
    }
}
