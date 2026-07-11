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
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

public enum StubHTTPServerBinding: Sendable {
    case unixDomainSocket
    case tcp
}

public struct StubRequest: Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let body: Data
    public let headers: HTTPHeaders
}

public struct StubResponse: Sendable {
    public let status: HTTPResponseStatus
    public let body: Data
    public let headers: HTTPHeaders

    public init(
        status: HTTPResponseStatus,
        body: Data = .init(),
        headers: HTTPHeaders = [:]
    ) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public static func ok(_ body: Data = .init()) -> StubResponse {
        StubResponse(status: .ok, body: body)
    }

    public static func json<T: Encodable>(_ value: T) throws -> StubResponse {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        return StubResponse(status: .ok, body: data, headers: headers)
    }

    public static func status(_ status: HTTPResponseStatus, body: Data = .init()) -> StubResponse {
        StubResponse(status: status, body: body)
    }
}

public final class StubHTTPServer: Sendable {
    public let socketPath: String
    public let port: Int?

    private let channel: Channel
    private let requests: NIOLockedValueBox<[StubRequest]>

    public init(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        binding: StubHTTPServerBinding = .unixDomainSocket,
        handler: @escaping @Sendable (StubRequest) -> StubResponse
    ) async throws {
        let requests = NIOLockedValueBox<[StubRequest]>([])
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withPipeliningAssistance: false
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        StubRequestHandler(userHandler: handler, requests: requests)
                    )
                }
            }

        let channel: Channel
        let socketPath: String
        switch binding {
        case .unixDomainSocket:
            socketPath =
                FileManager.default.temporaryDirectory
                .appendingPathComponent("http-stub-\(UUID().uuidString).sock")
                .path
            channel =
                try await bootstrap
                .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true)
                .get()
        case .tcp:
            socketPath = ""
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        }

        self.socketPath = socketPath
        self.port = channel.localAddress?.port
        self.channel = channel
        self.requests = requests
    }

    public func shutdown() async throws {
        try await channel.close().get()
        if !socketPath.isEmpty {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    public func recordedRequests() -> [StubRequest] {
        requests.withLockedValue { $0 }
    }
}

private final class StubRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let userHandler: @Sendable (StubRequest) -> StubResponse
    private let requests: NIOLockedValueBox<[StubRequest]>
    private var pendingMethod: HTTPMethod?
    private var pendingURI: String?
    private var pendingHeaders: HTTPHeaders = [:]
    private var pendingBody: [UInt8] = []

    init(
        userHandler: @escaping @Sendable (StubRequest) -> StubResponse,
        requests: NIOLockedValueBox<[StubRequest]>
    ) {
        self.userHandler = userHandler
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingMethod = head.method
            pendingURI = head.uri
            pendingHeaders = head.headers
            pendingBody = []
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                pendingBody.append(contentsOf: bytes)
            }
        case .end:
            guard let method = pendingMethod, let uri = pendingURI else {
                context.close(promise: nil)
                return
            }
            let request = StubRequest(
                method: method,
                uri: uri,
                body: Data(pendingBody),
                headers: pendingHeaders
            )
            requests.withLockedValue { $0.append(request) }
            writeResponse(context: context, response: userHandler(request))
        }
    }

    private func writeResponse(context: ChannelHandlerContext, response: StubResponse) {
        var headers = response.headers
        headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
        headers.replaceOrAdd(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
