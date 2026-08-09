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

import Containerization
import Foundation
import Logging
import NIOCore
import NIOPosix

final class GuestDNSProxy: Sendable {
    private static let maximumConcurrentRequests = 64
    private static let queryTimeout = Duration.seconds(3)

    private let group: any EventLoopGroup
    private let log: Logger

    init(group: any EventLoopGroup, log: Logger) {
        self.group = group
        self.log = log
    }

    func run() async throws {
        let channel = try await DatagramBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: DNSProxyProtocol.guestAddress, port: DNSProxyProtocol.guestPort)
            .flatMapThrowing { channel in
                try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        inboundType: AddressedEnvelope<ByteBuffer>.self,
                        outboundType: AddressedEnvelope<ByteBuffer>.self
                    )
                )
            }
            .get()

        log.info(
            "guest DNS proxy listening",
            metadata: [
                "host": "\(DNSProxyProtocol.guestAddress)",
                "port": "\(DNSProxyProtocol.guestPort)",
                "vsockPort": "\(DNSProxyProtocol.hostVsockPort)",
            ])

        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { requests in
                var activeRequests = 0
                for try await var packet in inbound {
                    guard packet.data.readableBytes <= DNSProxyProtocol.maximumMessageLength,
                        let bytes = packet.data.readBytes(length: packet.data.readableBytes)
                    else {
                        log.warning("dropping oversized guest DNS request")
                        continue
                    }

                    if activeRequests == Self.maximumConcurrentRequests {
                        _ = try await requests.next()
                        activeRequests -= 1
                    }

                    let remoteAddress = packet.remoteAddress
                    requests.addTask {
                        do {
                            let response = try await self.queryHost(Data(bytes))
                            try await outbound.write(
                                AddressedEnvelope(
                                    remoteAddress: remoteAddress,
                                    data: ByteBuffer(bytes: response)
                                )
                            )
                        } catch is CancellationError {
                            return
                        } catch {
                            self.log.debug(
                                "guest DNS request failed",
                                metadata: ["error": "\(error)"]
                            )
                        }
                    }
                    activeRequests += 1
                }
                try await requests.waitForAll()
            }
        }
    }

    private func queryHost(_ query: Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { tasks in
            tasks.addTask {
                try await self.queryHostOnce(query)
            }
            tasks.addTask {
                try await Task.sleep(for: Self.queryTimeout)
                throw ProxyError.timeout
            }

            guard let response = try await tasks.next() else {
                throw ProxyError.unexpectedEndOfStream
            }
            tasks.cancelAll()
            return response
        }
    }

    private func queryHostOnce(_ query: Data) async throws -> Data {
        let request = try DNSProxyProtocol.encode(query)
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(3))
            .connect(
                to: VsockAddress(
                    cid: .host,
                    port: VsockAddress.Port(rawValue: DNSProxyProtocol.hostVsockPort)
                )
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel
                    )
                }
            }

        return try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(bytes: request))

            var response = Data()
            for try await var chunk in inbound {
                guard let bytes = chunk.readBytes(length: chunk.readableBytes) else {
                    continue
                }
                response.append(contentsOf: bytes)
                guard response.count <= DNSProxyProtocol.maximumMessageLength + MemoryLayout<UInt16>.size else {
                    throw ProxyError.responseTooLarge
                }
                if let frame = try DNSProxyProtocol.decode(response) {
                    guard frame.consumedBytes == response.count else {
                        throw ProxyError.trailingResponseData
                    }
                    return frame.message
                }
            }
            throw ProxyError.unexpectedEndOfStream
        }
    }
}

private enum ProxyError: Error {
    case responseTooLarge
    case timeout
    case trailingResponseData
    case unexpectedEndOfStream
}

#endif
