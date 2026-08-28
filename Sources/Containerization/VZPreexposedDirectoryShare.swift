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
@preconcurrency import Virtualization

/// Pre-exposes host directories through the immutable boot-time VZ share.
///
/// Virtualization.framework cannot add a directory-sharing device after a VM
/// starts. Runtime filesystem images below these roots can therefore be
/// attached without changing the device that backs mappings held by
/// already-running workloads. Runtime-only shares use a bounded pool of
/// devices that are reused only after their previous guest mapping is
/// unmounted.
public struct VZPreexposedDirectoryShare: VZInstanceExtension {
    /// Virtualization.framework fails to start a VM when the combined number
    /// of boot-time storage devices, additional directory-sharing devices,
    /// and reserved runtime virtiofs devices exceeds this budget. The required
    /// baseline `virtiofs` share is excluded. Keep ordinary configurations at
    /// the requested pool size while yielding capacity to other devices.
    static let bootDeviceBudget = 20

    public let roots: [URL]
    public let runtimeDeviceCount: Int

    public init(roots: [URL], runtimeDeviceCount: Int = 16) {
        self.roots = roots
        self.runtimeDeviceCount = runtimeDeviceCount
    }

    func runtimeDeviceTags(
        storageDeviceCount: Int,
        additionalDirectorySharingDeviceCount: Int = 0
    ) -> [String] {
        let availableCount = max(
            0,
            Self.bootDeviceBudget - storageDeviceCount
                - additionalDirectorySharingDeviceCount
        )
        return VZHotplugProvider.runtimeDeviceTags(
            count: min(runtimeDeviceCount, availableCount)
        )
    }

    func runtimeDeviceTags(
        for config: VZVirtualMachineConfiguration
    ) -> [String] {
        runtimeDeviceTags(
            storageDeviceCount: config.storageDevices.count,
            additionalDirectorySharingDeviceCount:
                additionalDirectorySharingDeviceCount(in: config)
        )
    }

    private func additionalDirectorySharingDeviceCount(
        in config: VZVirtualMachineConfiguration
    ) -> Int {
        let possibleRuntimeTags = Set(
            VZHotplugProvider.runtimeDeviceTags(count: runtimeDeviceCount)
        )
        return config
            .directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
            .filter {
                $0.tag != "virtiofs"
                    && !possibleRuntimeTags.contains($0.tag)
            }
            .count
    }

    func finalizeRuntimeDeviceBudget(
        _ config: inout VZVirtualMachineConfiguration
    ) throws {
        let allowedTags = Set(runtimeDeviceTags(for: config))
        let excessTags = Set(runtimeDeviceTags(storageDeviceCount: 0))
            .subtracting(allowedTags)

        for device in config.directorySharingDevices.compactMap({
            $0 as? VZVirtioFileSystemDeviceConfiguration
        }) where excessTags.contains(device.tag) {
            guard
                let share = device.share as? VZMultipleDirectoryShare,
                share.directories.isEmpty
            else {
                throw ContainerizationError(
                    .invalidState,
                    message: "runtime virtiofs device \(device.tag) exceeds the available boot-device budget and is already in use"
                )
            }
        }

        config.directorySharingDevices.removeAll {
            guard
                let device = $0 as? VZVirtioFileSystemDeviceConfiguration
            else {
                return false
            }
            return excessTags.contains(device.tag)
        }
    }

    public func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws {
        guard (0...64).contains(runtimeDeviceCount) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "runtime virtiofs device count must be between 0 and 64"
            )
        }
        guard
            let device = config.directorySharingDevices
                .compactMap({ $0 as? VZVirtioFileSystemDeviceConfiguration })
                .first(where: { $0.tag == "virtiofs" }),
            let share = device.share as? VZMultipleDirectoryShare
        else {
            throw ContainerizationError(
                .notFound,
                message: "boot-time virtiofs configuration is unavailable"
            )
        }

        var directories = share.directories
        for root in roots {
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
            if let existing = directories[tag] {
                let existingRoot = existing.url
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard existingRoot.path == canonicalRoot.path else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "virtiofs tag collision for \(tag)"
                    )
                }
            }
            directories[tag] = VZSharedDirectory(
                url: canonicalRoot,
                readOnly: false
            )
        }
        device.share = VZMultipleDirectoryShare(directories: directories)

        let existingTags = Set(
            config.directorySharingDevices
                .compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
                .map(\.tag)
        )
        for tag in runtimeDeviceTags(
            storageDeviceCount: storageDeviceCount,
            additionalDirectorySharingDeviceCount:
                additionalDirectorySharingDeviceCount(in: config)
        ) {
            guard !existingTags.contains(tag) else {
                throw ContainerizationError(
                    .exists,
                    message: "virtiofs device tag already exists: \(tag)"
                )
            }
            let runtimeDevice = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            runtimeDevice.share = VZMultipleDirectoryShare(directories: [:])
            config.directorySharingDevices.append(runtimeDevice)
        }
    }
}

#endif
