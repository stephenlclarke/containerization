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

import Foundation
import Testing

@testable import Containerization

struct DNSProxyProtocolTests {
    @Test func roundTripsMessage() throws {
        let message = Data([0x12, 0x34, 0x01, 0x00])
        let encoded = try DNSProxyProtocol.encode(message)
        let frame = try DNSProxyProtocol.decode(encoded)
        let decoded = try #require(frame)

        #expect(decoded.message == message)
        #expect(decoded.consumedBytes == encoded.count)
    }

    @Test func returnsNilForPartialFrame() throws {
        let encoded = try DNSProxyProtocol.encode(Data([0x01, 0x02, 0x03]))

        #expect(try DNSProxyProtocol.decode(Data(encoded.prefix(1))) == nil)
        #expect(try DNSProxyProtocol.decode(Data(encoded.dropLast())) == nil)
    }

    @Test func reportsConsumedBytesBeforeTrailingFrame() throws {
        let first = try DNSProxyProtocol.encode(Data([0x01]))
        let second = try DNSProxyProtocol.encode(Data([0x02]))
        let frame = try DNSProxyProtocol.decode(first + second)
        let decoded = try #require(frame)

        #expect(decoded.message == Data([0x01]))
        #expect(decoded.consumedBytes == first.count)
    }

    @Test func rejectsEmptyMessage() {
        #expect(throws: DNSProxyProtocol.FramingError.emptyMessage) {
            try DNSProxyProtocol.encode(Data())
        }
        #expect(throws: DNSProxyProtocol.FramingError.emptyMessage) {
            try DNSProxyProtocol.decode(Data([0x00, 0x00]))
        }
    }

    @Test func rejectsOversizedMessage() {
        let message = Data(repeating: 0, count: DNSProxyProtocol.maximumMessageLength + 1)
        #expect(
            throws: DNSProxyProtocol.FramingError.messageTooLarge(message.count)
        ) {
            try DNSProxyProtocol.encode(message)
        }

        let oversizedLength = UInt16(DNSProxyProtocol.maximumMessageLength + 1).bigEndian
        let oversizedFrame = withUnsafeBytes(of: oversizedLength) { Data($0) }
        #expect(
            throws: DNSProxyProtocol.FramingError.messageTooLarge(message.count)
        ) {
            try DNSProxyProtocol.decode(oversizedFrame)
        }
    }
}
