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

#if os(Linux)

import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import VminitdCore

struct ManagedContainerSysctlTests {
    private let log = Logger(label: "ManagedContainerSysctlTests")

    @Test func runcWritesNetworkSysctlAndKeepsOnlyNamespacedKeys() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let networkFile = root.appending(path: "net/ipv4/ip_forward")
        try FileManager.default.createDirectory(at: networkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: networkFile)

        var spec = Spec(
            linux: Linux(sysctl: [
                "net.ipv4.ip_forward": "1",
                "kernel.shm_rmid_forced": "0",
            ])
        )
        try ManagedContainer.prepareSysctlsForRuntime(
            spec: &spec,
            ociRuntimePath: "/usr/bin/runc",
            procSysRoot: root.path,
            log: log
        )

        #expect(try String(contentsOf: networkFile, encoding: .utf8) == "1")
        #expect(spec.linux?.sysctl == ["kernel.shm_rmid_forced": "0"])
    }

    @Test func vmexecAndSpecsWithoutNetworkSysctlsDoNotWrite() throws {
        let missingRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var vmexecSpec = Spec(linux: Linux(sysctl: ["net.ipv4.ip_forward": "1"]))
        try ManagedContainer.prepareSysctlsForRuntime(
            spec: &vmexecSpec,
            ociRuntimePath: nil,
            procSysRoot: missingRoot.path,
            log: log
        )
        #expect(vmexecSpec.linux?.sysctl == ["net.ipv4.ip_forward": "1"])

        var nonNetworkSpec = Spec(linux: Linux(sysctl: ["kernel.shm_rmid_forced": "0"]))
        try ManagedContainer.prepareSysctlsForRuntime(
            spec: &nonNetworkSpec,
            ociRuntimePath: "/usr/bin/runc",
            procSysRoot: missingRoot.path,
            log: log
        )
        #expect(nonNetworkSpec.linux?.sysctl == ["kernel.shm_rmid_forced": "0"])

        var emptySpec = Spec()
        try ManagedContainer.prepareSysctlsForRuntime(
            spec: &emptySpec,
            ociRuntimePath: "/usr/bin/runc",
            procSysRoot: missingRoot.path,
            log: log
        )
        #expect(emptySpec.linux == nil)
        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    }

    @Test func openFailurePreservesOriginalSpec() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sysctls = ["net.ipv4.ip_forward": "1", "kernel.shm_rmid_forced": "0"]
        var spec = Spec(linux: Linux(sysctl: sysctls))

        #expect(throws: ContainerizationError.self) {
            try ManagedContainer.prepareSysctlsForRuntime(
                spec: &spec,
                ociRuntimePath: "/usr/bin/runc",
                procSysRoot: root.path,
                log: log
            )
        }
        #expect(spec.linux?.sysctl == sysctls)
    }

    @Test func laterOpenFailureLeavesSpecUnmodifiedAfterEarlierWrite() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "net/ipv4/conf/all/accept_redirects")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: first)
        let sysctls = [
            "net.ipv4.conf.all.accept_redirects": "0",
            "net.ipv4.ip_forward": "1",
            "kernel.shm_rmid_forced": "0",
        ]
        var spec = Spec(linux: Linux(sysctl: sysctls))

        #expect(throws: ContainerizationError.self) {
            try ManagedContainer.prepareSysctlsForRuntime(
                spec: &spec,
                ociRuntimePath: "/usr/bin/runc",
                procSysRoot: root.path,
                log: log
            )
        }
        #expect(try String(contentsOf: first, encoding: .utf8) == "0")
        #expect(spec.linux?.sysctl == sysctls)
    }

    @Test func writeFailurePreservesOriginalSpec() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let networkFile = root.appending(path: "net/ipv4/ip_forward")
        try FileManager.default.createDirectory(at: networkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: networkFile, withDestinationURL: URL(fileURLWithPath: "/dev/full"))
        let sysctls = ["net.ipv4.ip_forward": "1", "kernel.shm_rmid_forced": "0"]
        var spec = Spec(linux: Linux(sysctl: sysctls))

        #expect(throws: ContainerizationError.self) {
            try ManagedContainer.prepareSysctlsForRuntime(
                spec: &spec,
                ociRuntimePath: "/usr/bin/runc",
                procSysRoot: root.path,
                log: log
            )
        }
        #expect(spec.linux?.sysctl == sysctls)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "managed-sysctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

#endif
