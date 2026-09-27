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

#if os(macOS)

import ContainerizationError
import ContainerizationExtras
import Foundation
import Synchronization
@preconcurrency import Virtualization

/// Runtime filesystem attachment for the Virtualization.framework backend.
///
/// VZ cannot add a virtio-block device after boot. The VM therefore exposes a
/// stable boot-time `VZMultipleDirectoryShare` and a pool of runtime devices.
/// Each runtime device is assigned to one host directory until the final guest
/// mapping is unmounted, because replacing the share on a mounted VZ device
/// invalidates existing mappings. Ext4 images below pre-exposed roots use the
/// stable device and guest loop mounts.
final class VZHotplugProvider: HotplugProvider {
    static let runtimeVirtiofsTagPrefix = "runtime-virtiofs-"

    struct PreexposedDirectory: Equatable, Sendable {
        let tag: String
        let source: String
        let readOnly: Bool
    }

    private struct State: Sendable {
        var mounts: [String: [AttachedFilesystem]]
        var runtimeShares: VZRuntimeDirectorySharePool
        let preexposedDirectories: [PreexposedDirectory]
        var rootfsShareByID: [String: VZRuntimeDirectorySharePool.Reference] = [:]
        var virtiofsSharesByID: [String: Set<VZRuntimeDirectorySharePool.Reference>] = [:]
    }

    private nonisolated(unsafe) let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let allocator: any AddressAllocator<Character>
    private let state: Mutex<State>
    private let configuredRuntimeDeviceTags: Set<String>

