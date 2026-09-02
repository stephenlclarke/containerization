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
import Foundation
import Logging
import Synchronization

import struct ContainerizationOS.Terminal

/// `LinuxPod` allows managing multiple Linux containers within a single
/// virtual machine. Each container has its own rootfs and process, but
/// shares the VM's capacity and guest-agent connection. Workload resources
/// and Linux namespaces remain independently configurable.
public final class LinuxPod: Sendable {
    static let maxIDLength = 64

    /// The identifier of the pod.
    public let id: String

    /// Configuration for the pod.
    public let config: Configuration

    /// The configuration for the LinuxPod.
    public struct Configuration: Sendable {
        /// The amount of cpus for the pod's VM.
        public var cpus: Int = 4
        /// The memory in bytes to give to the pod's VM.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// The network interfaces for the pod.
        public var interfaces: [any Interface] = []
        /// Optional guest bridge for private workload network endpoints.
        ///
        /// The first and only virtual interface becomes the bridge uplink.
        /// Its addresses and routes are configured on the bridge rather than
        /// directly on the virtual interface.
        public var workloadNetworkBridge: WorkloadNetworkBridge?
        /// Whether nested virtualization should be turned on for the pod.
        public var virtualization: Bool = false
        /// Optional file path to store serial boot logs.
        public var bootLog: BootLog?
        /// Linux namespaces that every workload in the pod joins.
        ///
        /// The selected namespaces are owned by an internal pause workload so
        /// they remain available while individual workloads stop and start.
        /// This is limited to the experimental pod API; it does not change the
        /// VM-wide network configuration.
        public struct NamespaceSharing: OptionSet, Sendable, Hashable {
            public let rawValue: UInt8

            public init(rawValue: UInt8) {
                self.rawValue = rawValue
            }

            /// Share the Linux PID namespace between pod workloads.
            ///
            /// Workloads can observe and signal one another's processes.
            public static let process = Self(rawValue: 1 << 0)

            /// Share the Linux IPC namespace between pod workloads.
            ///
            /// This includes System V IPC objects and POSIX message queues.
            public static let interprocessCommunication = Self(rawValue: 1 << 1)
        }

        /// Linux namespaces shared by every workload in the pod.
        ///
        /// The default keeps each workload's PID and IPC namespaces private.
        public var sharedNamespaces: NamespaceSharing = []

        /// Compatibility accessor for sharing the PID namespace.
        ///
        /// Prefer ``sharedNamespaces`` with ``NamespaceSharing/process`` for
        /// new code.
        public var shareProcessNamespace: Bool {
            get { self.sharedNamespaces.contains(.process) }
            set {
                if newValue {
                    self.sharedNamespaces.insert(.process)
                } else {
                    self.sharedNamespaces.remove(.process)
                }
            }
        }
        /// The default hostname for all containers in the pod.
        /// Individual containers can override this by setting their own `hostname` configuration.
        public var hostname: String?
        /// The default DNS configuration for all containers in the pod.
        /// Individual containers can override this by setting their own `dns` configuration.
        public var dns: DNS?
        /// The default hosts file configuration for all containers in the pod.
        /// Individual containers can override this by setting their own `hosts` configuration.
        public var hosts: Hosts?
        /// Volumes attached to the pod. Can be shared with multiple containers.
        public var volumes: [PodVolume] = []
        /// Extension objects that participate in the VM instance lifecycle.
        public var extensions: [any Sendable] = []

        public init() {}
    }

    /// Configuration for a container within the pod.
    public struct ContainerConfiguration: Sendable {
        /// Whether this workload's root filesystem may be mutated by another workload.
        public enum RootFilesystemSharing: Equatable, Sendable {
            /// The root filesystem may be shared or its ownership is unknown.
            case potentiallyShared
            /// The root filesystem is private to this workload.
            case privateToWorkload
        }

        /// Selects the Linux namespace a workload joins.
        public enum NamespaceSelection: Equatable, Sendable {
            /// Create a private namespace for the workload.
            case privateNamespace
            /// Join the sandbox VM's initial namespace.
            case host
            /// Join the active init process namespace of another workload.
            case container(String)
        }

        /// Configuration for the init process of the container.
        public var process = LinuxProcessConfiguration()
        /// Optional per-container CPU limit (can exceed pod total for oversubscription).
        public var cpus: Int?
        /// Optional per-container memory limit in bytes (can exceed pod total for oversubscription).
        public var memoryInBytes: UInt64?
        /// Optional protected memory reservation for the workload cgroup.
        public var memoryReservationInBytes: Int64?
        /// Optional combined memory and swap limit for the workload cgroup.
        public var memorySwapLimitInBytes: Int64?
        /// Optional relative CPU scheduling weight for the workload cgroup.
        public var cpuShares: UInt64?
        /// Optional Linux CPU-set expression for the workload cgroup.
        public var cpuSet: String?
        /// Optional CFS quota in microseconds for the workload cgroup.
        public var cpuQuotaInMicroseconds: Int64?
        /// Optional CFS period in microseconds for the workload cgroup.
        public var cpuPeriodInMicroseconds: UInt64?
        /// Optional process count limit for the workload cgroup.
        public var pidsLimit: Int64?
        /// Optional block I/O resource limits for the workload cgroup.
        public var blockIO: LinuxBlockIO?
        /// Optional device cgroup rules for the workload.
        public var deviceCgroupRules: [LinuxDeviceCgroup] = []
        /// Optional device nodes to create in the workload specification.
        public var devices: [LinuxDevice] = []
        /// Device nodes to discover from the running sandbox before process start.
        public var guestDevices: [LinuxGuestDeviceRequest] = []
        /// OCI annotations for the workload runtime specification.
        public var annotations: [String: String] = [:]
        /// The hostname for the container.
        public var hostname: String?
        /// The system control options for the container.
        public var sysctl: [String: String] = [:]
        /// The mounts for the container.
        public var mounts: [Mount] = LinuxContainer.defaultMounts()
        /// Paths inside the container that vmexec hides from the workload.
        /// Defaults to the OCI standard set (``LinuxContainer/defaultMaskedPaths()``),
        /// matching the restricted capability baseline. Set to `[]` to opt out,
        /// or append to extend it.
        public var maskedPaths: [String] = LinuxContainer.defaultMaskedPaths()
        /// Paths inside the container that vmexec marks read-only.
        /// Defaults to the OCI standard set (``LinuxContainer/defaultReadonlyPaths()``),
        /// matching the restricted capability baseline. Set to `[]` to opt out,
        /// or append to extend it.
        public var readonlyPaths: [String] = LinuxContainer.defaultReadonlyPaths()
        /// The Unix domain socket relays to setup for the container.
        public var sockets: [UnixSocketConfiguration] = []
        /// The DNS configuration for the container.
        public var dns: DNS?
        /// The hosts file configuration for the container.
        public var hosts: Hosts?
        /// Run the container with a minimal init process that handles signal
        /// forwarding and zombie reaping.
        public var useInit: Bool = false
        /// Optional relative parent for the workload cgroup inside the sandbox.
        public var cgroupParent: String?
        /// PID namespace selection. `nil` retains the pod-wide compatibility policy.
        public var pidNamespace: NamespaceSelection?
        /// IPC namespace selection. `nil` retains the pod-wide compatibility policy.
        public var ipcNamespace: NamespaceSelection?
        /// Network namespace selection. `nil` retains the legacy sandbox-host network.
        public var networkNamespace: NamespaceSelection?
        /// Resolved veth endpoint plans to realise inside a private network namespace.
        ///
        /// Address allocation and endpoint ownership remain the caller's responsibility.
        /// Endpoints are configured before the workload's initial process can execute.
        public var networkEndpoints: [WorkloadNetworkEndpoint] = []
        /// Cgroup namespace selection. `nil` creates a private namespace.
        public var cgroupNamespace: NamespaceSelection?
        /// UTS namespace selection. `nil` creates a private namespace.
        public var utsNamespace: NamespaceSelection?
        /// User namespace selection. `nil` retains the sandbox-host user namespace.
        public var userNamespace: NamespaceSelection?
        /// OCI runtime path used to start this workload.
        public var ociRuntimePath: String?
        /// Root filesystem ownership used to select a safe process-start policy.
        ///
        /// A private root permits this workload's guest process setup to overlap
        /// setup for other private roots. The default preserves exclusive setup.
        public var rootFilesystemSharing: RootFilesystemSharing = .potentiallyShared

        public init() {}
    }

