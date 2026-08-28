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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Logging
import NIOCore
import NIOPosix
import Synchronization
@preconcurrency import Virtualization

public final class VZVirtualMachineInstance: Sendable {
    public typealias Agent = Vminitd

    /// Attached mounts on the virtual machine, organized by metadata ID.
    private let _mounts: Mutex<[String: [AttachedFilesystem]]>
    public var mounts: [String: [AttachedFilesystem]] {
        if let provider = hotplugProvider as? VZHotplugProvider {
            return provider.mounts
        }
        return _mounts.withLock { $0 }
    }

    /// The underlying Virtualization framework virtual machine.
    public var vzVirtualMachine: VZVirtualMachine { vm }

    /// The dispatch queue used for VZ operations.
    public var vmQueue: DispatchQueue { queue }

    /// Mutate the mount registry.
    public func withMountRegistry<T: Sendable>(_ body: (inout sending [String: [AttachedFilesystem]]) throws -> sending T) rethrows -> T {
        if let provider = hotplugProvider as? VZHotplugProvider {
            return try provider.withMountRegistry(body)
        }
        return try _mounts.withLock(body)
    }

    /// Serialize VM operations with the instance lock.
    public func withInstanceLock<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await lock.withLock { _ in try await body() }
    }

    /// The hotplug provider, if hotplug is enabled for this instance.
    public var hotplugProvider: (any HotplugProvider)? {
        get { _hotplugProvider.withLock { $0 } }
        set { _hotplugProvider.withLock { $0 = newValue } }
    }
    private let _hotplugProvider = Mutex<(any HotplugProvider)?>(nil)

    /// Returns the runtime state of the vm.
    public var state: VirtualMachineInstanceState {
        vzStateToInstanceState()
    }

    /// The virtual machine instance configuration.
    private let config: Configuration
    public struct Configuration: Sendable {
        /// Amount of cpus to allocated.
        public var cpus: Int
        /// Amount of memory in bytes allocated.
        public var memoryInBytes: UInt64
        /// Toggle rosetta's x86_64 emulation support.
        public var rosetta: Bool
        /// Toggle nested virtualization support.
        public var nestedVirtualization: Bool
        /// Mount attachments organized by metadata ID.
        public var mountsByID: [String: [Mount]]
        /// Network interface attachments.
        public var interfaces: [any Interface]
        /// Kernel image.
        public var kernel: Kernel?
        /// The root filesystem.
        public var initialFilesystem: Mount?
        /// Destination for the virtual machine's boot logs.
        public var bootLog: BootLog?
        /// Extension objects that participate in the VM instance lifecycle.
        public var extensions: [any Sendable] = []
        /// Virtual graphics device configuration.
        public var graphics: GraphicsConfiguration
        /// Legacy virtio-gpu switch. Prefer ``graphics`` to avoid order-dependent configuration.
        @available(*, deprecated, message: "Configure graphics directly with the graphics property.")
        public var graphicsDevice: Bool {
            get { self.graphics.isEnabled }
            set {
                self.graphics = newValue ? .virtioDevice : .disabled
            }
        }
        /// Legacy graphical-output switch. Prefer ``graphics`` to avoid order-dependent configuration.
        @available(*, deprecated, message: "Configure graphics directly with the graphics property.")
        public var graphicsDisplay: Bool {
            get { self.graphics.hasDisplay }
            set {
                if newValue {
                    self.graphics = .display()
                } else if self.graphics.isEnabled {
                    self.graphics = .virtioDevice
                } else {
                    self.graphics = .disabled
                }
            }
        }

        public init() {
            self.cpus = 4
            self.memoryInBytes = 1024.mib()
            self.rosetta = false
            self.nestedVirtualization = false
            self.mountsByID = [:]
            self.interfaces = []
            self.graphics = .disabled
        }
    }

    // `vm` isn't used concurrently.
    private nonisolated(unsafe) let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let lock: AsyncLock
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let timeSyncer: TimeSyncer
    private let logger: Logger?

    public convenience init(
        group: EventLoopGroup? = nil,
        logger: Logger? = nil,
        with: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try with(&config)
        try self.init(group: group, config: config, logger: logger)
    }

    init(group: EventLoopGroup?, config: Configuration, logger: Logger?) throws {
        let config = Self.withDefaultRuntimeDirectoryShare(config)
        if let group {
            self.ownsGroup = false
            self.group = group
        } else {
            self.ownsGroup = true
            // One event loop can serve this VM's agent and socket connections.
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }

        self.config = config
        self.lock = .init()
        self.queue = DispatchQueue(label: "com.apple.containerization.vzvm.\(UUID().uuidString)")
        self.logger = logger
        self.timeSyncer = .init(logger: logger)

        let allocator = Character.blockDeviceTagAllocator()
        let (mountAttachments, _) = try config.mountAttachments(allocator: allocator)
        self._mounts = Mutex(mountAttachments)

        let vzConfiguration = try config.toVZ(allocator: allocator)
        self.vm = VZVirtualMachine(
            configuration: vzConfiguration,
            queue: self.queue
        )
        let preexposedShares = config.extensions.compactMap {
            $0 as? VZPreexposedDirectoryShare
        }
        let configuredDirectoryTags = Set(
            vzConfiguration.directorySharingDevices
                .compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
                .map(\.tag)
        )
        self.hotplugProvider = try VZHotplugProvider(
            vm: self.vm,
            queue: self.queue,
            allocator: allocator,
            initialMounts: mountAttachments,
            preexposedRoots: preexposedShares.flatMap(\.roots),
            runtimeDeviceTags: preexposedShares.flatMap {
                $0.runtimeDeviceTags(for: vzConfiguration)
                    .filter(configuredDirectoryTags.contains)
            }
        )

        for ext in config.extensions.compactMap({ $0 as? any VZInstanceExtension }) {
            try ext.didCreate(self)
        }
    }

    /// Reserves runtime virtio-fs devices for ordinary VZ configurations.
    ///
    /// A directory-sharing device cannot be added after the VM starts. Keep a
    /// default empty-root extension in every VZ instance so existing callers
    /// that do not pre-expose host roots can still hotplug filesystems.
    static func withDefaultRuntimeDirectoryShare(
        _ configuration: Configuration
    ) -> Configuration {
        guard
            !configuration.extensions.contains(where: {
                $0 is VZPreexposedDirectoryShare
            })
        else {
            return configuration
        }

        var configuration = configuration
        configuration.extensions.append(
            VZPreexposedDirectoryShare(roots: [])
        )
        return configuration
    }
}

