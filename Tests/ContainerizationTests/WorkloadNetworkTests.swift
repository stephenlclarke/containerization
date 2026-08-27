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
import Testing

@testable import Containerization

struct WorkloadNetworkTests {
    private func endpoint() throws -> WorkloadNetworkEndpoint {
        WorkloadNetworkEndpoint(
            hostInterfaceName: "veth-api",
            interface: InterfaceConfiguration(
                name: "eth0",
                hardwareAddress: try MACAddress("02:42:ac:11:00:02"),
                addresses: [.init(address: try CIDR("192.0.2.2/24"))]
            )
        )
    }

    @Test func workloadBridgeAcceptsAValidLinuxInterfaceName() throws {
        #expect(throws: Never.self) {
            try WorkloadNetworkBridge(name: "cz-shared0").validate()
        }
    }

    @Test(arguments: ["", "lo", "bridge-name-that-is-too-long", "bad/name"])
    func workloadBridgeRejectsInvalidLinuxInterfaceNames(_ name: String) {
        #expect(throws: ContainerizationError.self) {
            try WorkloadNetworkBridge(name: name).validate()
        }
    }

    @Test func ipv6OnlyPlanRoundTripsWithoutSyntheticIPv4() throws {
        let endpoint = WorkloadNetworkEndpoint(
            hostInterfaceName: "veth-api",
            bridgeInterfaceName: "br-backend",
            interface: InterfaceConfiguration(
                name: "backend0",
                hardwareAddress: try MACAddress("02:42:ac:11:00:02"),
                addresses: [
                    .init(address: try CIDR("fd00:42::2/64")),
                    .init(address: try CIDR("fe80::42/64"), scope: .linkLocal),
                ],
                routes: [
                    .init(nextHop: try IPAddress("fd00:42::1"), metric: 20)
                ],
                mtu: 1450,
                sysctls: ["net.ipv6.conf.IFNAME.accept_dad": "0"]
            )
        )

        let encoded = try WorkloadNetworkPlan.encode([endpoint])
        let decoded = try WorkloadNetworkPlan.decode(encoded)

        #expect(decoded == [endpoint])
        #expect(decoded[0].interface.addresses.allSatisfy { $0.address.address.isV6 })
    }

    @Test func rejectsRouteWithoutAnAddressOfTheSameFamily() throws {
        let endpoint = WorkloadNetworkEndpoint(
            hostInterfaceName: "veth-api",
            interface: InterfaceConfiguration(
                name: "eth0",
                hardwareAddress: try MACAddress("02:42:ac:11:00:02"),
                addresses: [.init(address: try CIDR("192.0.2.2/24"))],
                routes: [.init(nextHop: try IPAddress("2001:db8::1"))]
            )
        )

        #expect(throws: ContainerizationError.self) {
            try WorkloadNetworkPlan.validate([endpoint])
        }
    }

    @Test func rejectsSysctlsOutsideTheEndpointInterfaceNamespace() throws {
        let endpoint = WorkloadNetworkEndpoint(
            hostInterfaceName: "veth-api",
            interface: InterfaceConfiguration(
                name: "eth0",
                hardwareAddress: try MACAddress("02:42:ac:11:00:02"),
                addresses: [.init(address: try CIDR("192.0.2.2/24"))],
                sysctls: ["kernel.hostname": "hidden-policy"]
            )
        )

        #expect(throws: ContainerizationError.self) {
            try WorkloadNetworkPlan.validate([endpoint])
        }
    }

    @Test func podRequiresPrivateNamespaceForOwningEndpoints() throws {
        var configuration = LinuxPod.ContainerConfiguration()
        configuration.networkEndpoints = [try endpoint()]

        #expect(throws: ContainerizationError.self) {
            try LinuxPod.validateWorkloadNetwork(configuration)
        }

        configuration.networkNamespace = .privateNamespace
        #expect(throws: Never.self) {
            try LinuxPod.validateWorkloadNetwork(configuration)
        }
    }

    @Test func donorNamespaceCannotOwnASecondEndpoint() throws {
        var configuration = LinuxPod.ContainerConfiguration()
        configuration.networkNamespace = .container("database")
        configuration.networkEndpoints = [try endpoint()]

        #expect(throws: ContainerizationError.self) {
            try LinuxPod.validateWorkloadNetwork(configuration)
        }
    }

    @Test func runtimePlanAnnotationCannotBeInjectedByAWorkload() throws {
        var configuration = LinuxPod.ContainerConfiguration()
        configuration.annotations[WorkloadNetworkPlan.annotationKey] = try WorkloadNetworkPlan.encode([endpoint()])

        #expect(throws: ContainerizationError.self) {
            try LinuxPod.validateWorkloadNetwork(configuration)
        }
    }
}
