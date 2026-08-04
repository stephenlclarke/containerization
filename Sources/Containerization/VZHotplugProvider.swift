//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
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
/// single mutable `VZMultipleDirectoryShare`; ext4 images are added to that
/// share and mounted through guest loop devices. Directory mounts are added to
/// the same live share. The guest owns loop-device setup and teardown so a
/// host share is never withdrawn while its filesystem is mounted.
final class VZHotplugProvider: HotplugProvider {
    private struct ShareState: Sendable {
        let source: String
        var references: Int
        var writableReferences: Int

        var readOnly: Bool { writableReferences == 0 }
    }

    private struct ShareReference: Hashable, Sendable {
        let tag: String
        let readOnly: Bool
    }

    private struct State: Sendable {
        var mounts: [String: [AttachedFilesystem]]
        var shares: [String: ShareState]
        var rootfsShareByID: [String: ShareReference] = [:]
        var virtiofsSharesByID: [String: Set<ShareReference>] = [:]
    }

    private nonisolated(unsafe) let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let allocator: any AddressAllocator<Character>
    private let state: Mutex<State>

    init(
        vm: VZVirtualMachine,
        queue: DispatchQueue,
        allocator: any AddressAllocator<Character>,
        initialMounts: [String: [AttachedFilesystem]],
        bootMounts: [String: [Mount]]
    ) throws {
        var shares: [String: ShareState] = [:]
        for mounts in bootMounts.values {
            for mount in mounts {
                guard case .virtiofs = mount.runtimeOptions else { continue }
                let tag = try hashFilePath(path: mount.source)
                try Self.addShare(
                    tag: tag,
                    source: mount.source,
                    readOnly: mount.options.contains("ro"),
                    to: &shares
                )
            }
        }
        self.vm = vm
        self.queue = queue
        self.allocator = allocator
        self.state = Mutex(State(mounts: initialMounts, shares: shares))
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
            let tag = try hashFilePath(path: rootfsURL.path)
            try addRuntimeShare(
                tag: tag,
                source: rootfsURL.deletingLastPathComponent().path,
                readOnly: rootfs.options.contains("ro"),
                id: id,
                rootfs: true
            )
            return AttachedFilesystem(
                type: rootfs.type,
                source: "/run/virtiofs/\(tag)/\(rootfsURL.lastPathComponent)",
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
            let tag = try hashFilePath(path: rootfs.source)
            try addRuntimeShare(
                tag: tag,
                source: rootfs.source,
                readOnly: rootfs.options.contains("ro"),
                id: id,
                rootfs: true
            )
            let source = try Self.subpath(root: "/run/virtiofs/\(tag)", relative: rootfs.sourceSubpath)
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
            attached.append(try AttachedFilesystem(mount: mount, allocator: allocator))
        }
        state.withLock { state in
            state.mounts[id] = attached
        }
    }

    func releaseHotplug(id: String) async throws {
        let reference = state.withLock { state -> ShareReference? in
            state.mounts[id] = nil
            return state.rootfsShareByID.removeValue(forKey: id)
        }
        guard let reference else { return }
        try removeRuntimeShares([reference])
    }

    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        var additions: [(tag: String, source: String, readOnly: Bool)] = []
        var seen: Set<String> = []
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
            let tag = try hashFilePath(path: mount.source)
            guard seen.insert(tag).inserted else { continue }
            additions.append((tag, mount.source, mount.options.contains("ro")))
        }
        guard !additions.isEmpty else { return }

        let references = Set(
            additions.map {
                ShareReference(tag: $0.tag, readOnly: $0.readOnly)
            }
        )
        try state.withLock { state in
            guard state.virtiofsSharesByID[id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "virtiofs hotplug already exists for \(id)"
                )
            }
            var updatedShares = state.shares
            for addition in additions {
                try Self.addShare(
                    tag: addition.tag,
                    source: addition.source,
                    readOnly: addition.readOnly,
                    to: &updatedShares
                )
            }
            state.shares = updatedShares
            state.virtiofsSharesByID[id] = references
        }
        do {
            try updateDirectoryShare()
        } catch {
            state.withLock { state in
                state.virtiofsSharesByID[id] = nil
                Self.removeShares(references, from: &state.shares)
            }
            throw error
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
    ) throws {
        try state.withLock { state in
            if rootfs {
                guard state.rootfsShareByID[id] == nil else {
                    throw ContainerizationError(
                        .exists,
                        message: "rootfs hotplug already exists for \(id)"
                    )
                }
            }
            try Self.addShare(
                tag: tag,
                source: source,
                readOnly: readOnly,
                to: &state.shares
            )
            if rootfs {
                state.rootfsShareByID[id] = ShareReference(
                    tag: tag,
                    readOnly: readOnly
                )
            }
        }
        do {
            try updateDirectoryShare()
        } catch {
            state.withLock { state in
                if rootfs {
                    state.rootfsShareByID[id] = nil
                }
                Self.removeShares(
                    [ShareReference(tag: tag, readOnly: readOnly)],
                    from: &state.shares
                )
            }
            throw error
        }
    }

    private func removeRuntimeShares(
        _ references: some Sequence<ShareReference>
    ) throws {
        state.withLock { state in
            Self.removeShares(references, from: &state.shares)
        }
        try updateDirectoryShare()
    }

    private func updateDirectoryShare() throws {
        let shares = state.withLock { $0.shares }
        try queue.sync {
            guard
                let device = vm.directorySharingDevices
                    .compactMap({ $0 as? VZVirtioFileSystemDevice })
                    .first(where: { $0.tag == "virtiofs" })
            else {
                throw ContainerizationError(
                    .notFound,
                    message: "unified virtiofs device is unavailable"
                )
            }
            var directories: [String: VZSharedDirectory] = [:]
            for (tag, share) in shares {
                directories[tag] = VZSharedDirectory(
                    url: URL(fileURLWithPath: share.source),
                    readOnly: share.readOnly
                )
            }
            device.share = VZMultipleDirectoryShare(directories: directories)
        }
    }

    private static func addShare(
        tag: String,
        source: String,
        readOnly: Bool,
        to shares: inout [String: ShareState]
    ) throws {
        if var existing = shares[tag] {
            guard existing.source == source else {
                throw ContainerizationError(
                    .invalidState,
                    message: "virtiofs tag collision for \(tag)"
                )
            }
            existing.references += 1
            if !readOnly {
                existing.writableReferences += 1
            }
            shares[tag] = existing
        } else {
            shares[tag] = ShareState(
                source: source,
                references: 1,
                writableReferences: readOnly ? 0 : 1
            )
        }
    }

    private static func removeShares(
        _ references: some Sequence<ShareReference>,
        from shares: inout [String: ShareState]
    ) {
        for reference in references {
            guard var share = shares[reference.tag] else { continue }
            share.references -= 1
            if !reference.readOnly {
                share.writableReferences -= 1
            }
            if share.references == 0 {
                shares[reference.tag] = nil
            } else {
                shares[reference.tag] = share
            }
        }
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
