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

/// The address scope applied to one workload interface assignment.
public enum InterfaceAddressScope: String, Codable, Sendable {
    case global
    case linkLocal
    case loopback
}

/// A family-neutral address assigned to a workload interface.
public struct InterfaceIPAssignment: Codable, Equatable, Sendable {
    public var address: CIDR
    public var scope: InterfaceAddressScope

    public init(address: CIDR, scope: InterfaceAddressScope = .global) {
        self.address = address
        self.scope = scope
    }
}

/// A family-neutral route installed in a workload network namespace.
///
/// A `nil` destination denotes the default route for the next-hop family.
/// A route without a next hop is link-scoped.
public struct InterfaceRoute: Codable, Equatable, Sendable {
    public var destination: CIDR?
    public var nextHop: IPAddress?
    public var metric: UInt32?

    public init(destination: CIDR? = nil, nextHop: IPAddress? = nil, metric: UInt32? = nil) {
        self.destination = destination
        self.nextHop = nextHop
        self.metric = metric
    }
}

/// Complete configuration for one interface inside a workload network namespace.
public struct InterfaceConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var hardwareAddress: MACAddress
    public var addresses: [InterfaceIPAssignment]
    public var routes: [InterfaceRoute]
    public var mtu: UInt32?
    public var sysctls: [String: String]

    public init(
        name: String,
        hardwareAddress: MACAddress,
        addresses: [InterfaceIPAssignment] = [],
        routes: [InterfaceRoute] = [],
        mtu: UInt32? = nil,
        sysctls: [String: String] = [:]
    ) {
        self.name = name
        self.hardwareAddress = hardwareAddress
        self.addresses = addresses
        self.routes = routes
        self.mtu = mtu
        self.sysctls = sysctls
    }
}

/// A low-level veth endpoint plan for one workload.
///
/// Address allocation, driver policy, endpoint ownership, and persistence stay in
/// the caller. Containerization only realises this resolved attachment plan.
public struct WorkloadNetworkEndpoint: Codable, Equatable, Sendable {
    public var hostInterfaceName: String
    public var bridgeInterfaceName: String?
    public var interface: InterfaceConfiguration

    public init(
        hostInterfaceName: String,
        bridgeInterfaceName: String? = nil,
        interface: InterfaceConfiguration
    ) {
        self.hostInterfaceName = hostInterfaceName
        self.bridgeInterfaceName = bridgeInterfaceName
        self.interface = interface
    }
}

/// Internal OCI annotation transport shared by the host library, vminitd, and vmexec.
public enum WorkloadNetworkPlan {
    public static let annotationKey = "io.github.stephenlclarke.containerization.workload-network.v1"
    private static let maximumEndpoints = 64
    private static let maximumEntriesPerInterface = 256
    private static let maximumEncodedBytes = 256 * 1024

    public static func encode(_ endpoints: [WorkloadNetworkEndpoint]) throws -> String {
        try validate(endpoints)
        let data = try JSONEncoder().encode(endpoints)
        guard data.count <= maximumEncodedBytes else {
            throw ContainerizationError(.invalidArgument, message: "workload network plan exceeds 256 KiB")
        }
        return data.base64EncodedString()
    }

    public static func decode(_ value: String) throws -> [WorkloadNetworkEndpoint] {
        guard value.utf8.count <= ((maximumEncodedBytes + 2) / 3) * 4 else {
            throw ContainerizationError(.invalidArgument, message: "workload network plan exceeds 256 KiB")
        }
        guard let data = Data(base64Encoded: value) else {
            throw ContainerizationError(.invalidArgument, message: "invalid workload network plan encoding")
        }
        return try JSONDecoder().decode([WorkloadNetworkEndpoint].self, from: data)
    }

    public static func validate(_ endpoints: [WorkloadNetworkEndpoint]) throws {
        guard endpoints.count <= maximumEndpoints else {
            throw ContainerizationError(.invalidArgument, message: "workload network plan exceeds 64 endpoints")
        }
        let hostNames = endpoints.map(\.hostInterfaceName)
        let guestNames = endpoints.map(\.interface.name)
        guard Set(hostNames).count == hostNames.count else {
            throw ContainerizationError(.invalidArgument, message: "host endpoint interface names must be unique")
        }
        guard Set(guestNames).count == guestNames.count else {
            throw ContainerizationError(.invalidArgument, message: "workload interface names must be unique")
        }

        for endpoint in endpoints {
            guard endpoint.interface.addresses.count <= maximumEntriesPerInterface,
                endpoint.interface.routes.count <= maximumEntriesPerInterface,
                endpoint.interface.sysctls.count <= maximumEntriesPerInterface
            else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "workload interface plan exceeds 256 addresses, routes, or sysctls"
                )
            }
            try validateInterfaceName(endpoint.hostInterfaceName, role: "host endpoint")
            try validateInterfaceName(endpoint.interface.name, role: "workload")
            if endpoint.interface.name == "lo" {
                throw ContainerizationError(.invalidArgument, message: "workload interface name 'lo' is reserved")
            }
            if let bridge = endpoint.bridgeInterfaceName {
                try validateInterfaceName(bridge, role: "bridge")
            }
            if let mtu = endpoint.interface.mtu, mtu < 68 {
                throw ContainerizationError(.invalidArgument, message: "workload interface MTU must be at least 68")
            }

            let addressFamilies = Set(endpoint.interface.addresses.map { $0.address.address.isV4 })
            for route in endpoint.interface.routes {
                guard route.destination != nil || route.nextHop != nil else {
                    throw ContainerizationError(.invalidArgument, message: "workload route requires a destination or next hop")
                }
                if let destination = route.destination, let nextHop = route.nextHop,
                    destination.address.isV4 != nextHop.isV4
                {
                    throw ContainerizationError(.invalidArgument, message: "workload route destination and next hop use different address families")
                }
                let routeIsV4 = route.destination?.address.isV4 ?? route.nextHop!.isV4
                guard addressFamilies.contains(routeIsV4) else {
                    throw ContainerizationError(.invalidArgument, message: "workload route has no configured address in its family")
                }
            }

            for key in endpoint.interface.sysctls.keys {
                guard
                    key.hasPrefix("net.ipv4.conf.IFNAME.")
                        || key.hasPrefix("net.ipv6.conf.IFNAME.")
                        || key.hasPrefix("net.mpls.conf.IFNAME.")
                else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "workload interface sysctl '\(key)' is outside the allowed interface namespaces"
                    )
                }
            }
            guard endpoint.interface.sysctls.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 4096 }) else {
                throw ContainerizationError(.invalidArgument, message: "workload interface sysctl exceeds size limits")
            }
        }
    }

    private static func validateInterfaceName(_ name: String, role: String) throws {
        guard !name.isEmpty, name.utf8.count <= 15,
            !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" || $0 == "\0" })
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "\(role) interface name '\(name)' must be 1-15 bytes and cannot contain whitespace, '/', ':', or NUL"
            )
        }
    }
}