    /// A volume that is attached at the pod level and can be shared by multiple containers.
    public struct PodVolume: Sendable {
        /// Describes the backing storage for the volume.
        public enum Source: Sendable {
            /// A network block device (NBD) volume.
            case nbd(url: URL, timeout: TimeInterval? = nil, readOnly: Bool = false)
            /// A disk-image file on the host, attached as a virtio-block device.
            case diskImage(path: URL, readOnly: Bool = false)
            /// An in-memory (tmpfs) volume mounted inside the guest.
            case tmpfs(sizeBytes: UInt64? = nil)
        }

        /// The logical name of this volume. Containers reference this name
        /// via `Mount.sharedMount(name:destination:)` in their mounts.
        public var name: String
        /// The backing storage source for this volume.
        public var source: Source
        /// The filesystem format on the volume.
        public var format: String

        public init(name: String, source: Source, format: String) {
            self.name = name
            self.source = source
            self.format = format
        }

        func toMount() -> Mount {
            switch source {
            case .nbd(let url, let timeout, let readOnly):
                var runtimeOptions: [String] = []
                if let timeout {
                    runtimeOptions.append("vzTimeout=\(timeout)")
                }
                return Mount.block(
                    format: self.format,
                    source: url.absoluteString,
                    destination: LinuxPod.guestVolumePath(name),
                    options: readOnly ? ["ro"] : [],
                    runtimeOptions: runtimeOptions
                )
            case .diskImage(let path, let readOnly):
                return Mount.block(
                    format: self.format,
                    source: path.absolutePath(),
                    destination: LinuxPod.guestVolumePath(name),
                    options: readOnly ? ["ro"] : []
                )
            case .tmpfs(let sizeBytes):
                return Mount.any(
                    type: "tmpfs",
                    source: "tmpfs",
                    destination: LinuxPod.guestVolumePath(name),
                    options: sizeBytes.map { ["size=\($0)"] } ?? []
                )
            }
        }
    }

    private struct PodContainer: Sendable {
        let id: String
        let rootfs: Mount
        let config: ContainerConfiguration
        var state: ContainerState
        var process: LinuxProcess?
        var fileMountContext: FileMountContext

        enum ContainerState: Sendable {
            case registered
            case created
            case starting
            case started
            case paused
            case stopped
            case errored

            var snapshotState: LinuxSandboxWorkloadState {
                switch self {
                case .registered:
                    return .registered
                case .created:
                    return .created
                case .starting:
                    return .starting
                case .started:
                    return .running
                case .paused:
                    return .paused
                case .stopped:
                    return .stopped
                case .errored:
                    return .recoveryRequired
                }
            }
        }
    }

    private let state: AsyncMutex<State>
    private let sharedRootFilesystemStartLock = AsyncLock()

    // Ports to be allocated from for stdio and for
    // unix socket relays that are sharing a guest
    // uds to the host. Released ports are reused — see
    // `VsockPortAllocator` for why that matters.
    private let hostVsockPorts: VsockPortAllocator
    // Ports we request the guest to allocate for unix socket relays from
    // the host.
    private let guestVsockPorts: Atomic<UInt32>

    private struct State: Sendable {
        var phase: Phase
        var containers: [String: PodContainer]
        var pauseProcess: LinuxProcess?
        // Whether the unified virtiofs share is mounted at `/run/virtiofs` in the guest
        var unifiedVirtiofsMounted: Bool = false
        // Boot-created runtime virtiofs devices currently mounted in the guest.
        var mountedRuntimeVirtiofsTags: Set<String> = []
    }

    private struct PreparedContainerStart: Sendable {
        let process: LinuxProcess
    }

    private enum Phase: Sendable {
        /// The pod has been created but no live resources are running.
        case initialized
        /// The pod's virtual machine has been setup and the runtime environment has been configured.
        case created(CreatedState)
        /// An error occurred during the lifetime of this class.
        case errored(Swift.Error)

        struct CreatedState: Sendable {
            let vm: any VirtualMachineInstance
            let relayManager: UnixSocketRelayManager
        }

        func createdState(_ operation: String) throws -> CreatedState {
            switch self {
            case .created(let state):
                return state
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to \(operation): pod must be created"
                )
            }
        }

        mutating func validateForCreate() throws {
            switch self {
            case .initialized:
                break
            case .errored(let err):
                throw err
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "pod must be in initialized state to create"
                )
            }
        }

        mutating func setErrored(error: Swift.Error) {
            self = .errored(error)
        }
    }

    private let vmm: VirtualMachineManager
    private let logger: Logger?

    /// Create a new `LinuxPod`. A `VirtualMachineManager` instance must be
    /// provided that will handle launching the virtual machine the containers
    /// will execute inside of.
    public init(
        _ id: String,
        vmm: VirtualMachineManager,
        logger: Logger? = nil,
        configuration: (inout Configuration) throws -> Void
    ) throws {
        guard id.count <= Self.maxIDLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "pod id length \(id.count) exceeds maximum of \(Self.maxIDLength) characters"
            )
        }
        self.id = id
        self.vmm = vmm
        self.hostVsockPorts = VsockPortAllocator(base: 0x1000_0000)
        self.guestVsockPorts = Atomic<UInt32>(0x1000_0000)
        self.logger = logger

        var config = Configuration()
        try configuration(&config)
        try Self.validateWorkloadNetworkBridge(config)

        self.config = config
        self.state = AsyncMutex(State(phase: .initialized, containers: [:], pauseProcess: nil))
    }

    private static func createDefaultRuntimeSpec(
        _ containerID: String,
        podID: String,
        cgroupParent: String?
    ) -> Spec {
        .init(
            process: .init(),
            hostname: containerID,
            root: .init(
                path: Self.guestRootfsPath(containerID),
                readonly: false
            ),
            linux: .init(
                resources: .init(),
                cgroupsPath: Self.cgroupPath(
                    containerID: containerID,
                    podID: podID,
                    parent: cgroupParent
                )
            )
        )
    }

    private static func cgroupPath(
        containerID: String,
        podID: String,
        parent: String?
    ) -> String {
        guard let parent else {
            return "/container/pod/\(podID)/\(containerID)"
        }
        return "/container/pod/\(podID)/\(parent)/\(containerID)"
    }

    private static func validateCgroupParent(_ parent: String?) throws {
        guard let parent else { return }
        let components = parent.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            !parent.isEmpty,
            !parent.hasPrefix("/"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "cgroup parent must be a non-empty relative path without empty, '.' or '..' components"
            )
        }
    }

    package static func validateWorkloadNetwork(_ config: ContainerConfiguration) throws {
        guard config.annotations[WorkloadNetworkPlan.annotationKey] == nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "workload network plan annotation is reserved for the runtime"
            )
        }
        guard !config.networkEndpoints.isEmpty else { return }
        guard config.networkNamespace == .privateNamespace else {
            throw ContainerizationError(
                .invalidArgument,
                message: "workload network endpoints require a private network namespace"
            )
        }
        guard config.ociRuntimePath == nil else {
            throw ContainerizationError(
                .unsupported,
                message: "workload network endpoints require the vmexec runtime"
            )
        }
        try WorkloadNetworkPlan.validate(config.networkEndpoints)
    }

    package static func validateWorkloadNetworkBridge(_ config: Configuration) throws {
        guard let bridge = config.workloadNetworkBridge else { return }
        try bridge.validate()
        guard config.interfaces.count == 1 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "a workload network bridge requires exactly one sandbox uplink interface"
            )
        }
        guard config.interfaces[0].guestInterfaceName == nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "a workload network bridge owns the guest name of the sandbox uplink interface"
            )
        }
    }

    private func generateRuntimeSpec(containerID: String, config: ContainerConfiguration, rootfs: Mount) -> Spec {
        var spec = Self.createDefaultRuntimeSpec(
            containerID,
            podID: self.id,
            cgroupParent: config.cgroupParent
        )

        // Process configuration
        spec.process = config.process.toOCI()

        // Wrap with init process if requested.
        if config.useInit {
            let originalArgs = spec.process?.args ?? []
            spec.process?.args = ["/.cz-init", "--"] + originalArgs
        }

        // General toggles
        // Container-level hostname takes precedence; fall back to pod-level hostname.
        if let hostname = config.hostname ?? self.config.hostname {
            spec.hostname = hostname
        }
        var annotations = config.annotations
        annotations.removeValue(forKey: WorkloadNetworkPlan.annotationKey)
        spec.annotations = annotations.isEmpty ? nil : annotations

        // Linux toggles
        spec.linux?.sysctl = config.sysctl
        spec.linux?.devices = config.devices
        spec.linux?.maskedPaths = config.maskedPaths
        spec.linux?.readonlyPaths = config.readonlyPaths

        // If the rootfs was requested as read-only, set it in the OCI spec.
        // We let the OCI runtime remount as ro, instead of doing it originally.
        spec.root?.readonly = rootfs.options.contains("ro")

        let legacyCPUQuota = config.cpus.flatMap { cpus in
            cpus > 0 ? Int64(cpus * 100_000) : nil
        }
        let cpuQuota =
            config.cpuQuotaInMicroseconds
            ?? (config.cpuPeriodInMicroseconds == nil ? legacyCPUQuota : nil)
        let cpuPeriod =
            config.cpuPeriodInMicroseconds
            ?? (cpuQuota == nil ? nil : 100_000)
        spec.linux?.resources = LinuxResources(
            devices: config.deviceCgroupRules,
            memory: LinuxMemory(
                limit: config.memoryInBytes.flatMap {
                    $0 > 0 ? Int64($0) : nil
                },
                reservation: config.memoryReservationInBytes,
                swap: config.memorySwapLimitInBytes
            ),
            cpu: LinuxCPU(
                shares: config.cpuShares,
                quota: cpuQuota,
                period: cpuPeriod,
                cpus: config.cpuSet ?? ""
            ),
            pids: config.pidsLimit.map(LinuxPids.init(limit:)),
            blockIO: config.blockIO?.toOCI()
        )
        if config.userNamespace == .privateNamespace {
            let mapping = LinuxIDMapping(
                containerID: 0,
                hostID: 0,
                size: UInt32.max
            )
            spec.linux?.uidMappings = [mapping]
            spec.linux?.gidMappings = [mapping]
        }

        return spec
    }

    static func guestRootfsPath(_ containerID: String) -> String {
        "/run/container/\(containerID)/rootfs"
    }

    static func guestSocketStagingPath(_ socketID: String) -> String {
        "/run/sockets/\(socketID).sock"
    }

    private static func guestVolumePath(_ volumeName: String) -> String {
        "/run/volumes/\(volumeName)"
    }

    package static func waitForGuestPath(
        _ path: URL,
        maximumAttempts: Int = 50,
        retryInterval: Duration = .milliseconds(20),
        probe: @Sendable (URL) async throws -> Void
    ) async throws {
        guard maximumAttempts > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "guest path readiness requires at least one attempt"
            )
        }

        var lastError: (any Error)?
        for attempt in 1...maximumAttempts {
            do {
                try await probe(path)
                return
            } catch let error as ContainerizationError where error.code == .notFound {
                lastError = error
                guard attempt < maximumAttempts else { break }
                try await Task.sleep(for: retryInterval)
            } catch {
                throw error
            }
        }
        throw ContainerizationError(
            .timeout,
            message: "guest path did not become visible at \(path.path) after \(maximumAttempts) attempts",
            cause: lastError
        )
    }
}