/// Protocol for extensions that participate in VZVirtualMachineInstance lifecycle.
/// Append conforming types to `Configuration.extensions` to hook into VM setup and teardown.
public protocol VZInstanceExtension: Sendable {
    /// Modify the VZ configuration before the VM is created.
    func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws

    /// Called after the VZVirtualMachine is created but before start.
    func didCreate(_ instance: VZVirtualMachineInstance) throws

    /// Called during stop before the VM is shut down.
    func willStop(_ instance: VZVirtualMachineInstance) async throws
}

extension VZInstanceExtension {
    public func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws {}

    public func didCreate(_ instance: VZVirtualMachineInstance) throws {}

    public func willStop(_ instance: VZVirtualMachineInstance) async throws {}
}

extension VZVirtualMachineInstance: VirtualMachineInstance {
    public var runtimeVirtiofsTags: Set<String> {
        (hotplugProvider as? VZHotplugProvider)?.runtimeDeviceTags ?? []
    }

    public func runtimeVirtiofsTagsToUnmount(id: String) -> Set<String> {
        (hotplugProvider as? VZHotplugProvider)?
            .runtimeDeviceTagsToUnmount(id: id) ?? []
    }

    public func start() async throws {
        try await lock.withLock { _ in
            guard self.state == .stopped else {
                throw ContainerizationError(
                    .invalidState,
                    message: "virtual machine is not stopped \(self.state)"
                )
            }

            // Do any necessary setup needed prior to starting the guest.
            try await self.prestart()

            try await self.vm.start(queue: self.queue)

            let agent = try await Vminitd(
                connection: try await self.vm.waitForAgent(queue: self.queue),
                group: self.group
            )

            do {
                if self.config.rosetta {
                    try await agent.enableRosetta()
                }
            } catch {
                try await agent.close()
                throw error
            }

            // Don't close our remote context as we are providing
            // it to our time sync routine.
            await self.timeSyncer.start(context: agent)
        }
    }

