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

@testable import ContainerizationEXT4

struct UnalignedLittleEndianTests {
    @Test(arguments: 0..<8, [false, true])
    func loadsBothByteOrderPaths(offset: Int, reverse: Bool) {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
        defer { storage.deallocate() }
        let bytes = UnsafeMutableRawBufferPointer(start: storage, count: 16)
        for index in 0..<8 {
            bytes[offset + index] = UInt8(index + 1)
        }
        let input = UnsafeRawBufferPointer(start: storage.advanced(by: offset), count: 8)
        let byteOrder: Endianness = reverse ? .big : .little
        // Simulate each branch on this host, not a claim of big-endian hardware validation.
        let expected64: UInt64 = reverse ? 0x0102_0304_0506_0708 : 0x0807_0605_0403_0201
        let expected32: UInt32 = reverse ? 0x0102_0304 : 0x0403_0201
        let expected16: UInt16 = reverse ? 0x0102 : 0x0201
        #expect(input.loadLittleEndian(as: UInt64.self, byteOrder: byteOrder) == UInt64(littleEndian: expected64))
        #expect(
            UnsafeRawBufferPointer(rebasing: input.prefix(4)).loadLittleEndian(as: UInt32.self, byteOrder: byteOrder)
                == UInt32(littleEndian: expected32))
        #expect(
            UnsafeRawBufferPointer(rebasing: input.prefix(2)).loadLittleEndian(as: UInt16.self, byteOrder: byteOrder)
                == UInt16(littleEndian: expected16))
    }

    @Test(arguments: 0..<8)
    func loadsLittleEndianAtEveryByteOffset(offset: Int) {
        // An explicitly aligned allocation makes every offset reproducible;
        // Array/Data storage alignment otherwise varies by allocator and size.
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
        defer { storage.deallocate() }
        let bytes = UnsafeMutableRawBufferPointer(start: storage, count: 16)
        for index in 0..<8 {
            bytes[offset + index] = UInt8(index + 1)
        }
        let input = UnsafeRawBufferPointer(start: storage.advanced(by: offset), count: 8)
        #expect(input.loadLittleEndian(as: UInt64.self) == 0x0807_0605_0403_0201)
        #expect(UnsafeRawBufferPointer(rebasing: input.prefix(4)).loadLittleEndian(as: UInt32.self) == 0x0403_0201)
        #expect(UnsafeRawBufferPointer(rebasing: input.prefix(2)).loadLittleEndian(as: UInt16.self) == 0x0201)
    }
}