/// Production spelling for the multi-workload Linux VM abstraction.
///
/// `LinuxPod` remains as a source-compatible name while clients migrate to
/// the sandbox terminology used for independent workload lifecycle and
/// protected service workloads.
public typealias LinuxSandbox = LinuxPod

/// Observable lifecycle state for one production Linux sandbox.
public enum LinuxSandboxRuntimeState: String, Codable, Equatable, Sendable {
    /// No VM or guest resources are active.
    case absent
    /// The VM and guest agent are active.
    case running
    /// The sandbox encountered an error and requires owner reconciliation.
    case recoveryRequired
}

/// Observable lifecycle state for one workload registered with a sandbox.
public enum LinuxSandboxWorkloadState: String, Codable, Equatable, Sendable {
    /// The workload is registered but the sandbox has not been created.
    case registered
    /// The root filesystem and runtime resources are ready for process start.
    case created
    /// The workload's initial process is being created in the guest.
    case starting
    /// The workload's initial process is active.
    case running
    /// The workload's process cgroup is frozen.
    case paused
    /// The workload has no active process or attached runtime resources.
    case stopped
    /// The workload encountered an error and requires owner reconciliation.
    case recoveryRequired
}

/// Public, side-effect-free observation of one sandbox workload.
public struct LinuxSandboxWorkloadSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let state: LinuxSandboxWorkloadState
    public let initProcessID: Int32?

    public init(id: String, state: LinuxSandboxWorkloadState, initProcessID: Int32?) {
        self.id = id
        self.state = state
        self.initProcessID = initProcessID
    }
}

/// Public, side-effect-free observation used for lost-response recovery.
public struct LinuxSandboxSnapshot: Codable, Equatable, Sendable {
    public let sandboxID: String
    public let state: LinuxSandboxRuntimeState
    public let workloads: [LinuxSandboxWorkloadSnapshot]

    public init(
        sandboxID: String,
        state: LinuxSandboxRuntimeState,
        workloads: [LinuxSandboxWorkloadSnapshot]
    ) {
        self.sandboxID = sandboxID
        self.state = state
        self.workloads = workloads
    }
}

extension LinuxPod {
    /// Number of CPU cores allocated to the pod's VM.
    public var cpus: Int {
        config.cpus
    }

    /// Amount of memory in bytes allocated for the pod's VM.
    public var memoryInBytes: UInt64 {
        config.memoryInBytes
    }

    /// Network interfaces of the pod.
    public var interfaces: [any Interface] {
        config.interfaces
    }

    /// Return the current sandbox and workload states without changing them.
    ///
    /// Workloads are sorted by immutable ID so callers can hash, persist, and
    /// compare observations deterministically. The snapshot deliberately
    /// exposes no underlying VM object, guest-agent handle, or raw error.
    public func snapshot() async -> LinuxSandboxSnapshot {
        await self.state.withLock { state in
            let sandboxState: LinuxSandboxRuntimeState
            switch state.phase {
            case .initialized:
                sandboxState = .absent
            case .created:
                sandboxState = .running
            case .errored:
                sandboxState = .recoveryRequired
            }
            let workloads = state.containers.values
                .map { container in
                    LinuxSandboxWorkloadSnapshot(
                        id: container.id,
                        state: container.state.snapshotState,
                        initProcessID: container.process?.pid
                    )
                }
                .sorted { $0.id < $1.id }
            return LinuxSandboxSnapshot(
                sandboxID: self.id,
                state: sandboxState,
                workloads: workloads
            )
        }
    }

