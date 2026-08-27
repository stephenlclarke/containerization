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
    public let roots: [URL]
    public let runtimeDeviceCount: Int

    public init(roots: [URL], runtimeDeviceCount: Int = 16) {
        self.roots = roots
        self.runtimeDeviceCount = runtimeDeviceCount
    }

    var runtimeDeviceTags: [String] {
        VZHotplugProvider.runtimeDeviceTags(count: runtimeDeviceCount)
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
        for tag in runtimeDeviceTags {
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
