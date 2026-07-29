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

/// Framing shared by the guest DNS proxy and its host-side resolver.
public enum DNSProxyProtocol {
    public static let guestAddress = "127.0.0.11"
    public static let guestPort = 53
    public static let hostVsockPort: UInt32 = 1025
    public static let maximumMessageLength = 4096

    public struct Frame: Equatable, Sendable {
        public let message: Data
        public let consumedBytes: Int

        public init(message: Data, consumedBytes: Int) {
            self.message = message
            self.consumedBytes = consumedBytes
        }
    }

    public enum FramingError: Error, Equatable {
        case emptyMessage
        case messageTooLarge(Int)
    }

    public static func encode(_ message: Data) throws -> Data {
        guard !message.isEmpty else {
            throw FramingError.emptyMessage
        }
        guard message.count <= maximumMessageLength else {
            throw FramingError.messageTooLarge(message.count)
        }

        var length = UInt16(message.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(message)
        return frame
    }

    public static func decode(_ data: Data) throws -> Frame? {
        guard data.count >= MemoryLayout<UInt16>.size else {
            return nil
        }

        let length = data.prefix(MemoryLayout<UInt16>.size).withUnsafeBytes {
            UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
        }
        let messageLength = Int(length)
        guard messageLength > 0 else {
            throw FramingError.emptyMessage
        }
        guard messageLength <= maximumMessageLength else {
            throw FramingError.messageTooLarge(messageLength)
        }

        let consumedBytes = MemoryLayout<UInt16>.size + messageLength
        guard data.count >= consumedBytes else {
            return nil
        }
        return Frame(
            message: data.subdata(in: MemoryLayout<UInt16>.size..<consumedBytes),
            consumedBytes: consumedBytes
        )
    }
}