    init(
        vm: VZVirtualMachine,
        queue: DispatchQueue,
        allocator: any AddressAllocator<Character>,
        initialMounts: [String: [AttachedFilesystem]],
        preexposedRoots: [URL],
        runtimeDeviceTags: [String]
    ) throws {
        var preexposedDirectories: [PreexposedDirectory] = []
        for root in preexposedRoots {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: canonicalRoot.path,
                    isDirectory: &isDirectory
                ),
                isDirectory.boolValue
            else {
                throw ContainerizationError(
                    .notFound,
                    message: "pre-exposed runtime root does not exist at \(canonicalRoot.path)"
                )
            }
            let tag = try hashFilePath(path: canonicalRoot.path)
            preexposedDirectories.append(
                PreexposedDirectory(
                    tag: tag,
                    source: canonicalRoot.path,
                    readOnly: false
                )
            )
        }
        self.vm = vm
        self.queue = queue
        self.allocator = allocator
        self.configuredRuntimeDeviceTags = Set(runtimeDeviceTags)
        self.state = Mutex(
            State(
                mounts: initialMounts,
                runtimeShares: VZRuntimeDirectorySharePool(
                    deviceTags: runtimeDeviceTags
                ),
                preexposedDirectories: preexposedDirectories
            )
        )
    }

    var runtimeDeviceTags: Set<String> {
        configuredRuntimeDeviceTags
    }

    static func runtimeDeviceTags(count: Int) -> [String] {
        (0..<count).map {
            runtimeVirtiofsTagPrefix + String(format: "%02d", $0)
        }
    }

    var mounts: [String: [AttachedFilesystem]] {
        state.withLock { $0.mounts }
    }

    func withMountRegistry<T: Sendable>(
        _ body: (inout sending [String: [AttachedFilesystem]]) throws -> sending T
    ) rethrows -> T {
        try state.withLock { state in
            try body(&state.mounts)
        }
    }

    func hotplug(_ rootfs: Mount, id: String) async throws -> AttachedFilesystem {
        switch rootfs.runtimeOptions {
        case .virtioblk:
            let rootfsURL = URL(fileURLWithPath: rootfs.source).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: rootfsURL.path,
                    isDirectory: &isDirectory
                ),
                !isDirectory.boolValue,
                !rootfsURL.lastPathComponent.isEmpty
            else {
                throw ContainerizationError(
                    .notFound,
                    message: "hotplug rootfs image does not exist at \(rootfsURL.path)"
                )
            }
            if let source = Self.preexposedGuestPath(
                for: rootfsURL.path,
                in: state.withLock({ $0.preexposedDirectories }),
                requiresWrite: !rootfs.options.contains("ro")
            ) {
                return AttachedFilesystem(
                    type: rootfs.type,
                    source: source,
                    destination: rootfs.destination,
                    options: rootfs.options + ["loop"],
                    sourceSubpath: rootfs.sourceSubpath
                )
            }
            let tag = try hashFilePath(path: rootfsURL.path)
            let deviceTag = try addRuntimeShare(
                tag: tag,
                source: rootfsURL.deletingLastPathComponent().path,
                readOnly: rootfs.options.contains("ro"),
                id: id,
                rootfs: true
            )
            return AttachedFilesystem(
                type: rootfs.type,
                source: "\(Self.runtimeGuestRoot(deviceTag))/\(tag)/\(rootfsURL.lastPathComponent)",
                destination: rootfs.destination,
                options: rootfs.options + ["loop"],
                sourceSubpath: rootfs.sourceSubpath
            )

        case .virtiofs:
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: rootfs.source,
                    isDirectory: &isDirectory
                ),
                isDirectory.boolValue
            else {
                throw ContainerizationError(
                    .notFound,
                    message: "hotplug virtiofs root does not exist at \(rootfs.source)"
                )
            }
            if let source = Self.preexposedGuestPath(
                for: rootfs.source,
                in: state.withLock({ $0.preexposedDirectories }),
                requiresWrite: !rootfs.options.contains("ro")
            ) {
                return AttachedFilesystem(
                    type: "none",
                    source: try Self.subpath(root: source, relative: rootfs.sourceSubpath),
                    destination: rootfs.destination,
                    options: ["bind"] + rootfs.options.filter { $0 != "bind" }
                )
            }
            let tag = try hashFilePath(path: rootfs.source)
            let deviceTag = try addRuntimeShare(
                tag: tag,
                source: rootfs.source,
                readOnly: rootfs.options.contains("ro"),
                id: id,
                rootfs: true
            )
            let source = try Self.subpath(
                root: "\(Self.runtimeGuestRoot(deviceTag))/\(tag)",
                relative: rootfs.sourceSubpath
            )
            return AttachedFilesystem(
                type: "none",
                source: source,
                destination: rootfs.destination,
                options: ["bind"] + rootfs.options.filter { $0 != "bind" }
            )

        case .shared, .any:
            throw ContainerizationError(
                .unsupported,
                message: "hotplug rootfs must be virtio-blk or virtiofs"
            )
        }
    }

    func registerMounts(
        id: String,
        rootfs: AttachedFilesystem,
        additionalMounts: [Mount]
    ) throws {
        var attached: [AttachedFilesystem] = [rootfs]
        for mount in additionalMounts {
            var attachment = try AttachedFilesystem(mount: mount, allocator: allocator)
            if case .virtiofs = mount.runtimeOptions {
                let source: String
                if let preexposedSource = Self.preexposedGuestPath(
                    for: mount.source,
                    in: state.withLock({ $0.preexposedDirectories }),
                    requiresWrite: !mount.options.contains("ro")
                ) {
                    source = preexposedSource
                } else {
                    let reference = VZRuntimeDirectorySharePool.Reference(
                        tag: attachment.source,
                        readOnly: mount.options.contains("ro")
                    )
                    let deviceTag = try state.withLock { state in
                        guard let deviceTag = state.runtimeShares.deviceTag(for: reference) else {
                            throw ContainerizationError(
                                .invalidState,
                                message: "runtime virtiofs share is not registered for \(mount.source)"
                            )
                        }
                        return deviceTag
                    }
                    source = "\(Self.runtimeGuestRoot(deviceTag))/\(attachment.source)"
                }
                attachment.guestSource = try Self.subpath(root: source, relative: mount.sourceSubpath)
            }
            attached.append(attachment)
        }
        state.withLock { state in
            state.mounts[id] = attached
        }
    }

    func releaseHotplug(id: String) async throws {
        let reference = state.withLock { state in
            state.mounts[id] = nil
            return state.rootfsShareByID.removeValue(forKey: id)
        }
        guard let reference else { return }
        try removeRuntimeShares([reference])
    }

    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        var additions: [(reference: VZRuntimeDirectorySharePool.Reference, source: String)] = []
        var seen: Set<VZRuntimeDirectorySharePool.Reference> = []
        for mount in mounts {
            guard case .virtiofs = mount.runtimeOptions else { continue }
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: mount.source,
                    isDirectory: &isDirectory
                ),
                isDirectory.boolValue
            else {
                throw ContainerizationError(
                    .notFound,
                    message: "hotplug virtiofs directory does not exist at \(mount.source)"
                )
            }
            if Self.preexposedGuestPath(
                for: mount.source,
                in: state.withLock({ $0.preexposedDirectories }),
                requiresWrite: !mount.options.contains("ro")
            ) != nil {
                continue
            }
            let tag = try hashFilePath(path: mount.source)
            let reference = VZRuntimeDirectorySharePool.Reference(
                tag: tag,
                readOnly: mount.options.contains("ro")
            )
            guard seen.insert(reference).inserted else { continue }
            additions.append((reference, mount.source))
        }
        guard !additions.isEmpty else { return }

        try state.withLock { state in
            guard state.virtiofsSharesByID[id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "virtiofs hotplug already exists for \(id)"
                )
            }
            let originalPool = state.runtimeShares
            var configuredDevices: Set<String> = []
            do {
                for addition in additions {
                    let acquisition = try state.runtimeShares.acquire(
                        addition.reference,
                        source: addition.source
                    )
                    if acquisition.newlyAssigned {
                        try configureRuntimeDevice(
                            acquisition.deviceTag,
                            reference: addition.reference,
                            source: addition.source
                        )
                        configuredDevices.insert(acquisition.deviceTag)
                    }
                }
            } catch {
                try? clearRuntimeDevices(configuredDevices)
                state.runtimeShares = originalPool
                throw error
            }
            state.virtiofsSharesByID[id] = Set(additions.map(\.reference))
        }
    }

    func releaseVirtioFS(id: String) async throws {
        let references = state.withLock { state in
            state.virtiofsSharesByID.removeValue(forKey: id) ?? []
        }
        guard !references.isEmpty else { return }
        try removeRuntimeShares(references)
    }

    private func addRuntimeShare(
        tag: String,
        source: String,
        readOnly: Bool,
        id: String,
        rootfs: Bool
    ) throws -> String {
        try state.withLock { state in
            if rootfs {
                guard state.rootfsShareByID[id] == nil else {
                    throw ContainerizationError(
                        .exists,
                        message: "rootfs hotplug already exists for \(id)"
                    )
                }
            }
            let reference = VZRuntimeDirectorySharePool.Reference(
                tag: tag,
                readOnly: readOnly
            )
            let originalPool = state.runtimeShares
            let acquisition: VZRuntimeDirectorySharePool.Acquisition
            do {
                acquisition = try state.runtimeShares.acquire(
                    reference,
                    source: source
                )
                if acquisition.newlyAssigned {
                    try configureRuntimeDevice(
                        acquisition.deviceTag,
                        reference: reference,
                        source: source
                    )
                }
            } catch {
                state.runtimeShares = originalPool
                throw error
            }
            if rootfs {
                state.rootfsShareByID[id] = reference
            }
            return acquisition.deviceTag
        }
    }

    private func removeRuntimeShares(
        _ references: some Sequence<VZRuntimeDirectorySharePool.Reference>
    ) throws {
        try state.withLock { state in
            var updatedPool = state.runtimeShares
            let releasedDevices = updatedPool.release(references)
            try clearRuntimeDevices(releasedDevices)
            state.runtimeShares = updatedPool
        }
    }

    func runtimeDeviceTagsToUnmount(id: String) -> Set<String> {
        state.withLock { state in
            var references: [VZRuntimeDirectorySharePool.Reference] = []
            if let rootfsReference = state.rootfsShareByID[id] {
                references.append(rootfsReference)
            }
            references.append(contentsOf: state.virtiofsSharesByID[id] ?? [])
            return state.runtimeShares.devicesReleased(by: references)
        }
    }

    private func configureRuntimeDevice(
        _ deviceTag: String,
        reference: VZRuntimeDirectorySharePool.Reference,
        source: String
    ) throws {
        try queue.sync {
            guard
                let device = vm.directorySharingDevices
                    .compactMap({ $0 as? VZVirtioFileSystemDevice })
                    .first(where: { $0.tag == deviceTag })
            else {
                throw ContainerizationError(
                    .notFound,
                    message: "runtime virtiofs device \(deviceTag) is unavailable"
                )
            }
            let canonicalSource = URL(fileURLWithPath: source)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            device.share = VZMultipleDirectoryShare(
                directories: [
                    reference.tag: VZSharedDirectory(
                        url: canonicalSource,
                        readOnly: reference.readOnly
                    )
                ]
            )
        }
    }

    private func clearRuntimeDevices(_ deviceTags: some Sequence<String>) throws {
        try queue.sync {
            let devices = Dictionary(
                uniqueKeysWithValues: vm.directorySharingDevices
                    .compactMap { $0 as? VZVirtioFileSystemDevice }
                    .map { ($0.tag, $0) }
            )
            for deviceTag in deviceTags {
                guard let device = devices[deviceTag] else {
                    throw ContainerizationError(
                        .notFound,
                        message: "runtime virtiofs device \(deviceTag) is unavailable"
                    )
                }
                device.share = VZMultipleDirectoryShare(directories: [:])
            }
        }
    }

    static func preexposedGuestPath(
        for source: String,
        in directories: [PreexposedDirectory],
        requiresWrite: Bool
    ) -> String? {
        let sourceComponents = URL(fileURLWithPath: source)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let match =
            directories
            .filter { directory in
                guard !requiresWrite || !directory.readOnly else { return false }
                let rootComponents = URL(fileURLWithPath: directory.source)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .pathComponents
                return sourceComponents.starts(with: rootComponents)
            }
            .max { lhs, rhs in
                URL(fileURLWithPath: lhs.source).pathComponents.count
                    < URL(fileURLWithPath: rhs.source).pathComponents.count
            }
        guard let match else { return nil }

        let rootComponents = URL(fileURLWithPath: match.source)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        let relativeComponents = sourceComponents.dropFirst(rootComponents.count)
        let guestRoot = "/run/virtiofs/\(match.tag)"
        guard !relativeComponents.isEmpty else { return guestRoot }
        return guestRoot + "/" + relativeComponents.joined(separator: "/")
    }

    private static func runtimeGuestRoot(_ deviceTag: String) -> String {
        "/run/\(deviceTag)"
    }

    private static func subpath(root: String, relative: String?) throws -> String {
        guard let relative else { return root }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard
            !relative.hasPrefix("/"),
            !components.isEmpty,
            !components.contains("."),
            !components.contains("..")
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid virtiofs rootfs subpath"
            )
        }
        return root + "/" + components.joined(separator: "/")
    }
}

#endif
