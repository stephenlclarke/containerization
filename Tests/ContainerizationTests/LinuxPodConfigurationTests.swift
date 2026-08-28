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

import ContainerizationError
import ContainerizationExtras
import Foundation
import Synchronization
import Testing

@testable import Containerization

struct LinuxPodConfigurationTests {
    @Test func rootFilesystemStartPolicyIsExclusiveUnlessExplicitlyPrivate() {
        var configuration = LinuxPod.ContainerConfiguration()
        #expect(configuration.rootFilesystemSharing == .potentiallyShared)

        configuration.rootFilesystemSharing = .privateToWorkload
        #expect(configuration.rootFilesystemSharing == .privateToWorkload)
    }

    @Test func namespaceDonorsArePinnedOnlyForExplicitContainerSelections() {
        var configuration = LinuxPod.ContainerConfiguration()
        configuration.pidNamespace = .container("pid-donor")
        configuration.ipcNamespace = .container("ipc-donor")
        configuration.networkNamespace = .container("network-donor")
        configuration.utsNamespace = .container("uts-donor")
        configuration.userNamespace = .container("user-donor")
        configuration.cgroupNamespace = .container("__pause")

        #expect(
            LinuxPod.namespaceDonorIDs(configuration: configuration) == [
                "ipc-donor",
                "network-donor",
                "pid-donor",
                "user-donor",
                "uts-donor",
            ]
        )
    }

    @Test func startingWorkloadStateRoundTripsDistinctly() throws {
        let encoded = try JSONEncoder().encode(LinuxSandboxWorkloadState.starting)
        let decoded = try JSONDecoder().decode(
            LinuxSandboxWorkloadState.self,
            from: encoded
        )

        #expect(decoded == .starting)
    }

    @Test func hotplugResourcesRequireGuestUnmountsAndProcessDeletion() {
        #expect(
            !LinuxPod.hotplugResourcesAreSafeToRelease(
                guestUnmountsConfirmed: false,
                processDeletionConfirmed: true
            )
        )
        #expect(
            !LinuxPod.hotplugResourcesAreSafeToRelease(
                guestUnmountsConfirmed: true,
                processDeletionConfirmed: false
            )
        )
        #expect(
            LinuxPod.hotplugResourcesAreSafeToRelease(
                guestUnmountsConfirmed: true,
                processDeletionConfirmed: true
            )
        )
    }

    @Test func failedGuestUnmountRetainsRuntimeShareAllocation() async {
        enum UnmountFailure: Error {
            case unavailable
        }

        let cleanup = await LinuxPod.unmountHotpluggedGuestPaths(
            rootfsPath: "/run/container/workload/rootfs",
            runtimeTags: ["runtime-virtiofs-00", "runtime-virtiofs-01"]
        ) { path in
            if path == "/run/runtime-virtiofs-00" {
                throw UnmountFailure.unavailable
            }
        }

        #expect(!cleanup.safeToRelease)
        #expect(cleanup.runtimeTagsUnmounted == ["runtime-virtiofs-01"])
    }

    @Test func guestPathRecognizesOnlyExactRootAndDescendants() {
        #expect(LinuxPod.isGuestPath("/run/runtime-virtiofs", below: "/run/runtime-virtiofs"))
        #expect(LinuxPod.isGuestPath("/run/runtime-virtiofs/share/data", below: "/run/runtime-virtiofs"))
        #expect(!LinuxPod.isGuestPath("/run/runtime-virtiofs-old/data", below: "/run/runtime-virtiofs"))
        #expect(!LinuxPod.isGuestPath("/tmp/runtime-virtiofs", below: "/run/runtime-virtiofs"))
    }

    @Test func guestPathReadinessReturnsAfterImmediateVisibility() async throws {
        let attempts = Mutex(0)

        try await LinuxPod.waitForGuestPath(
            URL(fileURLWithPath: "/run/virtiofs/rootfs/snapshot"),
            maximumAttempts: 3,
            retryInterval: .zero
        ) { _ in
            attempts.withLock { $0 += 1 }
        }

        #expect(attempts.withLock { $0 } == 1)
    }

    @Test func guestPathReadinessRetriesDelayedVisibility() async throws {
        let attempts = Mutex(0)

        try await LinuxPod.waitForGuestPath(
            URL(fileURLWithPath: "/run/virtiofs/rootfs/snapshot"),
            maximumAttempts: 3,
            retryInterval: .zero
        ) { _ in
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            if attempt < 3 {
                throw ContainerizationError(.notFound, message: "guest path is not visible")
            }
        }

        #expect(attempts.withLock { $0 } == 3)
    }

    @Test func guestPathReadinessFailsAfterBoundedAttempts() async {
        let attempts = Mutex(0)

        await #expect(throws: ContainerizationError.self) {
            try await LinuxPod.waitForGuestPath(
                URL(fileURLWithPath: "/run/virtiofs/rootfs/snapshot"),
                maximumAttempts: 3,
                retryInterval: .zero
            ) { _ in
                attempts.withLock { $0 += 1 }
                throw ContainerizationError(.notFound, message: "guest path is not visible")
            }
        }

        #expect(attempts.withLock { $0 } == 3)
    }

    @Test func guestPathReadinessDoesNotRetryOtherFailures() async {
        let attempts = Mutex(0)

        await #expect(throws: GuestPathReadinessTestError.self) {
            try await LinuxPod.waitForGuestPath(
                URL(fileURLWithPath: "/run/virtiofs/rootfs/snapshot"),
                maximumAttempts: 3,
                retryInterval: .zero
            ) { _ in
                attempts.withLock { $0 += 1 }
                throw GuestPathReadinessTestError.unavailable
            }
        }

        #expect(attempts.withLock { $0 } == 1)
    }

    @Test func snapshotDeterministicallyObservesRegisteredWorkloads() async throws {
        let pod = try LinuxPod("sandbox-1", vmm: SnapshotVirtualMachineManager()) { _ in }

        #expect(
            await pod.snapshot()
                == LinuxSandboxSnapshot(
                    sandboxID: "sandbox-1",
                    state: .absent,
                    workloads: []
                )
        )

        for id in ["zeta", "alpha"] {
            try await pod.addContainer(
                id,
                rootfs: .block(format: "ext4", source: "/tmp/\(id).img", destination: "/")
            ) { _ in }
        }

        let snapshot = await pod.snapshot()
        #expect(snapshot.state == .absent)
        #expect(snapshot.workloads.map(\.id) == ["alpha", "zeta"])
        #expect(snapshot.workloads.map(\.state) == [.registered, .registered])
        #expect(snapshot.workloads.allSatisfy { $0.initProcessID == nil })
        #expect(try JSONDecoder().decode(LinuxSandboxSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)

        try await pod.removeContainer("alpha")
        #expect(await pod.snapshot().workloads.map(\.id) == ["zeta"])
    }

    @Test func namespaceSharingDefaultsToPrivateNamespaces() {
        let configuration = LinuxPod.Configuration()

        #expect(configuration.sharedNamespaces.isEmpty)
    }

    @Test func workloadBridgeRequiresExactlyOneUnnamedUplink() throws {
        let interface = NATInterface(
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1")
        )

        var valid = LinuxPod.Configuration()
        valid.interfaces = [interface]
        valid.workloadNetworkBridge = WorkloadNetworkBridge(name: "cz-shared0")

        #expect(throws: Never.self) {
            try LinuxPod.validateWorkloadNetworkBridge(valid)
        }

        var missingUplink = LinuxPod.Configuration()
        missingUplink.workloadNetworkBridge = WorkloadNetworkBridge(name: "cz-shared0")
        #expect(throws: ContainerizationError.self) {
            try LinuxPod.validateWorkloadNetworkBridge(missingUplink)
        }

        var multipleUplinks = LinuxPod.Configuration()
        multipleUplinks.interfaces = [interface, interface]
        multipleUplinks.workloadNetworkBridge = WorkloadNetworkBridge(name: "cz-shared0")
        #expect(throws: ContainerizationError.self) {
            try LinuxPod.validateWorkloadNetworkBridge(multipleUplinks)
        }

        let namedInterface = NATInterface(guestInterfaceName: "uplink0")
        var namedUplink = LinuxPod.Configuration()
        namedUplink.interfaces = [namedInterface]
        namedUplink.workloadNetworkBridge = WorkloadNetworkBridge(name: "cz-shared0")
        #expect(throws: ContainerizationError.self) {
            try LinuxPod.validateWorkloadNetworkBridge(namedUplink)
        }
    }

    @Test func namespaceSharingSelectsProcessAndIPCIndependently() {
        var configuration = LinuxPod.Configuration()
        configuration.sharedNamespaces = [.process, .interprocessCommunication]

        #expect(configuration.sharedNamespaces.contains(.process))
        #expect(configuration.sharedNamespaces.contains(.interprocessCommunication))
    }

    @Test func legacyProcessNamespacePropertyBridgesTypedPolicy() {
        var configuration = LinuxPod.Configuration()
        configuration.sharedNamespaces = [.interprocessCommunication]
        configuration.shareProcessNamespace = true

        #expect(configuration.sharedNamespaces == [.process, .interprocessCommunication])
        #expect(configuration.shareProcessNamespace)

        configuration.shareProcessNamespace = false

        #expect(configuration.sharedNamespaces == [.interprocessCommunication])
        #expect(!configuration.shareProcessNamespace)
    }

    @Test func namespacePoliciesRenderPrivateAndSharedWorkloadNamespaces() {
        let privateNamespaces = LinuxPod.containerNamespaces(sharedNamespaces: [], pausePID: nil)
        #expect(privateNamespaces.map(\.type.rawValue) == ["cgroup", "mount", "uts", "ipc", "pid"])
        #expect(privateNamespaces.map(\.path) == ["", "", "", "", ""])

        let processNamespaces = LinuxPod.containerNamespaces(sharedNamespaces: [.process], pausePID: 42)
        #expect(processNamespaces.map(\.path) == ["", "", "", "", "/proc/42/ns/pid"])

        let ipcNamespaces = LinuxPod.containerNamespaces(sharedNamespaces: [.interprocessCommunication], pausePID: 42)
        #expect(ipcNamespaces.map(\.path) == ["", "", "", "/proc/42/ns/ipc", ""])

        let sharedNamespaces = LinuxPod.containerNamespaces(
            sharedNamespaces: [.process, .interprocessCommunication],
            pausePID: 42
        )
        #expect(sharedNamespaces.map(\.path) == ["", "", "", "/proc/42/ns/ipc", "/proc/42/ns/pid"])
    }

    @Test func workloadNamespacesSupportPrivateHostAndDonorSelections() throws {
        var configuration = LinuxPod.ContainerConfiguration()
        configuration.cgroupNamespace = .host
        configuration.ipcNamespace = .container("database")
        configuration.networkNamespace = .container("database")
        configuration.pidNamespace = .container("database")
        configuration.utsNamespace = .privateNamespace
        configuration.userNamespace = .privateNamespace

        let namespaces = try LinuxPod.containerNamespaces(
            containerID: "worker",
            configuration: configuration,
            sharedNamespaces: [],
            pausePID: nil,
            donorPIDs: ["database": 73]
        )

        #expect(namespaces.map(\.type.rawValue) == ["mount", "ipc", "network", "pid", "uts", "user"])
        #expect(
            namespaces.map(\.path) == [
                "", "/proc/73/ns/ipc", "/proc/73/ns/net", "/proc/73/ns/pid", "", "",
            ]
        )
    }

    @Test func workloadNamespaceRejectsMissingAndSelfDonors() {
        var configuration = LinuxPod.ContainerConfiguration()
        configuration.pidNamespace = .container("missing")

        #expect(throws: ContainerizationError.self) {
            try LinuxPod.containerNamespaces(
                containerID: "worker",
                configuration: configuration,
                sharedNamespaces: [],
                pausePID: nil,
                donorPIDs: [:]
            )
        }

        configuration.pidNamespace = .container("worker")
        #expect(throws: ContainerizationError.self) {
            try LinuxPod.containerNamespaces(
                containerID: "worker",
                configuration: configuration,
                sharedNamespaces: [],
                pausePID: nil,
                donorPIDs: ["worker": 73]
            )
        }
    }
}

private enum GuestPathReadinessTestError: Error {
    case unavailable
}

private struct SnapshotVirtualMachineManager: VirtualMachineManager {
    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        fatalError("snapshot test must not create a virtual machine")
    }
}