    public func stop() async throws {
        try await lock.withLock { connections in
            // NOTE: We should record HOW the vm stopped eventually. If the vm exited
            // unexpectedly virtualization framework offers you a way to store
            // an error on how it exited. We should report that here instead of the
            // generic vm is not running.
            guard self.state == .running else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }

            try await self.timeSyncer.close()

            if self.ownsGroup {
                try await self.group.shutdownGracefully()
            }

            for ext in self.config.extensions.compactMap({ $0 as? any VZInstanceExtension }) {
                try? await ext.willStop(self)
            }

            try await self.vm.stop(queue: self.queue)
        }
    }

    // NOTE: Investigate what is the "right" way to handle already vended vsock
    // connections for pause and resume.

    public func pause() async throws {
        try await lock.withLock { _ in
            await self.timeSyncer.pause()
            try await self.vm.pause(queue: self.queue)
        }
    }

    public func resume() async throws {
        try await lock.withLock { _ in
            try await self.vm.resume(queue: self.queue)
            await self.timeSyncer.resume()
        }
    }

    public func setMemoryTarget(_ memoryInBytes: UInt64) async throws {
        try await lock.withLock { _ in
            guard case .running = self.state else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }

            let maximum = Configuration.alignedMemorySize(self.config.memoryInBytes)
            try MemoryTarget.validate(memoryInBytes, maximum: maximum)

            let current = try self.vm.memoryBalloonTarget(queue: self.queue)
            if memoryInBytes < current {
                try await self.compactGuestMemory()
            }
            try self.vm.setMemoryBalloonTarget(queue: self.queue, memoryInBytes: memoryInBytes)
        }
    }

    public func dialAgent() async throws -> Vminitd {
        try await lock.withLock { _ in
            do {
                let conn = try await self.vm.connect(
                    queue: self.queue,
                    port: Vminitd.port
                )
                let handle = try conn.dupHandle()
                return try await Vminitd(connection: handle, group: self.group)
            } catch {
                if let err = error as? ContainerizationError {
                    throw err
                }
                throw ContainerizationError(
                    .internalError,
                    message: "failed to dial agent",
                    cause: error
                )
            }
        }
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        try await lock.withLock { _ in
            do {
                let conn = try await self.vm.connect(
                    queue: self.queue,
                    port: port
                )
                return try conn.dupHandle()
            } catch {
                if let err = error as? ContainerizationError {
                    throw err
                }
                throw ContainerizationError(
                    .internalError,
                    message: "failed to dial vsock port",
                    cause: error
                )
            }
        }
    }

    public func listen(_ port: UInt32) throws -> VsockListener {
        let stream = VsockListener(port: port, stopListen: self.stopListen)
        let listener = VZVirtioSocketListener()
        listener.delegate = stream

        try self.vm.listen(
            queue: queue,
            port: port,
            listener: listener
        )
        return stream
    }

    private func stopListen(_ port: UInt32) throws {
        try self.vm.removeListener(
            queue: queue,
            port: port
        )
    }

    private func compactGuestMemory() async throws {
        let agent: Vminitd
        do {
            let connection = try await self.vm.connect(queue: self.queue, port: Vminitd.port)
            agent = try await Vminitd(connection: try connection.dupHandle(), group: self.group)
        } catch {
            throw ContainerizationError(.internalError, message: "failed to connect for guest memory compaction", cause: error)
        }

        do {
            try await agent.writeFile(
                path: "/proc/sys/vm/compact_memory",
                data: Data("1\n".utf8),
                flags: WriteFileFlags(),
                mode: 0
            )
            try await agent.close()
        } catch {
            try? await agent.close()
            throw ContainerizationError(.internalError, message: "failed to compact guest memory", cause: error)
        }
    }

    // MARK: - Hotplug

    public func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        guard let hotplugProvider else {
            throw ContainerizationError(.unsupported, message: "hotplug not supported")
        }
        return try await hotplugProvider.hotplug(block, id: id)
    }

    public func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws {
        guard let hotplugProvider else { return }
        try hotplugProvider.registerMounts(id: id, rootfs: rootfs, additionalMounts: additionalMounts)
    }

    public func releaseHotplug(id: String) async throws {
        guard let hotplugProvider else { return }
        try await hotplugProvider.releaseHotplug(id: id)
    }

    public func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        guard let hotplugProvider else { return }
        try await hotplugProvider.hotplugVirtioFS(mounts, id: id)
    }

    public func releaseVirtioFS(id: String) async throws {
        guard let hotplugProvider else { return }
        try await hotplugProvider.releaseVirtioFS(id: id)
    }
}

extension VZVirtualMachineInstance {
    func vzStateToInstanceState() -> VirtualMachineInstanceState {
        self.queue.sync {
            let state: VirtualMachineInstanceState
            switch self.vm.state {
            case .starting:
                state = .starting
            case .running:
                state = .running
            case .stopping:
                state = .stopping
            case .stopped:
                state = .stopped
            default:
                state = .unknown
            }
            return state
        }
    }

