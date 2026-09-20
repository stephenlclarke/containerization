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

// A standalone Linux component test for static SDKs without Swift Testing.
// It runs in an isolated test process; alarm bounds even an old relay deadlock.
#if os(Linux)
import ContainerizationOS
import Foundation
import Synchronization

@testable import VminitdCore

enum Failure: Error {
    case blockingDestination
    case outputMismatch
    case producerFailed
    case closeLostBytes
    case descriptorLeak
    case unexpectedRegistration
    case terminalMismatch
    case relayRetained
}

func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
    var result = Data()
    while result.count < count {
        var event = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 1_000) > 0,
            let part = try handle.read(upToCount: count - result.count), !part.isEmpty
        else { throw Failure.terminalMismatch }
        result.append(part)
    }
    return result
}

func fill(_ fd: Int32) throws -> Data {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw Failure.blockingDestination
    }
    var bytes = [UInt8](repeating: 65, count: 4096)
    var expected = Data()
    for _ in 0..<1024 {
        let result = bytes.withUnsafeMutableBufferPointer { OSFile(fd: fd).write($0) }
        expected.append(contentsOf: bytes.prefix(result.wrote))
        if result.action == .again { return expected }
        guard result.action == .success else { throw Failure.producerFailed }
    }
    throw Failure.producerFailed
}

func closeDrainsPendingOutput() throws {
    let input = Pipe()
    let output = Pipe()
    var expected = try fill(output.fileHandleForWriting.fileDescriptor)
    let suffix = Data("pending-after-close".utf8)
    expected.append(suffix)
    let relay = IOPair(
        readFrom: input.fileHandleForReading, writeTo: output.fileHandleForWriting, reason: "close drain"
    )
    try relay.relay()
    try input.fileHandleForWriting.write(contentsOf: suffix)
    // Keep the producer open: close must drain available input without waiting
    // for another readable edge, then complete when output becomes writable.
    relay.close()
    guard try output.fileHandleForReading.readToEnd() == expected else { throw Failure.closeLostBytes }
    relay.close()
    try input.fileHandleForWriting.close()
}

final class InvalidIO: IOCloser {
    let closes = Mutex(0)
    var fileDescriptor: Int32 { -1 }
    func close() { closes.withLock { $0 += 1 } }
}

func descriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
}

