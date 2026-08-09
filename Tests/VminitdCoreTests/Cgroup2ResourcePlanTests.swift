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
import ContainerizationOCI
import Testing

@testable import Cgroup

struct Cgroup2ResourcePlanTests {
    @Test func memoryReservationAndCombinedSwapMapToV2Files() throws {
        let memory = LinuxMemory(
            limit: 536_870_912,
            reservation: 268_435_456,
            swap: 805_306_368,
            checkBeforeUpdate: true
        )
        let resources = LinuxResources(memory: memory)

        let plan = try Cgroup2ResourcePlan.make(resources: resources, bfqWeightAvailable: false)

        let expected: [Cgroup2ResourceWrite] = [
            .init(fileName: "memory.swap.max", value: "268435456"),
            .init(fileName: "memory.max", value: "536870912"),
            .init(fileName: "memory.low", value: "268435456"),
        ]
        #expect(plan.writes == expected)
        #expect(plan.memoryLimitCheck == 536_870_912)
    }

    @Test func equalCombinedSwapAndMemoryDisablesSwap() throws {
        let resources = LinuxResources(memory: .init(limit: 1024, swap: 1024))
        let plan = try Cgroup2ResourcePlan.make(resources: resources, bfqWeightAvailable: false)

        #expect(plan.writes[0] == .init(fileName: "memory.swap.max", value: "0", missingFilePolicy: .ignore))
    }

    @Test func finiteSwapRequiresCompatibleMemoryLimit() {
        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(
                resources: .init(memory: .init(swap: 1024)),
                bfqWeightAvailable: false
            )
        }
        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(
                resources: .init(memory: .init(limit: 2048, swap: 1024)),
                bfqWeightAvailable: false
            )
        }
    }

    @Test func cpuPartialQuotaBurstAndIdleMapWithoutSilentDrops() throws {
        let resources = LinuxResources(
            cpu: .init(shares: 512, quota: 80_000, burst: 20_000, idle: 1)
        )
        let plan = try Cgroup2ResourcePlan.make(resources: resources, bfqWeightAvailable: false)

        #expect(plan.writes.contains(.init(fileName: "cpu.weight", value: "59")))
        #expect(plan.writes.contains(.init(fileName: "cpu.idle", value: "1")))
        #expect(plan.cpuMaximum == .init(fileName: "cpu.max", value: "80000 100000"))
        #expect(plan.cpuBurst == .init(fileName: "cpu.max.burst", value: "20000"))
    }

    @Test func periodWithoutQuotaKeepsQuotaUnlimited() throws {
        let plan = try Cgroup2ResourcePlan.make(
            resources: .init(cpu: .init(period: 50_000)),
            bfqWeightAvailable: false
        )

        #expect(plan.cpuMaximum == .init(fileName: "cpu.max", value: "max 50000"))
    }

    @Test func blockIOConvertsWeightAndGroupsThrottleFieldsByDevice() throws {
        let blockIO = LinuxBlockIO(
            weight: 500,
            leafWeight: nil,
            weightDevice: [],
            throttleReadBpsDevice: [.init(major: 8, minor: 0, rate: 1_000_000)],
            throttleWriteBpsDevice: [.init(major: 8, minor: 0, rate: 2_000_000)],
            throttleReadIOPSDevice: [],
            throttleWriteIOPSDevice: [.init(major: 8, minor: 0, rate: 300)]
        )
        let plan = try Cgroup2ResourcePlan.make(
            resources: .init(blockIO: blockIO),
            bfqWeightAvailable: false
        )

        #expect(plan.writes[0] == .init(fileName: "io.weight", value: "4950"))
        #expect(
            plan.writes[1]
                == .init(fileName: "io.max", value: "8:0 rbps=1000000 wbps=2000000 wiops=300")
        )
    }

    @Test func perDeviceWeightRequiresBFQAndUsesItsNativeScale() throws {
        let blockIO = LinuxBlockIO(
            weight: 100,
            leafWeight: nil,
            weightDevice: [.init(major: 8, minor: 16, weight: 700, leafWeight: nil)],
            throttleReadBpsDevice: [],
            throttleWriteBpsDevice: [],
            throttleReadIOPSDevice: [],
            throttleWriteIOPSDevice: []
        )

        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(resources: .init(blockIO: blockIO), bfqWeightAvailable: false)
        }

        let plan = try Cgroup2ResourcePlan.make(
            resources: .init(blockIO: blockIO),
            bfqWeightAvailable: true
        )
        #expect(plan.writes[0] == .init(fileName: "io.bfq.weight", value: "100"))
        #expect(plan.writes[1] == .init(fileName: "io.bfq.weight", value: "8:16 700"))
    }

    @Test func hugepageRdmaAndUnifiedWritesAreDeterministic() throws {
        let resources = LinuxResources(
            hugepageLimits: [.init(pagesize: "2MB", limit: 64 * 1024 * 1024)],
            rdma: ["mlx5_0": .init(hcsHandles: 4, hcaObjects: 8)],
            unified: ["memory.high": "1048576", "cpu.uclamp.min": "20"]
        )
        let plan = try Cgroup2ResourcePlan.make(resources: resources, bfqWeightAvailable: false)

        #expect(plan.writes[0] == .init(fileName: "hugetlb.2MB.max", value: "67108864"))
        #expect(
            plan.writes[1]
                == .init(
                    fileName: "hugetlb.2MB.rsvd.max",
                    value: "67108864",
                    missingFilePolicy: .ignore
                )
        )
        #expect(plan.writes[2] == .init(fileName: "rdma.max", value: "mlx5_0 hca_handle=4 hca_object=8"))
        #expect(
            plan.unifiedWrites == [
                .init(fileName: "cpu.uclamp.min", value: "20"),
                .init(fileName: "memory.high", value: "1048576"),
            ]
        )
    }

    @Test func nonConvertibleAndUnsafeResourcesFailExplicitly() {
        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(
                resources: .init(
                    devices: [.init(allow: true, type: "c", major: 1, minor: 3, access: "rwm")]
                ),
                bfqWeightAvailable: false
            )
        }
        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(
                resources: .init(memory: .init(swappiness: 0)),
                bfqWeightAvailable: false
            )
        }
        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(
                resources: .init(unified: ["../cgroup.procs": "1"]),
                bfqWeightAvailable: false
            )
        }
        #expect(throws: ContainerizationError.self) {
            try Cgroup2ResourcePlan.make(
                resources: .init(unified: ["..": "1"]),
                bfqWeightAvailable: false
            )
        }
    }
}
