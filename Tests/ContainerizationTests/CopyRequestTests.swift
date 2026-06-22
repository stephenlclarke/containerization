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

import Containerization
import Testing

struct CopyRequestTests {
    @Test func copyRequestRoundTripsCopyOptions() throws {
        let request = Com_Apple_Containerization_Sandbox_V3_CopyRequest.with {
            $0.direction = .copyOut
            $0.path = "/run/container/example/rootfs/tmp/link"
            $0.vsockPort = 42
            $0.followSymlink = true
            $0.preserveOwnership = true
            $0.uid = 501
            $0.gid = 20
        }

        let bytes: [UInt8] = try request.serializedBytes()
        let decoded = try Com_Apple_Containerization_Sandbox_V3_CopyRequest(serializedBytes: bytes)

        #expect(decoded.direction == Com_Apple_Containerization_Sandbox_V3_CopyRequest.Direction.copyOut)
        #expect(decoded.path == "/run/container/example/rootfs/tmp/link")
        #expect(decoded.vsockPort == 42)
        #expect(decoded.followSymlink)
        #expect(decoded.preserveOwnership)
        #expect(decoded.uid == 501)
        #expect(decoded.gid == 20)
    }

    @Test func copyResponseRoundTripsSingleFileMetadata() throws {
        let response = Com_Apple_Containerization_Sandbox_V3_CopyResponse.with {
            $0.status = .metadata
            $0.totalSize = 128
            $0.mode = 0o100640
            $0.uid = 1000
            $0.gid = 1001
        }

        let bytes: [UInt8] = try response.serializedBytes()
        let decoded = try Com_Apple_Containerization_Sandbox_V3_CopyResponse(serializedBytes: bytes)

        #expect(decoded.status == Com_Apple_Containerization_Sandbox_V3_CopyResponse.Status.metadata)
        #expect(decoded.totalSize == 128)
        #expect(decoded.mode == 0o100640)
        #expect(decoded.uid == 1000)
        #expect(decoded.gid == 1001)
    }
}
