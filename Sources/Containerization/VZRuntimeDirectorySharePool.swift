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
import Foundation

/// Allocates immutable, boot-created virtio-fs devices to runtime shares.
///
/// Virtualization.framework does not preserve guest mappings when the share
/// on a mounted device is replaced. A device is therefore assigned to one
/// canonical host directory and access mode until its final reference is
/// released. Only then may the device be cleared and returned to the pool.
struct VZRuntimeDirectorySharePool: Sendable {
    struct Reference: Hashable, Sendable {
        let tag: String
        let readOnly: Bool
    }

    struct Share: Equatable, Sendable {
        let source: String
        let deviceTag: String
        var references: Int
    }

    struct Acquisition: Equatable, Sendable {
        let deviceTag: String
        let newlyAssigned: Bool
    }

    private(set) var shares: [Reference: Share] = [:]
    private var availableDeviceTags: [String]

    init(deviceTags: [String]) {
        self.availableDeviceTags = deviceTags.sorted()
    }

    func deviceTag(for reference: Reference) -> String? {
        shares[reference]?.deviceTag
    }

    mutating func acquire(
        _ reference: Reference,
        source: String
    ) throws -> Acquisition {
        let canonicalSource = URL(fileURLWithPath: source)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if var existing = shares[reference] {
            guard existing.source == canonicalSource else {
                throw ContainerizationError(
                    .invalidState,
                    message: "virtiofs tag collision for \(reference.tag)"
                )
            }
            existing.references += 1
            shares[reference] = existing
            return Acquisition(
                deviceTag: existing.deviceTag,
                newlyAssigned: false
            )
        }

        guard !availableDeviceTags.isEmpty else {
            throw ContainerizationError(
                .empty,
                message: "runtime virtiofs device pool is exhausted"
            )
        }
        let deviceTag = availableDeviceTags.removeFirst()
        shares[reference] = Share(
            source: canonicalSource,
            deviceTag: deviceTag,
            references: 1
        )
        return Acquisition(deviceTag: deviceTag, newlyAssigned: true)
    }

    /// Returns devices whose final reference would be removed.
    func devicesReleased(
        by references: some Sequence<Reference>
    ) -> Set<String> {
        var releaseCounts: [Reference: Int] = [:]
        for reference in references {
            releaseCounts[reference, default: 0] += 1
        }
        return Set(
            releaseCounts.compactMap { reference, count in
                guard let share = shares[reference], share.references == count else {
                    return nil
                }
                return share.deviceTag
            }
        )
    }

    /// Releases references and returns devices that can be safely cleared.
    mutating func release(
        _ references: some Sequence<Reference>
    ) -> Set<String> {
        var releasedDevices: Set<String> = []
        for reference in references {
            guard var share = shares[reference] else { continue }
            share.references -= 1
            if share.references == 0 {
                shares[reference] = nil
                releasedDevices.insert(share.deviceTag)
                availableDeviceTags.append(share.deviceTag)
            } else {
                shares[reference] = share
            }
        }
        availableDeviceTags.sort()
        return releasedDevices
    }
}

#endif
