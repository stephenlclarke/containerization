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

import Foundation
import SystemPackage

/// Represents a UnixSocket that can be shared into or out of a container/guest.
public struct UnixSocketConfiguration: Sendable {
    /// The unique identifier for this socket configuration.
    ///
    /// Authorities should provide a durable grant identifier so start, stop,
    /// and recovery address the same guest relay. Ad-hoc callers retain a
    /// generated identifier for source compatibility.
    public let id: String

    /// The path to the socket you'd like relayed. For .into
    /// direction this should be the path on the host to a unix socket.
    /// For direction .outOf this should be the path in the container/guest
    /// to a unix socket.
    public var source: URL

    /// The path you'd like the socket to be relayed to. For .into
    /// direction this should be the path in the container/guest. For
    /// direction .outOf this should be the path on your host.
    public var destination: URL

    /// What to set the file permissions of the unix socket being created
    /// to. For .into direction this will be the socket in the guest. For
    /// .outOf direction this will be the socket on the host.
    public var permissions: FilePermissions?

    /// Ownership to apply to a socket created in the guest for an `.into`
    /// relay. This is computed by the authority rather than supplied by the
    /// container workload.
    public var guestOwnership: UnixSocketOwnership?

    /// The direction of the relay. `.into` for sharing a unix socket on your
    /// host into the container/guest. `outOf` shares a socket in the container/guest
    /// onto your host.
    public var direction: Direction

    /// Type that denotes the direction of the unix socket relay.
    public enum Direction: Sendable {
        /// Share the socket into the container/guest.
        case into
        /// Share a socket in the container/guest onto the host.
        case outOf
    }

    public init(
        id: String = UUID().uuidString,
        source: URL,
        destination: URL,
        permissions: FilePermissions? = nil,
        guestOwnership: UnixSocketOwnership? = nil,
        direction: Direction = .into
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.permissions = permissions
        self.guestOwnership = guestOwnership
        self.direction = direction
    }
}

/// Effective ownership for a Unix socket materialized inside a Linux guest.
public struct UnixSocketOwnership: Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32

    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }
}
