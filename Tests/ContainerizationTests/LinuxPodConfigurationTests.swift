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

import Testing

@testable import Containerization

struct LinuxPodConfigurationTests {
    @Test func namespaceSharingDefaultsToPrivateNamespaces() {
        let configuration = LinuxPod.Configuration()

        #expect(configuration.sharedNamespaces.isEmpty)
    }

    @Test func namespaceSharingSelectsProcessAndIPCIndependently() {
        var configuration = LinuxPod.Configuration()
        configuration.sharedNamespaces = [.process, .interprocessCommunication]

        #expect(configuration.sharedNamespaces.contains(.process))
        #expect(configuration.sharedNamespaces.contains(.interprocessCommunication))
    }

    @Test func legacyProcessNamespacePropertyBridgesTypedPolicy() {
        var configuration = LinuxPod.Configuration()
        configuration.sharedNamespaces = [.interprocessCommunication]
        configuration.shareProcessNamespace = true

        #expect(configuration.sharedNamespaces == [.process, .interprocessCommunication])
        #expect(configuration.shareProcessNamespace)

        configuration.shareProcessNamespace = false

        #expect(configuration.sharedNamespaces == [.interprocessCommunication])
        #expect(!configuration.shareProcessNamespace)
    }

    @Test func namespacePoliciesRenderPrivateAndSharedWorkloadNamespaces() {
        let privateNamespaces = LinuxPod.containerNamespaces(sharedNamespaces: [], pausePID: nil)
        #expect(privateNamespaces.map(\.type.rawValue) == ["cgroup", "mount", "uts", "ipc", "pid"])
        #expect(privateNamespaces.map(\.path) == ["", "", "", "", ""])

        let processNamespaces = LinuxPod.containerNamespaces(sharedNamespaces: [.process], pausePID: 42)
        #expect(processNamespaces.map(\.path) == ["", "", "", "", "/proc/42/ns/pid"])

        let ipcNamespaces = LinuxPod.containerNamespaces(sharedNamespaces: [.interprocessCommunication], pausePID: 42)
        #expect(ipcNamespaces.map(\.path) == ["", "", "", "/proc/42/ns/ipc", ""])

        let sharedNamespaces = LinuxPod.containerNamespaces(
            sharedNamespaces: [.process, .interprocessCommunication],
            pausePID: 42
        )
        #expect(sharedNamespaces.map(\.path) == ["", "", "", "/proc/42/ns/ipc", "/proc/42/ns/pid"])
    }
}
