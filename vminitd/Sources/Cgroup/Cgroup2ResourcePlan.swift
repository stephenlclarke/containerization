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
import Foundation

package enum Cgroup2MissingFilePolicy: Sendable {
    case required
    case ignore
}

package struct Cgroup2ResourceWrite: Equatable, Sendable {
    package var fileName: String
    package var value: String
    package var missingFilePolicy: Cgroup2MissingFilePolicy

    package init(
        fileName: String,
        value: String,
        missingFilePolicy: Cgroup2MissingFilePolicy = .required
    ) {
        self.fileName = fileName
        self.value = value
        self.missingFilePolicy = missingFilePolicy
    }
}

package struct Cgroup2ResourcePlan: Equatable, Sendable {
    package var writes: [Cgroup2ResourceWrite]
    package var unifiedWrites: [Cgroup2ResourceWrite]
    package var cpuMaximum: Cgroup2ResourceWrite?
    package var cpuBurst: Cgroup2ResourceWrite?
    package var memoryLimitCheck: Int64?

    package init(
        writes: [Cgroup2ResourceWrite] = [],
        unifiedWrites: [Cgroup2ResourceWrite] = [],
        cpuMaximum: Cgroup2ResourceWrite? = nil,
        cpuBurst: Cgroup2ResourceWrite? = nil,
        memoryLimitCheck: Int64? = nil
    ) {
        self.writes = writes
        self.unifiedWrites = unifiedWrites
        self.cpuMaximum = cpuMaximum
        self.cpuBurst = cpuBurst
        self.memoryLimitCheck = memoryLimitCheck
    }

    package static func make(
        resources: LinuxResources,
        bfqWeightAvailable: Bool
    ) throws -> Self {
        try validateUnsupportedResources(resources)

        var plan = Self()
        try appendMemory(resources.memory, to: &plan)
        try appendCPU(resources.cpu, to: &plan)
        try appendPids(resources.pids, to: &plan)
        try appendBlockIO(resources.blockIO, bfqWeightAvailable: bfqWeightAvailable, to: &plan)
        try appendHugepages(resources.hugepageLimits, to: &plan)
        try appendRdma(resources.rdma, to: &plan)
        try appendUnified(resources.unified, to: &plan)
        return plan
    }

    package static func cpuWeight(fromShares shares: UInt64) -> UInt64 {
        guard shares != 0 else { return 0 }
        if shares <= 2 { return 1 }
        if shares >= 262_144 { return 10_000 }

        let logarithm = log2(Double(shares))
        let exponent = (logarithm * logarithm + 125 * logarithm) / 612 - 7.0 / 34.0
        return UInt64(ceil(pow(10, exponent)))
    }

    package static func ioWeight(fromBlockIOWeight weight: UInt16) throws -> UInt64 {
        guard (10...1000).contains(weight) else {
            throw invalid("block I/O weight must be between 10 and 1000")
        }
        return 1 + (UInt64(weight) - 10) * 9999 / 990
    }

    package static func swapOnlyLimit(memorySwap: Int64, memoryLimit: Int64?) throws -> Int64? {
        switch (memorySwap, memoryLimit) {
        case (0, _):
            return nil
        case (-1, _):
            return -1
        case (...(-2), _):
            throw invalid("memory+swap limit must be -1 or non-negative")
        case (_, nil), (_, 0):
            throw invalid("memory+swap limit requires a memory limit")
        case (_, -1):
            return memorySwap
        case (_, let memory?) where memory < -1:
            throw invalid("memory limit must be -1 or non-negative")
        case (_, let memory?) where memorySwap < memory:
            throw invalid("memory+swap limit must be greater than or equal to the memory limit")
        case (_, let memory?):
            return memorySwap - memory
        }
    }

    private static func appendMemory(_ memory: LinuxMemory?, to plan: inout Self) throws {
        guard let memory else { return }

        if memory.kernel != nil || memory.kernelTCP != nil {
            throw unsupported("kernel memory limits have no cgroup v2 equivalent")
        }
        if memory.swappiness != nil {
            throw unsupported("memory swappiness has no cgroup v2 equivalent")
        }
        if memory.disableOOMKiller == true {
            throw unsupported("disabling the OOM killer has no cgroup v2 equivalent")
        }
        if memory.useHierarchy == false {
            throw unsupported("cgroup v2 memory accounting is always hierarchical")
        }
        if let limit = memory.limit, limit < -1 {
            throw invalid("memory limit must be -1 or non-negative")
        }
        if let reservation = memory.reservation, reservation < -1 {
            throw invalid("memory reservation must be -1 or non-negative")
        }

        if let swap = memory.swap,
            let value = try swapOnlyLimit(memorySwap: swap, memoryLimit: memory.limit)
        {
            let encoded = value == -1 ? "max" : String(value)
            let policy: Cgroup2MissingFilePolicy = encoded == "max" || encoded == "0" ? .ignore : .required
            plan.writes.append(.init(fileName: "memory.swap.max", value: encoded, missingFilePolicy: policy))
        } else if memory.limit == -1 {
            plan.writes.append(.init(fileName: "memory.swap.max", value: "max", missingFilePolicy: .ignore))
        }

        if let limit = memory.limit, limit != 0 {
            plan.writes.append(.init(fileName: "memory.max", value: limit == -1 ? "max" : String(limit)))
            if memory.checkBeforeUpdate == true, limit > 0 {
                plan.memoryLimitCheck = limit
            }
        }
        if let reservation = memory.reservation, reservation != 0 {
            plan.writes.append(
                .init(fileName: "memory.low", value: reservation == -1 ? "max" : String(reservation))
            )
        }
    }

    private static func appendCPU(_ cpu: LinuxCPU?, to plan: inout Self) throws {
        guard let cpu else { return }

        if cpu.realtimeRuntime != nil || cpu.realtimePeriod != nil {
            throw unsupported("realtime CPU limits have no cgroup v2 equivalent")
        }
        if let quota = cpu.quota, quota < -1 {
            throw invalid("CPU quota must be -1 or non-negative")
        }
        if let idle = cpu.idle, idle != 0 && idle != 1 {
            throw invalid("CPU idle must be 0 or 1")
        }
        if let shares = cpu.shares, shares != 0 {
            plan.writes.append(.init(fileName: "cpu.weight", value: String(cpuWeight(fromShares: shares))))
        }
        if let idle = cpu.idle {
            plan.writes.append(.init(fileName: "cpu.idle", value: String(idle)))
        }

        if cpu.quota != nil || cpu.period != nil {
            let quota = cpu.quota ?? -1
            let period = cpu.period == nil || cpu.period == 0 ? 100_000 : cpu.period!
            let quotaValue = quota <= 0 ? "max" : String(quota)
            plan.cpuMaximum = .init(fileName: "cpu.max", value: "\(quotaValue) \(period)")
        }
        if let burst = cpu.burst {
            if let quota = cpu.quota, quota > 0, burst > UInt64(quota) {
                throw invalid("CPU burst cannot exceed a positive CPU quota")
            }
            plan.cpuBurst = .init(fileName: "cpu.max.burst", value: String(burst))
        }
    }

    private static func appendPids(_ pids: LinuxPids?, to plan: inout Self) throws {
        guard let pids else { return }
        guard pids.limit >= -1 else {
            throw invalid("PIDs limit must be -1 or non-negative")
        }
        plan.writes.append(.init(fileName: "pids.max", value: pids.limit == -1 ? "max" : String(pids.limit)))
    }

    private static func appendBlockIO(
        _ blockIO: LinuxBlockIO?,
        bfqWeightAvailable: Bool,
        to plan: inout Self
    ) throws {
        guard let blockIO else { return }
        if blockIO.leafWeight != nil || blockIO.weightDevice.contains(where: { $0.leafWeight != nil }) {
            throw unsupported("block I/O leaf weights have no cgroup v2 equivalent")
        }

        if let weight = blockIO.weight {
            let value = bfqWeightAvailable ? UInt64(weight) : try ioWeight(fromBlockIOWeight: weight)
            if bfqWeightAvailable {
                _ = try ioWeight(fromBlockIOWeight: weight)
            }
            plan.writes.append(
                .init(fileName: bfqWeightAvailable ? "io.bfq.weight" : "io.weight", value: String(value))
            )
        }

        for device in blockIO.weightDevice {
            try validateDevice(major: device.major, minor: device.minor)
            guard let weight = device.weight else { continue }
            _ = try ioWeight(fromBlockIOWeight: weight)
            guard bfqWeightAvailable else {
                throw unsupported("per-device block I/O weights require the BFQ controller")
            }
            plan.writes.append(
                .init(fileName: "io.bfq.weight", value: "\(device.major):\(device.minor) \(weight)")
            )
        }

        var throttles: [DeviceNumber: [String: UInt64]] = [:]
        try addThrottles(blockIO.throttleReadBpsDevice, key: "rbps", to: &throttles)
        try addThrottles(blockIO.throttleWriteBpsDevice, key: "wbps", to: &throttles)
        try addThrottles(blockIO.throttleReadIOPSDevice, key: "riops", to: &throttles)
        try addThrottles(blockIO.throttleWriteIOPSDevice, key: "wiops", to: &throttles)

        let keyOrder = ["rbps", "wbps", "riops", "wiops"]
        for device in throttles.keys.sorted() {
            let values = throttles[device]!
            let limits = keyOrder.compactMap { key in values[key].map { "\(key)=\($0)" } }
            plan.writes.append(
                .init(fileName: "io.max", value: "\(device.major):\(device.minor) " + limits.joined(separator: " "))
            )
        }
    }

    private static func appendHugepages(_ limits: [LinuxHugepageLimit], to plan: inout Self) throws {
        for limit in limits {
            try validatePageSize(limit.pagesize)
            let prefix = "hugetlb.\(limit.pagesize)"
            let value = String(limit.limit)
            plan.writes.append(.init(fileName: prefix + ".max", value: value))
            plan.writes.append(
                .init(fileName: prefix + ".rsvd.max", value: value, missingFilePolicy: .ignore)
            )
        }
    }

    private static func appendRdma(_ rdma: [String: LinuxRdma]?, to plan: inout Self) throws {
        guard let rdma else { return }
        for device in rdma.keys.sorted() {
            guard isSafeToken(device) else {
                throw invalid("invalid RDMA device name '\(device)'")
            }
            let limit = rdma[device]!
            var values: [String] = []
            if let handles = limit.hcsHandles {
                values.append("hca_handle=\(handles)")
            }
            if let objects = limit.hcaObjects {
                values.append("hca_object=\(objects)")
            }
            if !values.isEmpty {
                plan.writes.append(.init(fileName: "rdma.max", value: device + " " + values.joined(separator: " ")))
            }
        }
    }

    private static func appendUnified(_ unified: [String: String]?, to plan: inout Self) throws {
        guard let unified else { return }
        let forbidden = Set([
            "cgroup.freeze", "cgroup.kill", "cgroup.procs", "cgroup.subtree_control",
            "cgroup.threads", "cgroup.type",
        ])
        for key in unified.keys.sorted() {
            guard isSafeFileName(key), !forbidden.contains(key) else {
                throw invalid("unsafe unified cgroup resource key '\(key)'")
            }
            plan.unifiedWrites.append(.init(fileName: key, value: unified[key]!))
        }
    }

    private static func validateUnsupportedResources(_ resources: LinuxResources) throws {
        if !resources.devices.isEmpty {
            throw unsupported("cgroup v2 device rules require a BPF device controller")
        }
        if let network = resources.network,
            network.classID != nil || !network.priorities.isEmpty
        {
            throw unsupported("OCI network class and priority controls are cgroup v1-only")
        }
    }

    private static func addThrottles(
        _ devices: [LinuxThrottleDevice],
        key: String,
        to result: inout [DeviceNumber: [String: UInt64]]
    ) throws {
        for device in devices {
            try validateDevice(major: device.major, minor: device.minor)
            let number = DeviceNumber(major: device.major, minor: device.minor)
            guard result[number]?[key] == nil else {
                throw invalid("duplicate block I/O throttle for \(device.major):\(device.minor) \(key)")
            }
            result[number, default: [:]][key] = device.rate
        }
    }

    private static func validateDevice(major: Int64, minor: Int64) throws {
        guard major >= 0, minor >= 0 else {
            throw invalid("block I/O device numbers must be non-negative")
        }
    }

    private static func validatePageSize(_ value: String) throws {
        let suffixes = ["KB", "MB", "GB"]
        guard let suffix = suffixes.first(where: value.hasSuffix) else {
            throw invalid("invalid hugepage size '\(value)'")
        }
        let digits = value.dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw invalid("invalid hugepage size '\(value)'")
        }
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.contains(".")
            && value.utf8.allSatisfy { byte in
                byte == 45 || byte == 46 || byte == 95
                    || (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
            }
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                byte == 45 || byte == 46 || byte == 95
                    || (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
            }
    }

    private static func invalid(_ message: String) -> ContainerizationError {
        ContainerizationError(.invalidArgument, message: message)
    }

    private static func unsupported(_ message: String) -> ContainerizationError {
        ContainerizationError(.unsupported, message: message)
    }

    private struct DeviceNumber: Hashable, Comparable {
        var major: Int64
        var minor: Int64

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
        }
    }
}