    /// Add a container to the pod.
    ///
    /// When called before `create()`, the container is registered for setup during VM creation.
    /// When called after `create()`, the container is hotplugged into the running VM.
    /// If the underlying VMM does not support hotplug, an error is thrown.
    public func addContainer(
        _ id: String,
        rootfs: Mount,
        configuration: @Sendable @escaping (inout ContainerConfiguration) throws -> Void
    ) async throws {
        guard id.count <= Self.maxIDLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container id length \(id.count) exceeds maximum of \(Self.maxIDLength) characters"
            )
        }
        try await self.state.withLock { state in
            guard state.containers[id] == nil else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container with id \(id) already exists in pod"
                )
            }

            var config = ContainerConfiguration()
            try configuration(&config)
            try Self.validateCgroupParent(config.cgroupParent)
            try Self.validateWorkloadNetwork(config)

            let fileMountContext = try FileMountContext.prepare(mounts: config.mounts)

            switch state.phase {
            case .initialized:
                state.containers[id] = PodContainer(
                    id: id,
                    rootfs: rootfs,
                    config: config,
                    state: .registered,
                    process: nil,
                    fileMountContext: fileMountContext
                )

            case .created(let createdState):
                let vm = createdState.vm

                var modifiedRootfs = rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })

                let attachment = try await vm.hotplug(modifiedRootfs, id: id)

                var updatedFileMountContext = fileMountContext
                var hotplugCleanupSafe = true
                do {
                    let virtioFSMounts = fileMountContext.transformedMounts.filter {
                        if case .virtiofs(_) = $0.runtimeOptions { return true }
                        return false
                    }
                    if !virtioFSMounts.isEmpty {
                        try await vm.hotplugVirtioFS(virtioFSMounts, id: id)
                    }

                    let newVirtiofsTags = try virtioFSMounts.map {
                        try hashFilePath(path: $0.source)
                    }
                    // Shared mounts are pod volumes and are registered separately.
                    let nonSharedMounts = fileMountContext.transformedMounts.filter {
                        if case .shared = $0.runtimeOptions { return false }
                        return true
                    }
                    try vm.registerMounts(
                        id: id,
                        rootfs: attachment,
                        additionalMounts: nonSharedMounts
                    )
                    let containerMounts = vm.mounts[id] ?? []
                    let guestSources = containerMounts.map {
                        $0.guestSource ?? $0.source
                    }
                    let stableVirtiofsRoot = "/run/virtiofs"
                    let runtimeVirtiofsTagsUsed = Set(
                        vm.runtimeVirtiofsTags.filter { tag in
                            let root = "/run/\(tag)"
                            return guestSources.contains {
                                Self.isGuestPath($0, below: root)
                            }
                        }
                    )
                    let usesStableVirtiofs =
                        vm.virtiofsLayout == .unified
                        && guestSources.contains {
                            Self.isGuestPath($0, below: stableVirtiofsRoot)
                        }
                    let usesRuntimeVirtiofs =
                        vm.virtiofsLayout == .unified
                        && !runtimeVirtiofsTagsUsed.isEmpty
                    let rootfsUsesVirtiofs =
                        vm.virtiofsLayout == .unified
                        && (Self.isGuestPath(attachment.source, below: stableVirtiofsRoot)
                            || runtimeVirtiofsTagsUsed.contains {
                                Self.isGuestPath(
                                    attachment.source,
                                    below: "/run/\($0)"
                                )
                            })

                    let agent = try await vm.dialAgent()
                    var runtimeVirtiofsMountAttempts: Set<String> = []
                    var rootfsMountAttempted = false
                    do {
                        // Mount newly exposed virtiofs content before the rootfs.
                        // VZ runtime block attachments are ext4 images reached
                        // through the unified share and therefore need this
                        // mount before the guest can create its loop device.
                        if !newVirtiofsTags.isEmpty || usesStableVirtiofs || usesRuntimeVirtiofs {
                            if vm.virtiofsLayout == .perTag {
                                try await agent.mkdir(path: stableVirtiofsRoot, all: true, perms: 0o755)
                                // Tags already mounted in the guest at boot or by a
                                // prior hotplug (i.e. present on another container).
                                let alreadyMounted = Set(
                                    vm.mounts
                                        .filter { $0.key != id }
                                        .values.flatMap { $0 }
                                        .filter { $0.type == "virtiofs" }
                                        .map { $0.source }
                                )
                                var seen: Set<String> = []
                                for tag in newVirtiofsTags
                                where !alreadyMounted.contains(tag) && seen.insert(tag).inserted {
                                    let dest = "/run/virtiofs/\(tag)"
                                    try await agent.mkdir(path: dest, all: true, perms: 0o755)
                                    try await agent.mount(
                                        ContainerizationOCI.Mount(
                                            type: "virtiofs",
                                            source: tag,
                                            destination: dest,
                                            options: []
                                        ))
                                }
                            } else {
                                if usesStableVirtiofs && !state.unifiedVirtiofsMounted {
                                    // The boot-time share is immutable for the VM's
                                    // lifetime, so mount it only once.
                                    try await agent.mkdir(path: stableVirtiofsRoot, all: true, perms: 0o755)
                                    try await agent.mount(
                                        ContainerizationOCI.Mount(
                                            type: "virtiofs",
                                            source: "virtiofs",
                                            destination: stableVirtiofsRoot,
                                            options: []
                                        ))
                                    state.unifiedVirtiofsMounted = true
                                }

                                for runtimeTag in runtimeVirtiofsTagsUsed.sorted()
                                where !state.mountedRuntimeVirtiofsTags.contains(runtimeTag) {
                                    let runtimeRoot = "/run/\(runtimeTag)"
                                    try await agent.mkdir(path: runtimeRoot, all: true, perms: 0o755)
                                    // A lost reply can hide a successful guest
                                    // mount, so cleanup must treat the RPC as
                                    // applied before awaiting it.
                                    runtimeVirtiofsMountAttempts.insert(runtimeTag)
                                    try await agent.mount(
                                        ContainerizationOCI.Mount(
                                            type: "virtiofs",
                                            source: runtimeTag,
                                            destination: runtimeRoot,
                                            options: []
                                        ))
                                    state.mountedRuntimeVirtiofsTags.insert(runtimeTag)
                                }
                            }
                        }

                        var mount = attachment.to
                        mount.destination = Self.guestRootfsPath(id)
                        if rootfsUsesVirtiofs {
                            try await Self.waitForGuestPath(
                                URL(fileURLWithPath: mount.source)
                            ) { path in
                                _ = try await agent.stat(path: path)
                            }
                        }
                        rootfsMountAttempted = true
                        try await agent.mount(mount)

                        if fileMountContext.hasFileMounts {
                            try await updatedFileMountContext.mountHoldingDirectories(
                                vmMounts: containerMounts,
                                agent: agent
                            )
                            try await updatedFileMountContext.materializeOwnedFiles(containerID: id, agent: agent)
                        }

                        if let dns = config.dns ?? self.config.dns {
                            try await agent.configureDNS(
                                config: dns,
                                location: Self.guestRootfsPath(id)
                            )
                        }

                        if let hosts = config.hosts ?? self.config.hosts {
                            try await agent.configureHosts(
                                config: hosts,
                                location: Self.guestRootfsPath(id)
                            )
                        }

                        for socket in config.sockets {
                            try await self.relayUnixSocket(
                                socket: socket,
                                containerID: id,
                                relayManager: createdState.relayManager,
                                agent: agent
                            )
                        }

                        try await agent.close()
                    } catch {
                        let cleanup = await Self.unmountHotpluggedGuestPaths(
                            rootfsPath: rootfsMountAttempted
                                ? Self.guestRootfsPath(id) : nil,
                            runtimeTags: runtimeVirtiofsMountAttempts
                        ) { path in
                            try await agent.umount(path: path, flags: 0)
                        }
                        state.mountedRuntimeVirtiofsTags.subtract(
                            cleanup.runtimeTagsUnmounted
                        )
                        hotplugCleanupSafe = cleanup.safeToRelease
                        try? await agent.close()
                        throw error
                    }

                    state.containers[id] = PodContainer(
                        id: id,
                        rootfs: rootfs,
                        config: config,
                        state: .created,
                        process: nil,
                        fileMountContext: updatedFileMountContext
                    )
                } catch {
                    if hotplugCleanupSafe {
                        try? await vm.releaseHotplug(id: id)
                        try? await vm.releaseVirtioFS(id: id)
                    }
                    throw error
                }

            case .errored(let err):
                throw err
            }
        }
    }

    static func unmountHotpluggedGuestPaths(
        rootfsPath: String?,
        runtimeTags: Set<String>,
        unmount: (String) async throws -> Void
    ) async -> (safeToRelease: Bool, runtimeTagsUnmounted: Set<String>) {
        var safeToRelease = true
        var runtimeTagsUnmounted: Set<String> = []

        if let rootfsPath {
            do {
                try await unmount(rootfsPath)
            } catch {
                safeToRelease = false
            }
        }
        for runtimeTag in runtimeTags.sorted() {
            do {
                try await unmount("/run/\(runtimeTag)")
                runtimeTagsUnmounted.insert(runtimeTag)
            } catch {
                safeToRelease = false
            }
        }
        return (safeToRelease, runtimeTagsUnmounted)
    }

    static func hotplugResourcesAreSafeToRelease(
        guestUnmountsConfirmed: Bool,
        processDeletionConfirmed: Bool
    ) -> Bool {
        guestUnmountsConfirmed && processDeletionConfirmed
    }

    /// Create and start the underlying pod's virtual machine and set up
    /// the runtime environment. All registered containers will have their
    /// rootfs mounted, but no init processes will be running.
    public func create() async throws {
        try await self.state.withLock { state in
            try state.phase.validateForCreate()

            // Build mountsByID for all containers.
            // Strip "ro" from rootfs options - we handle readonly via the OCI spec's
            // root.readonly field and remount in vmexec after setup is complete.
            // Use transformedMounts from fileMountContext (file mounts become directory shares).
            var mountsByID: [String: [Mount]] = [:]
            for (id, container) in state.containers {
                var modifiedRootfs = container.rootfs
                modifiedRootfs.options.removeAll(where: { $0 == "ro" })
                // Filter out shared mounts — those are handled separately as pod volume bind mounts.
                let containerMounts = container.fileMountContext.transformedMounts.filter {
                    if case .shared = $0.runtimeOptions { return false }
                    return true
                }
                mountsByID[id] = [modifiedRootfs] + containerMounts
            }

            // Validate pod volume names are unique.
            var volumeNames = Set<String>()
            for volume in self.config.volumes {
                guard volumeNames.insert(volume.name).inserted else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "duplicate pod volume name \"\(volume.name)\""
                    )
                }
            }

            // Validate that all shared mounts reference valid pod volume names.
            for (id, container) in state.containers {
                for mount in container.config.mounts {
                    if case .shared = mount.runtimeOptions {
                        guard volumeNames.contains(mount.source) else {
                            throw ContainerizationError(
                                .invalidArgument,
                                message: "container \(id) references unknown pod volume \"\(mount.source)\""
                            )
                        }
                    }
                }
            }
            let podVolumeMounts = self.config.volumes.map { $0.toMount() }
            if !podVolumeMounts.isEmpty {
                mountsByID[self.id] = podVolumeMounts
            }

            // Capture into an immutable `let` so the value is safely usable
            // from the concurrent `withAgent` closure below. The container
            // path makes the same decision in LinuxContainer.create — CH
            // only attaches a virtiofs device when shares are configured,
            // so mounting an unbacked /run/virtiofs would fail with EINVAL
            // on the CH backend.
            let hasVirtiofsMount = mountsByID.values.contains { mounts in
                mounts.contains { mount in
                    if case .virtiofs = mount.runtimeOptions { return true }
                    return false
                }
            }

            var vmConfig = VMConfiguration(
                cpus: self.config.cpus,
                memoryInBytes: self.config.memoryInBytes,
                interfaces: self.config.interfaces,
                mountsByID: mountsByID,
                bootLog: self.config.bootLog,
                nestedVirtualization: self.config.virtualization
            )
            vmConfig.extensions = self.config.extensions
            let creationConfig = StandardVMConfig(configuration: vmConfig)
            let vm = try await self.vmm.create(config: creationConfig)
            let relayManager = UnixSocketRelayManager(vm: vm)
            try await vm.start()

            do {
                let containers = state.containers
                let sharedNamespaces = self.config.sharedNamespaces
                let pauseProcessHolder = Mutex<LinuxProcess?>(nil)
                let fileMountContextUpdates = Mutex<[String: FileMountContext]>([:])

                try await vm.withAgent { agent in
                    try await agent.standardSetup()

                    // Mount the unified virtiofs share at /run/virtiofs only
                    // when at least one container has a virtiofs mount. VZ
                    // tolerates the unbacked mount; CH does not.
                    if hasVirtiofsMount {
                        try await agent.mkdir(path: "/run/virtiofs", all: true, perms: 0o755)
                        if vm.virtiofsLayout == .perTag {
                            // CH backend: one virtio-fs device per source-hash
                            // tag, so mount each tag separately at
                            // /run/virtiofs/<tag>. See LinuxContainer for the
                            // VZ vs. CH model split.
                            var seenTags: Set<String> = []
                            for (_, attached) in vm.mounts {
                                for entry in attached where entry.type == "virtiofs" {
                                    guard seenTags.insert(entry.source).inserted else { continue }
                                    let dest = "/run/virtiofs/\(entry.source)"
                                    try await agent.mkdir(path: dest, all: true, perms: 0o755)
                                    try await agent.mount(
                                        ContainerizationOCI.Mount(
                                            type: "virtiofs",
                                            source: entry.source,
                                            destination: dest,
                                            options: []
                                        ))
                                }
                            }
                        } else {
                            try await agent.mount(
                                ContainerizationOCI.Mount(
                                    type: "virtiofs",
                                    source: "virtiofs",
                                    destination: "/run/virtiofs",
                                    options: []
                                ))
                        }
                    }

                    // The pause container owns every shared namespace so it
                    // stays available while individual workloads restart.
                    if !sharedNamespaces.isEmpty {
                        let pauseID = "pause-\(self.id)"
                        let pauseRootfsPath = "/run/container/\(pauseID)/rootfs"

                        // Bind mount /sbin into the pause container rootfs.
                        // This is where the guest agent lives.
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: "",
                                source: "/sbin",
                                destination: "\(pauseRootfsPath)/sbin",
                                options: ["bind"]
                            ))

                        var pauseSpec = Self.createDefaultRuntimeSpec(
                            pauseID,
                            podID: self.id,
                            cgroupParent: nil
                        )
                        pauseSpec.process?.args = ["/sbin/vminitd", "pause"]
                        pauseSpec.hostname = ""
                        pauseSpec.mounts = LinuxContainer.defaultMounts().map {
                            ContainerizationOCI.Mount(
                                type: $0.type,
                                source: $0.source,
                                destination: $0.destination,
                                options: $0.options
                            )
                        }
                        pauseSpec.linux?.namespaces = [
                            LinuxNamespace(type: .cgroup),
                            LinuxNamespace(type: .ipc),
                            LinuxNamespace(type: .mount),
                            LinuxNamespace(type: .pid),
                            LinuxNamespace(type: .uts),
                        ]

                        // Create LinuxProcess for pause container
                        let process = LinuxProcess(
                            pauseID,
                            containerID: pauseID,
                            spec: pauseSpec,
                            io: LinuxProcess.Stdio(stdin: nil, stdout: nil, stderr: nil),
                            portAllocator: self.hostVsockPorts,
                            ociRuntimePath: nil,
                            agent: agent,
                            vm: vm,
                            logger: self.logger
                        )

                        try await process.start()
                        pauseProcessHolder.withLock { $0 = process }

                        self.logger?.debug("Pause container started", metadata: ["pid": "\(process.pid)"])
                    }

                    // Mount all container rootfs
                    for (_, container) in containers {
                        guard let attachments = vm.mounts[container.id], let rootfsAttachment = attachments.first else {
                            throw ContainerizationError(.notFound, message: "rootfs mount not found for container \(container.id)")
                        }
                        var rootfs = rootfsAttachment.to
                        rootfs.destination = Self.guestRootfsPath(container.id)
                        try await agent.mount(rootfs)
                    }

                    // Mount file mount holding directories under /run for each container.
                    for (id, container) in containers {
                        if container.fileMountContext.hasFileMounts {
                            var ctx = container.fileMountContext
                            let containerMounts = vm.mounts[id] ?? []
                            try await ctx.mountHoldingDirectories(
                                vmMounts: containerMounts,
                                agent: agent
                            )
                            try await ctx.materializeOwnedFiles(containerID: id, agent: agent)
                            fileMountContextUpdates.withLock { $0[id] = ctx }
                        }
                    }

                    // Mount pod-level volumes.
                    let podVolumeAttachments = vm.mounts[self.id] ?? []
                    for (index, volume) in self.config.volumes.enumerated() {
                        guard index < podVolumeAttachments.count else {
                            throw ContainerizationError(
                                .notFound,
                                message: "attached filesystem not found for pod volume \"\(volume.name)\""
                            )
                        }
                        let attachment = podVolumeAttachments[index]
                        let guestPath = Self.guestVolumePath(volume.name)
                        try await agent.mount(
                            ContainerizationOCI.Mount(
                                type: volume.format,
                                source: attachment.source,
                                destination: guestPath,
                                options: attachment.options
                            ))
                    }

                    // Start up unix socket relays for each container
                    for (_, container) in containers {
                        for socket in container.config.sockets {
                            try await self.relayUnixSocket(
                                socket: socket,
                                containerID: container.id,
                                relayManager: relayManager,
                                agent: agent
                            )
                        }
                    }

                    // For every interface asked for:
                    // 1. Add the address requested
                    // 2. Online the adapter
                    // 3. For the first interface, add the default route
                    if let bridge = self.config.workloadNetworkBridge {
                        try await agent.configureWorkloadNetworkBridge(
                            name: bridge.name,
                            uplinkInterface: "eth0"
                        )
                        try await agent.setupInterface(
                            self.interfaces[0],
                            name: bridge.name,
                            initialName: bridge.name,
                            setDefaultRoute: true,
                            logger: self.logger
                        )
                    } else {
                        var defaultRouteSet = false
                        let interfaceNames = try resolveGuestInterfaceNames(self.interfaces)
                        for (index, i) in self.interfaces.enumerated() {
                            let name = interfaceNames[index]
                            try await agent.setupInterface(
                                i,
                                name: name,
                                initialName: "eth\(index)",
                                setDefaultRoute: !defaultRouteSet,
                                logger: self.logger
                            )
                            defaultRouteSet = true
                        }
                    }

                    // Setup /etc/resolv.conf and /etc/hosts for each container.
                    // Container-level config takes precedence over pod-level config.
                    for (_, container) in containers {
                        if let dns = container.config.dns ?? self.config.dns {
                            try await agent.configureDNS(
                                config: dns,
                                location: Self.guestRootfsPath(container.id)
                            )
                        }
                        if let hosts = container.config.hosts ?? self.config.hosts {
                            try await agent.configureHosts(
                                config: hosts,
                                location: Self.guestRootfsPath(container.id)
                            )
                        }
                    }
                }

                state.pauseProcess = pauseProcessHolder.withLock { $0 }
                state.unifiedVirtiofsMounted = hasVirtiofsMount && vm.virtiofsLayout == .unified

                // Apply file mount context updates.
                let updates = fileMountContextUpdates.withLock { $0 }
                for (id, ctx) in updates {
                    state.containers[id]?.fileMountContext = ctx
                }

                // Transition all containers to created state
                for id in state.containers.keys {
                    state.containers[id]?.state = .created
                }

                state.phase = .created(.init(vm: vm, relayManager: relayManager))
            } catch {
                try? await relayManager.stopAll()
                try? await vm.stop()
                state.phase.setErrored(error: error)
                throw error
            }
        }
    }

    /// Start a container's initial process.
    public func startContainer(_ containerID: String) async throws {
        let rootFilesystemSharing = try await self.state.withLock { state in
            _ = try state.phase.createdState("startContainer")
            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }
            return container.config.rootFilesystemSharing
        }

        switch rootFilesystemSharing {
        case .privateToWorkload:
            try await startContainerProcess(containerID)
        case .potentiallyShared:
            try await sharedRootFilesystemStartLock.withLock { _ in
                try await self.startContainerProcess(containerID)
            }
        }
    }

    private func startContainerProcess(_ containerID: String) async throws {
        let prepared = try await self.state.withLock { state -> PreparedContainerStart in
            let createdState = try state.phase.createdState("startContainer")

            guard var container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .created else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be in created state to start"
                )
            }

            let agent = try await createdState.vm.dialAgent()
            do {
                if let networkNamespace = container.config.networkNamespace,
                    networkNamespace != .host
                {
                    try await agent.validateWorkloadNetwork(
                        endpoints: container.config.networkEndpoints
                    )
                }
                var spec = self.generateRuntimeSpec(containerID: containerID, config: container.config, rootfs: container.rootfs)
                try await LinuxContainer.addGuestDevices(
                    container.config.guestDevices,
                    to: &spec,
                    using: agent
                )
                // We don't need the rootfs, nor do OCI runtimes want it included.
                // Also filter out file mount holding directories - we mount those separately under /run.
                // Transform virtiofs mounts to bind mounts from /run/virtiofs/{tag}
                let containerMounts = createdState.vm.mounts[containerID] ?? []
                let holdingTags = container.fileMountContext.holdingDirectoryTags
                var mounts: [ContainerizationOCI.Mount] =
                    containerMounts.dropFirst()
                    .filter { !holdingTags.contains($0.source) }
                    .map { attached -> ContainerizationOCI.Mount in
                        if attached.type == "virtiofs" {
                            // Transform to bind mount from holding directory
                            return ContainerizationOCI.Mount(
                                type: "none",
                                source: attached.guestSource ?? "/run/virtiofs/\(attached.source)",
                                destination: attached.destination,
                                options: ["bind"] + attached.options
                            )
                        }
                        return attached.to
                    }
                    + container.fileMountContext.ociBindMounts()

                // When useInit is enabled, bind mount vminitd from the VM's filesystem
                // into the container so it can be executed.
                if container.config.useInit {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: "/sbin/vminitd",
                            destination: "/.cz-init",
                            options: ["bind", "ro"]
                        ))
                }

                // Bind mount staged sockets into the container. Sockets relayed
                // .into the container are created in a staging directory outside
                // the rootfs to avoid symlink traversal and mount shadowing.
                for socket in container.config.sockets where socket.direction == .into {
                    mounts.append(
                        ContainerizationOCI.Mount(
                            type: "bind",
                            source: Self.guestSocketStagingPath(socket.id),
                            destination: socket.destination.path,
                            options: ["bind"]
                        ))
                }

                // Bind mount pod volumes into the container.
                for mount in container.config.mounts {
                    if case .shared = mount.runtimeOptions {
                        mounts.append(
                            ContainerizationOCI.Mount(
                                type: "none",
                                source: Self.guestVolumePath(mount.source),
                                destination: mount.destination,
                                options: ["bind"] + mount.options
                            ))
                    }
                }

                spec.mounts = cleanAndSortMounts(mounts)

                let pausePID = state.pauseProcess?.pid
                let donorPIDs = state.containers.reduce(
                    into: [String: Int32]()
                ) { result, entry in
                    if let pid = entry.value.process?.pid {
                        result[entry.key] = pid
                    }
                }
                let namespaces = try Self.containerNamespaces(
                    containerID: containerID,
                    configuration: container.config,
                    sharedNamespaces: self.config.sharedNamespaces,
                    pausePID: pausePID,
                    donorPIDs: donorPIDs
                )
                if let pausePID {
                    for namespace in namespaces where !namespace.path.isEmpty {
                        let description: String
                        switch namespace.type {
                        case .ipc:
                            description = "IPC"
                        case .pid:
                            description = "PID"
                        default:
                            continue
                        }

                        self.logger?.debug(
                            "Container joining pause \(description) namespace",
                            metadata: [
                                "container": "\(containerID)",
                                "pausePID": "\(pausePID)",
                                "nsPath": "\(namespace.path)",
                            ])
                    }
                }

                spec.linux?.namespaces = namespaces
                if container.config.networkNamespace == .privateNamespace {
                    var annotations = spec.annotations ?? [:]
                    annotations[WorkloadNetworkPlan.annotationKey] = try WorkloadNetworkPlan.encode(
                        container.config.networkEndpoints
                    )
                    spec.annotations = annotations
                }

                let stdio = IOUtil.setup(
                    portAllocator: self.hostVsockPorts,
                    stdin: container.config.process.stdin,
                    stdout: container.config.process.stdout,
                    stderr: container.config.process.stderr
                )

                let process = LinuxProcess(
                    containerID,
                    containerID: containerID,
                    spec: spec,
                    io: stdio,
                    portAllocator: self.hostVsockPorts,
                    ociRuntimePath: container.config.ociRuntimePath,
                    agent: agent,
                    vm: createdState.vm,
                    logger: self.logger
                )
                container.state = .starting
                state.containers[containerID] = container
                return PreparedContainerStart(process: process)
            } catch {
                try? await agent.close()
                throw error
            }
        }

        do {
            try await prepared.process.start()
            try await self.state.withLock { state in
                _ = try state.phase.createdState("startContainer")
                guard var container = state.containers[containerID],
                    container.state == .starting
                else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "container \(containerID) no longer has a pending start"
                    )
                }
                container.process = prepared.process
                container.state = .started
                state.containers[containerID] = container
            }
        } catch {
            try? await prepared.process.delete()
            await self.state.withLock { state in
                guard var container = state.containers[containerID],
                    container.state == .starting
                else {
                    return
                }
                container.state = .created
                state.containers[containerID] = container
            }
            throw error
        }
    }

    /// Stop a container from executing.
    public func stopContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("stopContainer")

            guard var container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            // Allow stop to be called multiple times
            if container.state == .stopped {
                return
            }

            if let dependentID = Self.startingNamespaceDependent(
                on: containerID,
                in: state.containers
            ) {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) is a namespace donor for starting container \(dependentID)"
                )
            }

            guard container.state == .created || container.state == .started || container.state == .paused else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be in created, started, or paused state to stop"
                )
            }

            let runtimeTagsToUnmount = createdState.vm
                .runtimeVirtiofsTagsToUnmount(id: containerID)
            var guestUnmountsConfirmed = false
            var processDeletionConfirmed = container.process == nil
            do {
                // Check if the vm is even still running
                if createdState.vm.state == .stopped {
                    container.state = .stopped
                    state.containers[containerID] = container
                    return
                }

                if container.state == .paused {
                    try await createdState.vm.withAgent { agent in
                        try await agent.resumeContainer(containerID: containerID)
                    }
                }

                if let process = container.process {
                    try await process.kill(.kill)
                    try await process.wait(timeoutInSeconds: 3)
                }

                let sockets = container.config.sockets
                try await createdState.vm.withAgent { agent in
                    if !sockets.isEmpty {
                        guard let relayAgent = agent as? SocketRelayAgent else {
                            throw ContainerizationError(
                                .unsupported,
                                message: "VirtualMachineAgent does not support relaySocket surface"
                            )
                        }
                        for socket in sockets {
                            try? await createdState.relayManager.stop(socket: socket)
                            try? await relayAgent.stopSocketRelay(
                                configuration: socket
                            )
                        }
                    }
                    try await agent.umount(
                        path: Self.guestRootfsPath(containerID),
                        flags: 0
                    )
                    for runtimeTag in runtimeTagsToUnmount.sorted() {
                        try await agent.umount(
                            path: "/run/\(runtimeTag)",
                            flags: 0
                        )
                    }
                    try await agent.sync()
                }
                state.mountedRuntimeVirtiofsTags.subtract(runtimeTagsToUnmount)
                guestUnmountsConfirmed = true

                // Clean up the process resources before a host share can be
                // cleared and its VZ device returned to the runtime pool.
                try await container.process?.delete()
                processDeletionConfirmed = true

                // Release the hotplug device and virtiofs shares so they can be reused by new containers
                try await createdState.vm.releaseHotplug(id: containerID)
                try await createdState.vm.releaseVirtioFS(id: containerID)

                container.process = nil
                container.state = .stopped
                state.containers[containerID] = container
            } catch {
                // Never replace a VZ share while its guest mapping may still
                // be mounted. Leave the allocation for VM recovery instead.
                if Self.hotplugResourcesAreSafeToRelease(
                    guestUnmountsConfirmed: guestUnmountsConfirmed,
                    processDeletionConfirmed: processDeletionConfirmed
                ) {
                    try? await createdState.vm.releaseHotplug(id: containerID)
                    try? await createdState.vm.releaseVirtioFS(id: containerID)
                }

                container.state = .errored
                container.process = nil
                state.containers[containerID] = container

                throw error
            }
        }
    }

    /// Remove a stopped workload registration from the sandbox. The caller
    /// must stop the workload first; donor validation therefore cannot retain
    /// a stale namespace owner under the same ID.
    public func removeContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }
            switch container.state {
            case .registered, .stopped:
                state.containers.removeValue(forKey: containerID)
            case .created, .starting, .started, .paused, .errored:
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be stopped before removal"
                )
            }
        }
    }

    /// Stop the pod's VM and all containers.
    public func stop() async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("stop")

            guard !state.containers.values.contains(where: { $0.state == .starting }) else {
                throw ContainerizationError(
                    .invalidState,
                    message: "pod cannot stop while a container start is in progress"
                )
            }

            do {
                try await createdState.relayManager.stopAll()

                // Stop all containers
                let containerIDs = Array(state.containers.keys)

                for containerID in containerIDs {
                    // Stop the container inline
                    guard var container = state.containers[containerID] else {
                        continue
                    }

                    if container.state == .stopped {
                        continue
                    }

                    if let process = container.process,
                        container.state == .started || container.state == .paused
                    {
                        if createdState.vm.state != .stopped {
                            if container.state == .paused {
                                try? await createdState.vm.withAgent { agent in
                                    try await agent.resumeContainer(containerID: containerID)
                                }
                            }
                            try? await process.kill(.kill)
                            _ = try? await process.wait(timeoutInSeconds: 3)

                            try? await createdState.vm.withAgent { agent in
                                try await agent.umount(
                                    path: Self.guestRootfsPath(containerID),
                                    flags: 0
                                )
                            }
                        }

                        try? await process.delete()
                        container.process = nil
                        container.state = .stopped

                        state.containers[containerID] = container
                    }
                }

                // Unmount pod-level volumes.
                if createdState.vm.state != .stopped && !self.config.volumes.isEmpty {
                    try? await createdState.vm.withAgent { agent in
                        for volume in self.config.volumes {
                            try? await agent.umount(
                                path: Self.guestVolumePath(volume.name),
                                flags: 0
                            )
                        }
                    }
                }

                try await createdState.vm.stop()
                state.unifiedVirtiofsMounted = false
                state.mountedRuntimeVirtiofsTags.removeAll()
                state.phase = .initialized
            } catch {
                try? await createdState.vm.stop()
                state.unifiedVirtiofsMounted = false
                state.mountedRuntimeVirtiofsTags.removeAll()
                state.phase.setErrored(error: error)
                throw error
            }
        }
    }

    /// Freeze one workload's processes while leaving the VM and its other workloads running.
    public func pauseContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("pauseContainer")
            guard var container = state.containers[containerID] else {
                throw ContainerizationError(.notFound, message: "container \(containerID) not found in pod")
            }
            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to pause"
                )
            }

            try await createdState.vm.withAgent { agent in
                try await agent.pauseContainer(containerID: containerID)
            }
            container.state = .paused
            state.containers[containerID] = container
        }
    }

    /// Resume one paused workload while leaving the VM and its other workloads unchanged.
    public func resumeContainer(_ containerID: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("resumeContainer")
            guard var container = state.containers[containerID] else {
                throw ContainerizationError(.notFound, message: "container \(containerID) not found in pod")
            }
            guard container.state == .paused else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be paused to resume"
                )
            }

            try await createdState.vm.withAgent { agent in
                try await agent.resumeContainer(containerID: containerID)
            }
            container.state = .started
            state.containers[containerID] = container
        }
    }

    /// Apply live cgroup resource changes to a running or paused workload.
    ///
    /// Only fields present in `resources` are changed. Callers remain
    /// responsible for retaining their desired configuration for inspection
    /// and reconciliation.
    public func updateContainerResources(
        _ containerID: String,
        resources: LinuxResources
    ) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("updateContainerResources")
            guard let container = state.containers[containerID] else {
                throw ContainerizationError(.notFound, message: "container \(containerID) not found in pod")
            }
            guard container.state == .started || container.state == .paused else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started or paused to update resources"
                )
            }

            try await createdState.vm.withAgent { agent in
                try await agent.updateContainerResources(
                    containerID: containerID,
                    resources: resources
                )
            }
        }
    }

    /// Send a signal to a container.
    public func killContainer(_ containerID: String, signal: Signal) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            if let dependentID = Self.startingNamespaceDependent(
                on: containerID,
                in: state.containers
            ) {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) is a namespace donor for starting container \(dependentID)"
                )
            }
            try await process.kill(signal)
        }
    }

    /// Wait for a container to exit. Returns the exit code.
    @discardableResult
    public func waitContainer(_ containerID: String, timeoutInSeconds: Int64? = nil) async throws -> ExitStatus {
        let process = try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            return process
        }
        return try await process.wait(timeoutInSeconds: timeoutInSeconds)
    }

    /// Resize a container's terminal (if one was requested).
    public func resizeContainer(_ containerID: String, to: Terminal.Size) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.resize(to: to)
        }
    }

    /// Execute a new process in a container.
    public func execInContainer(
        _ containerID: String,
        processID: String,
        configuration: @Sendable @escaping (inout LinuxProcessConfiguration) throws -> Void
    ) async throws -> LinuxProcess {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("execInContainer")

            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to exec"
                )
            }

            var spec = self.generateRuntimeSpec(containerID: containerID, config: container.config, rootfs: container.rootfs)
            let donorPIDs = state.containers.reduce(
                into: [String: Int32]()
            ) { result, entry in
                if let pid = entry.value.process?.pid {
                    result[entry.key] = pid
                }
            }
            spec.linux?.namespaces = try Self.containerNamespaces(
                containerID: containerID,
                configuration: container.config,
                sharedNamespaces: self.config.sharedNamespaces,
                pausePID: state.pauseProcess?.pid,
                donorPIDs: donorPIDs
            )
            // Inherit environment variables, working directory, user, capabilities, rlimits from container process.
            // Reset: process arguments, terminal, stdio as these are not supposed to be inherited.
            var config = container.config.process
            config.arguments = []
            config.terminal = false
            config.stdin = nil
            config.stdout = nil
            config.stderr = nil
            try configuration(&config)
            spec.process = config.toOCI()

            let agent = try await createdState.vm.dialAgent()
            let stdio = IOUtil.setup(
                portAllocator: self.hostVsockPorts,
                stdin: config.stdin,
                stdout: config.stdout,
                stderr: config.stderr
            )
            let process = LinuxProcess(
                processID,
                containerID: containerID,
                spec: spec,
                io: stdio,
                portAllocator: self.hostVsockPorts,
                ociRuntimePath: container.config.ociRuntimePath,
                agent: agent,
                vm: createdState.vm,
                logger: self.logger
            )
            return process
        }
    }

    /// List all container IDs in the pod.
    public func listContainers() async -> [String] {
        await self.state.withLock { state in
            Array(state.containers.keys)
        }
    }

    /// Get statistics for containers in the pod.
    public func statistics(containerIDs: [String]? = nil, categories: StatCategory = .all) async throws -> [ContainerStatistics] {
        let (createdState, ids) = try await self.state.withLock { state in
            let createdState = try state.phase.createdState("statistics")
            let ids = containerIDs ?? Array(state.containers.keys)
            return (createdState, ids)
        }

        let stats = try await createdState.vm.withAgent { agent in
            try await agent.containerStatistics(containerIDs: ids, categories: categories)
        }

        return stats
    }

    /// Get process identifiers for one active workload.
    public func processIdentifiers(_ containerID: String) async throws -> [Int32] {
        let createdState = try await self.state.withLock { state in
            guard let container = state.containers[containerID],
                container.state == .started || container.state == .paused
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to list processes"
                )
            }
            return try state.phase.createdState("processIdentifiers")
        }
        return try await createdState.vm.withAgent { agent in
            try await agent.containerProcesses(containerID: containerID)
        }
    }

    /// Get process-table rows for one active workload.
    public func processes(_ containerID: String) async throws -> [ContainerProcessInfo] {
        let createdState = try await self.state.withLock { state in
            guard let container = state.containers[containerID],
                container.state == .started || container.state == .paused
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to list process information"
                )
            }
            return try state.phase.createdState("processes")
        }
        return try await createdState.vm.withAgent { agent in
            try await agent.containerProcessInfo(containerID: containerID)
        }
    }

    /// Dial a vsock port in the pod's VM.
    public func dialVsock(port: UInt32) async throws -> FileHandle {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("dialVsock")
            return try await createdState.vm.dial(port)
        }
    }

    /// Provides scoped access to the underlying virtual machine instance.
    ///
    /// Most users should prefer the higher level APIs on ``LinuxPod``
    /// directly. This is intended for advanced use cases that need to interact
    /// with the virtual machine outside of the pod abstraction.
    public func withVirtualMachineInstance<T: Sendable>(
        _ fn: @Sendable (any VirtualMachineInstance) async throws -> T
    ) async throws -> T {
        let vm = try await self.state.withLock { state in
            try state.phase.createdState("withVirtualMachineInstance").vm
        }
        return try await fn(vm)
    }

    // Perform filesystem operations in a container.
    public func filesystemOperation(_ containerID: String, operation: FilesystemOperation, path: String) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("filesystemOperation")

            guard let container = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            guard container.state == .started else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(containerID) must be started to perform filesystem operations"
                )
            }

            try await createdState.vm.withAgent { agent in
                guard let vminitd = agent as? Vminitd else {
                    throw ContainerizationError(.unsupported, message: "filesystemOperation requires Vminitd agent")
                }
                try await vminitd.filesystemOperation(operation: operation, path: path, containerID: containerID)
            }
        }
    }

    /// Close a container's standard input to signal no more input is arriving.
    public func closeContainerStdin(_ containerID: String) async throws {
        try await self.state.withLock { state in
            guard let container = state.containers[containerID], let process = container.process else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found or not started"
                )
            }
            try await process.closeStdin()
        }
    }

    /// Relay a unix socket for a container.
    public func relayUnixSocket(_ containerID: String, socket: UnixSocketConfiguration) async throws {
        try await self.state.withLock { state in
            let createdState = try state.phase.createdState("relayUnixSocket")

            guard let _ = state.containers[containerID] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(containerID) not found in pod"
                )
            }

            try await createdState.vm.withAgent { agent in
                try await self.relayUnixSocket(
                    socket: socket,
                    containerID: containerID,
                    relayManager: createdState.relayManager,
                    agent: agent
                )
            }
        }
    }

    private func relayUnixSocket(
        socket: UnixSocketConfiguration,
        containerID: String,
        relayManager: UnixSocketRelayManager,
        agent: any VirtualMachineAgent
    ) async throws {
        guard let relayAgent = agent as? SocketRelayAgent else {
            throw ContainerizationError(
                .unsupported,
                message: "VirtualMachineAgent does not support relaySocket surface"
            )
        }

        var socket = socket

        // Adjust paths to be relative to the container's rootfs
        let rootInGuest = URL(filePath: Self.guestRootfsPath(containerID))

        let port: UInt32
        if socket.direction == .into {
            // Held for the lifetime of the relay, so it is deliberately never
            // released — the relay manager outlives this call.
            port = self.hostVsockPorts.allocate()
            socket.destination = URL(filePath: Self.guestSocketStagingPath(socket.id))
        } else {
            port = self.guestVsockPorts.wrappingAdd(1, ordering: .relaxed).oldValue
            socket.source = rootInGuest.appending(path: socket.source.path)
        }

        try await relayManager.start(port: port, socket: socket)
        try await relayAgent.relaySocket(port: port, configuration: socket)
    }
}