func registrationFailureClosesOwnership() throws {
    // Initialize supervisor once before measuring its persistent descriptors.
    _ = ProcessSupervisor.default
    let before = try descriptorCount()
    for mode in 0..<3 {
        let input = Pipe()
        let output = Pipe()
        let invalid = InvalidIO()
        let regular = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        let relay = IOPair(
            readFrom: mode == 2 ? invalid : input.fileHandleForReading,
            writeTo: mode == 0 ? invalid : (mode == 1 ? regular : output.fileHandleForWriting),
            reason: "registration failure"
        )
        do {
            try relay.relay()
            throw Failure.unexpectedRegistration
        } catch is POSIXError {
            // Invalid destination: duplicate fails. Regular file: epoll add
            // fails. Invalid source: writer registration must be rolled back.
        }
        let unrelated = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        relay.close()
        relay.close()
        guard fcntl(unrelated.fileDescriptor, F_GETFD) >= 0,
            mode == 1 || invalid.closes.withLock({ $0 }) == 1
        else { throw Failure.descriptorLeak }
        try unrelated.close()
        try? regular.close()
        try? input.fileHandleForReading.close()
        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
    guard try descriptorCount() == before else { throw Failure.descriptorLeak }
}

func terminalSharedDescriptor() throws {
    let (parent, child) = try Terminal.create()
    try child.setraw()
    defer { try? child.close() }
    let input = Pipe()
    let output = Pipe()
    let stdout = IOPair(readFrom: parent, writeTo: output.fileHandleForWriting, reason: "PTY stdout")
    let stdin = IOPair(readFrom: input.fileHandleForReading, writeTo: UnownedIOCloser(parent), reason: "PTY stdin")
    try stdout.relay(ignoreHup: true)
    try stdin.relay(ignoreHup: true)
    defer {
        stdout.close()
        stdin.close()
    }
    let inbound = Data("input-marker".utf8)
    let outbound = Data("output-marker".utf8)
    try input.fileHandleForWriting.write(contentsOf: inbound)
    guard try readExactly(child.handle, count: inbound.count) == inbound else { throw Failure.terminalMismatch }
    try child.write(outbound)
    guard try readExactly(output.fileHandleForReading, count: outbound.count) == outbound else {
        throw Failure.terminalMismatch
    }
    try input.fileHandleForWriting.close()
    stdin.close()
    // Closing stdin must not own or replace the shared master read handler.
    try child.write(outbound)
    guard try readExactly(output.fileHandleForReading, count: outbound.count) == outbound else {
        throw Failure.terminalMismatch
    }
    try child.close()
    stdout.close()
    guard try output.fileHandleForReading.readToEnd()?.isEmpty != false else { throw Failure.terminalMismatch }
}

func terminalHangupReleasesPendingInput() throws {
    let (parent, child) = try Terminal.create()
    try child.setraw()
    defer { try? parent.close() }
    _ = try fill(parent.handle.fileDescriptor)
    let input = Pipe()
    var relay: IOPair? = IOPair(
        readFrom: input.fileHandleForReading, writeTo: UnownedIOCloser(parent), reason: "PTY pending hangup"
    )
    let released = { [weak relay] in relay == nil }
    try relay?.relay(ignoreHup: true)
    try input.fileHandleForWriting.write(contentsOf: Data("pending-input".utf8))
    relay?.close()
    try child.close()
    // Assert relay ownership/liveness, not a specific write errno after a PTY
    // hangup: the kernel can still accept data in its terminal input buffer.
    relay?.close()
    relay = nil
    // A callback already taken by the epoll thread can briefly retain self.
    for _ in 0..<100 where !released() { Thread.sleep(forTimeInterval: 0.001) }
    guard released() else { throw Failure.relayRetained }
    try input.fileHandleForWriting.close()
}

func runEdgeCases() throws {
    try closeDrainsPendingOutput()
    try registrationFailureClosesOwnership()
    try terminalSharedDescriptor()
    try terminalHangupReleasesPendingInput()
    print("PASS close drain, registration rollback, repeated close, shared PTY and pending-input hangup")
}

func terminalAttachmentFailureClosesParent() throws {
    let (parent, child) = try Terminal.create()
    defer { try? child.close() }
    let descriptor = parent.handle.fileDescriptor
    let invalid = InvalidIO()
    let relay = IOPair(readFrom: invalid, writeTo: UnownedIOCloser(parent), reason: "PTY attachment failure")
    do {
        try TerminalIO.startRelay(relay, parent: parent)
        throw Failure.unexpectedRegistration
    } catch is POSIXError {
        // Actual TerminalIO handoff: stdin registration fails before the
        // stdout relay takes ownership of the master terminal descriptor.
    }
    guard fcntl(descriptor, F_GETFD) == -1, errno == EBADF else { throw Failure.descriptorLeak }
    relay.close()
    guard invalid.closes.withLock({ $0 }) == 1 else { throw Failure.descriptorLeak }
    print("PASS terminal attachment failure closes untransferred parent")
}

func runRegression() throws {
    let input = Pipe()
    let output = Pipe()
    let relay = IOPair(
        readFrom: input.fileHandleForReading,
        writeTo: output.fileHandleForWriting,
        reason: "regression backpressure"
    )
    try relay.relay()
    defer { relay.close() }
    let flags = fcntl(output.fileHandleForWriting.fileDescriptor, F_GETFL)
    guard CommandLine.arguments.contains("--transfer-only") || (flags >= 0 && flags & O_NONBLOCK != 0) else {
        throw Failure.blockingDestination
    }

    let expected = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
    let sent = DispatchSemaphore(value: 0)
    Thread {
        do {
            try input.fileHandleForWriting.write(contentsOf: expected)
            try input.fileHandleForWriting.close()
            sent.signal()
        } catch {
            // The main thread cannot accept success without this signal.
            try? input.fileHandleForWriting.close()
        }
    }.start()

    Thread.sleep(forTimeInterval: 0.25)
    let markerInput = Pipe()
    let markerOutput = Pipe()
    let markerRelay = IOPair(
        readFrom: markerInput.fileHandleForReading,
        writeTo: markerOutput.fileHandleForWriting,
        reason: "regression independent stream"
    )
    try markerRelay.relay()
    defer { markerRelay.close() }
    let marker = Data("ready".utf8)
    try markerInput.fileHandleForWriting.write(contentsOf: marker)
    try markerInput.fileHandleForWriting.close()
    var event = pollfd(fd: markerOutput.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&event, 1, 1_000) > 0,
        try markerOutput.fileHandleForReading.read(upToCount: marker.count) == marker
    else {
        // An old relay can hold its mutex in a blocking write. Do not enter
        // deferred close on that path: this isolated process owns all fds.
        print("FAIL unrelatedStreamStalled")
        exit(1)
    }

    guard try output.fileHandleForReading.readToEnd() == expected else {
        throw Failure.outputMismatch
    }
    guard sent.wait(timeout: .now() + 1) == .success else {
        throw Failure.producerFailed
    }
    print("PASS nonblocking destination, independent stream, delayed 4 MiB output, exact bytes and EOF")
}

_ = signal(SIGPIPE, SIG_IGN)
_ = alarm(8)
do {
    if CommandLine.arguments.contains("--attachment-failure") {
        try terminalAttachmentFailureClosesParent()
    } else if CommandLine.arguments.contains("--edge-cases") {
        try runEdgeCases()
    } else {
        try runRegression()
    }
    _ = alarm(0)
} catch {
    print("FAIL \(error)")
    exit(1)
}
#else
fatalError("Run this regression in the isolated Linux test lane")
#endif