    func prestart() async throws {
        if self.config.rosetta {
            #if arch(arm64)
            if VZLinuxRosettaDirectoryShare.availability == .notInstalled {
                self.logger?.info("installing rosetta")
                try await VZVirtualMachineInstance.Configuration.installRosetta()
            }
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        }
    }
}

extension VZVirtualMachineInstance.Configuration {
    public static func installRosetta() async throws {
        do {
            #if arch(arm64)
            try await VZLinuxRosettaDirectoryShare.installRosetta()
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to install rosetta",
                cause: error
            )
        }
    }

    private func serialPort(destination: BootLog) throws -> [VZVirtioConsoleDeviceSerialPortConfiguration] {
        let c = VZVirtioConsoleDeviceSerialPortConfiguration()
        switch destination.base {
        case .file(let path, let append):
            c.attachment = try VZFileSerialPortAttachment(url: path, append: append)
        case .fileHandle(let fileHandle):
            c.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: fileHandle
            )
        }
        return [c]
    }

    func toVZ(allocator: any AddressAllocator<Character>) throws -> VZVirtualMachineConfiguration {
        var config = VZVirtualMachineConfiguration()

        config.cpuCount = self.cpus
        configureMemory(on: config)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let bootLog = self.bootLog {
            config.serialPorts = try serialPort(destination: bootLog)
        } else {
            // We always supply a serial console. If no explicit path was provided just send em to the void.
            config.serialPorts = try serialPort(destination: .file(path: URL(filePath: "/dev/null")))
        }

        config.networkDevices = try self.interfaces.map {
            guard let vzi = $0 as? VZInterface else {
                throw ContainerizationError(.invalidArgument, message: "interface type not supported by VZ")
            }
            return try vzi.device()
        }

        if self.rosetta {
            #if arch(arm64)
            switch VZLinuxRosettaDirectoryShare.availability {
            case .notSupported:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "rosetta was requested but is not supported on this machine"
                )
            case .notInstalled:
                // NOTE: If rosetta isn't installed, we'll error with a nice error message
                // during .start() of the virtual machine instance.
                fallthrough
            case .installed:
                let share = try VZLinuxRosettaDirectoryShare()
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                device.share = share
                config.directorySharingDevices.append(device)
            @unknown default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unknown rosetta availability encountered: \(VZLinuxRosettaDirectoryShare.availability)"
                )
            }
            #else
            fatalError("rosetta is only supported on arm64")
            #endif
        }

        guard let kernel = self.kernel else {
            throw ContainerizationError(.invalidArgument, message: "kernel cannot be nil")
        }

        guard let initialFilesystem = self.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "rootfs cannot be nil")
        }

        let loader = VZLinuxBootLoader(kernelURL: kernel.path)
        loader.commandLine = kernel.linuxCommandline(initialFilesystem: initialFilesystem)
        config.bootLoader = loader

        try initialFilesystem.configure(config: &config)

        // Configure block devices and collect the unified virtiofs directories in
        // one pass. Resolving symlinks and hashing a source path requires filesystem
        // I/O, so cache exact repeated sources within this VM configuration.
        let directories = try configureMountDevices(config: &config)
        let multiShare = VZMultipleDirectoryShare(directories: directories)
        let virtiofsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "virtiofs")
        virtiofsDevice.share = multiShare
        config.directorySharingDevices.append(virtiofsDevice)

        if self.graphics.isEnabled {
            let device = VZVirtioGraphicsDeviceConfiguration()
            let scanout: (widthInPixels: Int, heightInPixels: Int)
            switch self.graphics {
            case .disabled:
                preconditionFailure("disabled graphics configuration reached enabled path")
            case .virtioDevice, .deviceOnly:
                scanout = (1920, 1080)
            case .display(let widthInPixels, let heightInPixels):
                scanout = (widthInPixels, heightInPixels)
            }
            guard scanout.widthInPixels > 0, scanout.heightInPixels > 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "graphics display dimensions must be positive"
                )
            }
            device.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: scanout.widthInPixels,
                    heightInPixels: scanout.heightInPixels
                )
            ]
            config.graphicsDevices = [device]
        }

        let platform = VZGenericPlatformConfiguration()
        // We shouldn't silently succeed if the user asked for virt and their hardware does
        // not support it.
        if !VZGenericPlatformConfiguration.isNestedVirtualizationSupported && self.nestedVirtualization {
            throw ContainerizationError(
                .unsupported,
                message: "nested virtualization is not supported on the platform"
            )
        }
        platform.isNestedVirtualizationEnabled = self.nestedVirtualization
        config.platform = platform

        try configureExtensions(&config, allocator: allocator)

        try config.validate()
        return config
    }

    func configureExtensions(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>
    ) throws {
        let extensions = self.extensions.compactMap {
            $0 as? any VZInstanceExtension
        }
        var runtimeShareDevices:
            [(
                extension: VZPreexposedDirectoryShare,
                devices: [VZVirtioFileSystemDeviceConfiguration]
            )] = []

        for ext in extensions {
            let existingDirectoryDeviceIDs = Set(
                config.directorySharingDevices.map(ObjectIdentifier.init)
            )
            try ext.configureVZ(
                &config,
                allocator: allocator,
                storageDeviceCount: config.storageDevices.count,
                mountsByID: self.mountsByID
            )
            if let share = ext as? VZPreexposedDirectoryShare {
                let ownedDevices = config.directorySharingDevices
                    .compactMap {
                        $0 as? VZVirtioFileSystemDeviceConfiguration
                    }
                    .filter {
                        !existingDirectoryDeviceIDs.contains(
                            ObjectIdentifier($0)
                        )
                    }
                runtimeShareDevices.append((share, ownedDevices))
            }
        }

        // Preserve public extension ordering while reconciling the share pool
        // against storage devices added by later extensions. An excess device
        // that another extension has claimed fails explicitly instead of being
        // removed behind that extension's back.
        for (share, devices) in runtimeShareDevices {
            try share.finalizeRuntimeDeviceBudget(
                &config,
                ownedRuntimeDevices: devices
            )
        }
    }

    func configureMemory(on config: VZVirtualMachineConfiguration) {
        config.memorySize = Self.alignedMemorySize(self.memoryInBytes)
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }

    static func alignedMemorySize(_ memoryInBytes: UInt64) -> UInt64 {
        let mib: UInt64 = 1 << 20
        return (memoryInBytes + mib - 1) & ~(mib - 1)
    }

    func configureMountDevices(
        config: inout VZVirtualMachineConfiguration,
        tagForPath: (String) throws -> String = hashFilePath
    ) throws -> [String: VZSharedDirectory] {
        var directories: [String: VZSharedDirectory] = [:]
        var tagsBySource: [String: String] = [:]

        for (_, mounts) in self.mountsByID {
            for mount in mounts {
                guard case .virtiofs = mount.runtimeOptions else {
                    try mount.configure(config: &config)
                    continue
                }
                let tag: String
                if let cached = tagsBySource[mount.source] {
                    tag = cached
                } else {
                    guard FileManager.default.fileExists(atPath: mount.source) else {
                        throw ContainerizationError(.notFound, message: "directory \(mount.source) does not exist")
                    }
                    tag = try tagForPath(mount.source)
                    tagsBySource[mount.source] = tag
                }
                directories[tag] = VZSharedDirectory(
                    url: URL(fileURLWithPath: mount.source),
                    readOnly: mount.options.contains("ro")
                )
            }
        }

        return directories
    }

    func mountAttachments(allocator: any AddressAllocator<Character>) throws -> (
        attachments: [String: [AttachedFilesystem]], storageDeviceCount: Int
    ) {
        var storageDeviceCount = 0

        if let initialFilesystem {
            // When the initial filesystem is a blk, allocate the first letter "vd(a)"
            // as that is what this blk will be attached under.
            if initialFilesystem.isBlock {
                _ = try allocator.allocate()
                storageDeviceCount += 1
            }
        }

        var attachmentsByID: [String: [AttachedFilesystem]] = [:]

        for (id, mounts) in self.mountsByID {
            var attachments: [AttachedFilesystem] = []
            for mount in mounts {
                let attached = try AttachedFilesystem(mount: mount, allocator: allocator)
                attachments.append(attached)
                if mount.isBlock {
                    storageDeviceCount += 1
                }
            }
            attachmentsByID[id] = attachments
        }

        return (attachmentsByID, storageDeviceCount)
    }
}

public protocol VZInterface {
    func device() throws -> VZVirtioNetworkDeviceConfiguration
}

extension NATInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }
        config.attachment = VZNATNetworkDeviceAttachment()
        return config
    }
}

#endif