extension LinuxPod {
    private static func startingNamespaceDependent(
        on donorID: String,
        in containers: [String: PodContainer]
    ) -> String? {
        containers.values.first(where: {
            $0.state == .starting
                && namespaceDonorIDs(configuration: $0.config).contains(donorID)
        })?.id
    }

    package static func namespaceDonorIDs(
        configuration: ContainerConfiguration
    ) -> Set<String> {
        let selections = [
            configuration.cgroupNamespace,
            configuration.ipcNamespace,
            configuration.networkNamespace,
            configuration.pidNamespace,
            configuration.utsNamespace,
            configuration.userNamespace,
        ]
        return Set(
            selections.compactMap { selection in
                guard case .container(let donorID) = selection,
                    donorID != "__pause"
                else {
                    return nil
                }
                return donorID
            }
        )
    }

    /// Produces the OCI namespace list for an independently configured
    /// workload. Donor selections are resolved only against active init
    /// processes, so a stopped or unknown donor fails before process start.
    package static func containerNamespaces(
        containerID: String,
        configuration: ContainerConfiguration,
        sharedNamespaces: Configuration.NamespaceSharing,
        pausePID: Int32?,
        donorPIDs: [String: Int32]
    ) throws -> [LinuxNamespace] {
        var namespaces = [LinuxNamespace(type: .mount)]

        let compatibilityPID: ContainerConfiguration.NamespaceSelection =
            sharedNamespaces.contains(.process) ? .container("__pause") : .privateNamespace
        let compatibilityIPC: ContainerConfiguration.NamespaceSelection =
            sharedNamespaces.contains(.interprocessCommunication) ? .container("__pause") : .privateNamespace

        for (type, selection) in [
            (.cgroup, configuration.cgroupNamespace ?? .privateNamespace),
            (.ipc, configuration.ipcNamespace ?? compatibilityIPC),
            (.network, configuration.networkNamespace ?? .host),
            (.pid, configuration.pidNamespace ?? compatibilityPID),
            (.uts, configuration.utsNamespace ?? .privateNamespace),
            (.user, configuration.userNamespace ?? .host),
        ] as [(LinuxNamespaceType, ContainerConfiguration.NamespaceSelection)] {
            switch selection {
            case .privateNamespace:
                namespaces.append(LinuxNamespace(type: type))
            case .host:
                continue
            case .container(let donorID):
                let donorPID: Int32?
                if donorID == "__pause" {
                    donorPID = pausePID
                } else {
                    guard donorID != containerID else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "container \(containerID) cannot join its own \(type.rawValue) namespace"
                        )
                    }
                    donorPID = donorPIDs[donorID]
                }
                guard let donorPID else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "\(type.rawValue) namespace donor \(donorID) is not active"
                    )
                }
                namespaces.append(
                    LinuxNamespace(
                        type: type,
                        path: "/proc/\(donorPID)/ns/\(Self.namespacePathComponent(type))"
                    )
                )
            }
        }

        return namespaces
    }

    static func isGuestPath(_ path: String, below root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func namespacePathComponent(
        _ type: LinuxNamespaceType
    ) -> String {
        type == .network ? "net" : type.rawValue
    }

    /// Produces the OCI namespace list for a workload in this pod.
    ///
    /// The pause workload owns selected namespaces. A missing pause process
    /// leaves the workload private; creation establishes the pause process
    /// before a configured shared namespace can reach this point.
    package static func containerNamespaces(
        sharedNamespaces: Configuration.NamespaceSharing,
        pausePID: Int32?
    ) -> [LinuxNamespace] {
        var namespaces: [LinuxNamespace] = [
            LinuxNamespace(type: .cgroup),
            LinuxNamespace(type: .mount),
            LinuxNamespace(type: .uts),
        ]

        for (type, sharing) in [
            (.ipc, Configuration.NamespaceSharing.interprocessCommunication),
            (.pid, Configuration.NamespaceSharing.process),
        ] as [(LinuxNamespaceType, Configuration.NamespaceSharing)] {
            if sharedNamespaces.contains(sharing), let pausePID {
                namespaces.append(LinuxNamespace(type: type, path: "/proc/\(pausePID)/ns/\(type.rawValue)"))
            } else {
                namespaces.append(LinuxNamespace(type: type))
            }
        }

        return namespaces
    }
}
