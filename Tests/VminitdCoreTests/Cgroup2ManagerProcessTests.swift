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
import Foundation
import Testing

@testable import Cgroup

struct Cgroup2ManagerProcessTests {
    @Test(arguments: [(UInt64(0), UInt64(0)), (1, 1), (2, 1), (512, 59), (1024, 100), (262_144, 10_000)])
    func cpuSharesConvertToCgroupV2Weight(shares: UInt64, expectedWeight: UInt64) {
        #expect(Cgroup2Manager.cpuWeight(fromShares: shares) == expectedWeight)
    }

    @Test func cpuSharesWriteConvertedCgroupV2Weight() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cgroup-cpu-weight-\(UUID().uuidString)")
        let group = URL(filePath: "container")
        let cgroup = root.appending(path: group.path)
        try FileManager.default.createDirectory(at: cgroup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cpuWeight = cgroup.appending(path: "cpu.weight")
        try Data().write(to: cpuWeight)

        let manager = Cgroup2Manager(mountPoint: root, group: group)
        try manager.applyResources(resources: .init(cpu: .init(shares: 512)))

        #expect(try String(contentsOf: cpuWeight, encoding: .utf8) == "59")
    }

    @Test func unlimitedCPUQuotaUsesCgroupMax() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cgroup-cpu-\(UUID().uuidString)")
        let group = URL(filePath: "container")
        let cgroup = root.appending(path: group.path)
        try FileManager.default.createDirectory(at: cgroup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cpuMax = cgroup.appending(path: "cpu.max")
        try Data().write(to: cpuMax)

        let manager = Cgroup2Manager(mountPoint: root, group: group)
        try manager.applyResources(resources: .init(cpu: .init(quota: -1, period: 100_000)))

        #expect(try String(contentsOf: cpuMax, encoding: .utf8) == "max 100000")
    }

    @Test func processIdentifiersHandleEmptyFiles() throws {
        #expect(try Cgroup2Manager.parseProcessIdentifiers(nil) == [])
        #expect(try Cgroup2Manager.parseProcessIdentifiers("") == [])
    }

    @Test func processIdentifiersTrimAndSortValues() throws {
        let identifiers = try Cgroup2Manager.parseProcessIdentifiers("99\n 7 \n42\n")

        #expect(identifiers == [7, 42, 99])
    }

    @Test func processIdentifiersRejectMalformedValues() {
        #expect(throws: ContainerizationError.self) {
            try Cgroup2Manager.parseProcessIdentifiers("42\nnot-a-pid\n")
        }
    }

    @Test func processInfoRowsAreReadFromProc() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cgroup-process-\(UUID().uuidString)")
        let processRoot = root.appending(path: "42")
        try FileManager.default.createDirectory(at: processRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "42 (sleep) S 7 42 42 0 -1 0 0 0 0 0 200 300 0 0 20 0 1 0 9000 0\n"
            .write(to: processRoot.appending(path: "stat"), atomically: true, encoding: .utf8)
        try "Name:\tsleep\nUid:\t0\t0\t0\t0\n"
            .write(to: processRoot.appending(path: "status"), atomically: true, encoding: .utf8)
        try Data([UInt8(ascii: "s"), UInt8(ascii: "l"), UInt8(ascii: "e"), UInt8(ascii: "e"), UInt8(ascii: "p"), 0, UInt8(ascii: "6"), UInt8(ascii: "0"), 0])
            .write(to: processRoot.appending(path: "cmdline"))

        let rows = try Cgroup2Manager.processes(
            identifiers: [42],
            procRoot: root,
            now: Date(timeIntervalSince1970: 3_600),
            uptime: 100,
            clockTicks: 100
        )

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.uid == "root")
        #expect(row.pid == 42)
        #expect(row.ppid == 7)
        #expect(row.cpu == 50)
        #expect(!row.startTime.isEmpty)
        #expect(row.tty == "?")
        #expect(row.time == "00:00:05")
        #expect(row.command == "sleep 60")
    }

    @Test func processInfoRowsSkipExitedProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cgroup-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = try Cgroup2Manager.processes(
            identifiers: [42],
            procRoot: root,
            now: Date(timeIntervalSince1970: 0),
            uptime: 1_000,
            clockTicks: 100
        )

        #expect(rows == [])
    }

    @Test func commandLineFallsBackToStatCommandName() {
        #expect(Cgroup2Manager.parseCommandLine(Data(), fallbackCommandName: "sh") == "[sh]")
    }
}

#endif
