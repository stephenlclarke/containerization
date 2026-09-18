//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import CoreFoundation

// takes a pointer and converts its contents to native endian bytes
public func withUnsafeLittleEndianBytes<T, Result>(of value: T, body: (UnsafeRawBufferPointer) throws -> Result)
    rethrows -> Result
{
    switch Endian {
    case .little:
        return try withUnsafeBytes(of: value) { bytes in
            try body(bytes)
        }
    case .big:
        return try withUnsafeBytes(of: value) { buffer in
            let reversedBuffer = Array(buffer.reversed())
            return try reversedBuffer.withUnsafeBytes { buf in
                try body(buf)
            }
        }
    }
}

public func withUnsafeLittleEndianBuffer<T>(
    of value: UnsafeRawBufferPointer, body: (UnsafeRawBufferPointer) throws -> T
) rethrows -> T {
    switch Endian {
    case .little:
        return try body(value)
    case .big:
        let reversed = Array(value.reversed())
        return try reversed.withUnsafeBytes { buf in
            try body(buf)
        }
    }
}

extension UnsafeRawBufferPointer {
    // Image bytes and Data slices need not satisfy the loaded type's alignment.
    public func loadLittleEndian<T>(as type: T.Type) -> T {
        loadLittleEndian(as: type, byteOrder: Endian)
    }

    // Keep both host-byte-order paths testable without changing global state.
    func loadLittleEndian<T>(as _: T.Type, byteOrder: Endianness) -> T {
        switch byteOrder {
        case .little:
            return self.loadUnaligned(as: T.self)
        case .big:
            let buffer = Array(self.reversed())
            return buffer.withUnsafeBytes { ptr in
                ptr.loadUnaligned(as: T.self)
            }
        }
    }
}

public enum Endianness {
    case little
    case big
}

// returns current endianness
public var Endian: Endianness {
    var value: UInt32 = 0x0102_0304
    return withUnsafeBytes(of: &value) { buffer in
        buffer.first == 0x04 ? .little : .big
    }
}
