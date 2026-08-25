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
import Testing
import Virtualization

@testable import Containerization

struct VZMemoryTests {
    @Test func configurationAddsIdleMemoryBalloon() {
        var configuration = VZVirtualMachineInstance.Configuration()
        configuration.memoryInBytes = 512 * 1024 * 1024 + 1
        let vzConfiguration = VZVirtualMachineConfiguration()

        configuration.configureMemory(on: vzConfiguration)

        #expect(vzConfiguration.memorySize == 513 * 1024 * 1024)
        #expect(vzConfiguration.memoryBalloonDevices.count == 1)
        #expect(vzConfiguration.memoryBalloonDevices[0] is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
    }

    @Test func memoryTargetsMustBeAlignedAndWithinConfiguredRange() throws {
        let maximum: UInt64 = 512 * 1024 * 1024

        #expect(MemoryTarget.minimum == VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        try MemoryTarget.validate(maximum, maximum: maximum)
        try MemoryTarget.validate(MemoryTarget.minimum, maximum: maximum)
        #expect(throws: ContainerizationError.self) {
            try MemoryTarget.validate(maximum - 1, maximum: maximum)
        }
        #expect(throws: ContainerizationError.self) {
            try MemoryTarget.validate(maximum + MemoryTarget.alignment, maximum: maximum)
        }
        #expect(throws: ContainerizationError.self) {
            try MemoryTarget.validate(MemoryTarget.minimum - MemoryTarget.alignment, maximum: maximum)
        }
    }
}
#endif
