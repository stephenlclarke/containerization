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

//

import ContainerizationError
import ContainerizationIO
import Crypto
import Foundation
import HTTPTestSupport
import NIO
import NIOHTTP1
import Synchronization
import Testing

@testable import ContainerizationOCI

struct OCIClientTests: ~Copyable {
    private var contentPath: URL
    private let fileManager = FileManager.default
    private var encoder = JSONEncoder()

    init() async throws {
        let testDir = fileManager.uniqueTemporaryDirectory()
        let contentPath = testDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: contentPath, withIntermediateDirectories: true)
        self.contentPath = contentPath

        encoder.outputFormatting = .prettyPrinted
    }

    deinit {
        try? fileManager.removeItem(at: contentPath)
    }

    private static var arch: String? {
        var uts = utsname()
        let result = uname(&uts)
        guard result == EXIT_SUCCESS else {
            return nil
        }

        let machine = Data(bytes: &uts.machine, count: 256)
        guard let arch = String(bytes: machine, encoding: .utf8) else {
            return nil
        }

        switch arch.lowercased().trimmingCharacters(in: .controlCharacters) {
        case "arm64":
            return "arm64"
        default:
            return "amd64"
        }
    }

    @Test(.enabled(if: hasRegistryCredentials))
    func fetchToken() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        let request = TokenRequest(realm: "https://ghcr.io/token", service: "ghcr.io", clientId: "tests", scope: nil)
        let response = try await client.fetchToken(request: request)
        #expect(response.getToken() != nil)
    }

    @Test(arguments: [
        "registry-1.docker.io",
        "public.ecr.aws",
        "registry.k8s.io",
        "mcr.microsoft.com",
    ])
    func ping(host: String) async throws {
        let client = RegistryClient(host: host)
        try await client.ping()
    }

    @Test func pingWithInvalidCredentials() async throws {
        let authentication = BasicAuthentication(username: "foo", password: "bar")
        let client = RegistryClient(host: "ghcr.io", authentication: authentication)
        let error = await #expect(throws: RegistryClient.Error.self) { try await client.ping() }
        guard case .invalidStatus(_, let status, let reason) = error else {
            throw error!
        }
        #expect(status == .unauthorized)
        #expect(reason == "access denied or wrong credentials")
    }

    @Test(.enabled(if: hasRegistryCredentials))
    func pingWithCredentials() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        try await client.ping()
    }

    @Test func resolve() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        #expect(descriptor.mediaType == MediaTypes.dockerManifest)
        #expect(descriptor.size != 0)
        #expect(!descriptor.digest.isEmpty)
    }

    @Test func resolveSha() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(
            name: "apple/containerization/dockermanifestimage", tag: "sha256:c8d344d228b7d9a702a95227438ec0d71f953a9a483e28ffabc5704f70d2b61e")
        let namedDescriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        #expect(descriptor == namedDescriptor)
        #expect(descriptor.mediaType == MediaTypes.dockerManifest)
        #expect(descriptor.size != 0)
        #expect(!descriptor.digest.isEmpty)
    }

    @Test func fetchManifest() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.layers.count == 1)
    }

    @Test func fetchManifestAsData() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifestData = try await client.fetchData(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        let checksum = SHA256.hash(data: manifestData)
        #expect(descriptor.digest == checksum.digest)
    }

    @Test func fetchConfig() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        let image: Image = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: manifest.config)
        // This is an empty image -- check that the image label is present in the image config
        #expect(image.config?.labels?["org.opencontainers.image.source"] == "https://github.com/apple/containerization")
        #expect(image.rootfs.diffIDs.count == 1)
    }

    @Test func fetchBlob() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        var called = false
        var done = false
        try await client.fetchBlob(name: "apple/containerization/dockermanifestimage", descriptor: manifest.layers.first!) { (expected, body) in
            called = true
            #expect(expected != 0)
            var received = 0
            for try await buffer in body {
                received += buffer.readableBytes
                if received == expected {
                    done = true
                }
            }
        }
        #expect(called)
        #expect(done)
    }

    @Test(.disabled("External users cannot push images, disable while we find a better solution"))
    func pushIndex() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        let indexDescriptor = try await client.resolve(name: "apple/containerization/emptyimage", tag: "0.0.1")
        let index: Index = try await client.fetch(name: "apple/containerization/emptyimage", descriptor: indexDescriptor)

        let platform = Platform(arch: "amd64", os: "linux")

        var manifestDescriptor: Descriptor?
        for m in index.manifests where m.platform == platform {
            manifestDescriptor = m
            break
        }

        #expect(manifestDescriptor != nil)

        let manifest: Manifest = try await client.fetch(name: "apple/containerization/emptyimage", descriptor: manifestDescriptor!)
        let imgConfig: Image = try await client.fetch(name: "apple/containerization/emptyimage", descriptor: manifest.config)

        let layer = try #require(manifest.layers.first)
        let blobPath = contentPath.appendingPathComponent(layer.digest)
        let outputStream = OutputStream(toFileAtPath: blobPath.path, append: false)
        #expect(outputStream != nil)

        try await outputStream!.withThrowingOpeningStream {
            try await client.fetchBlob(name: "apple/containerization/emptyimage", descriptor: layer) { (expected, body) in
                var received: Int64 = 0
                for try await buffer in body {
                    received += Int64(buffer.readableBytes)

                    buffer.withUnsafeReadableBytes { pointer in
                        let unsafeBufferPointer = pointer.bindMemory(to: UInt8.self)
                        if let addr = unsafeBufferPointer.baseAddress {
                            _ = outputStream!.write(addr, maxLength: buffer.readableBytes)
                        }
                    }
                }

                #expect(received == expected)
            }
        }

        let name = "apple/test-images/image-push"
        let ref = "latest"

        // Push the layer first.
        do {
            let content = try LocalContent(path: blobPath)
            let generator = {
                let stream = try ReadStream(url: content.path)
                try stream.reset()
                return stream.stream
            }
            try await client.push(name: name, ref: ref, descriptor: layer, streamGenerator: generator, progress: nil)
        } catch let err as ContainerizationError {
            guard err.code == .exists else {
                throw err
            }
        }

        // Push the image configuration.
        var imgConfigDesc: Descriptor?
        do {
            imgConfigDesc = try await self.pushDescriptor(
                client: client,
                name: name,
                ref: ref,
                content: imgConfig,
                baseDescriptor: manifest.config
            )
        } catch let err as ContainerizationError {
            guard err.code != .exists else {
                return
            }
            throw err
        }

        // Push the image manifest.
        let newManifest = Manifest(
            schemaVersion: manifest.schemaVersion,
            mediaType: manifest.mediaType!,
            config: imgConfigDesc!,
            layers: manifest.layers,
            annotations: manifest.annotations
        )
        let manifestDesc = try await self.pushDescriptor(
            client: client,
            name: name,
            ref: ref,
            content: newManifest,
            baseDescriptor: manifestDescriptor!
        )

        // Push the index.
        let newIndex = Index(
            schemaVersion: index.schemaVersion,
            mediaType: index.mediaType,
            manifests: [manifestDesc],
            annotations: index.annotations
        )
        try await self.pushDescriptor(
            client: client,
            name: name,
            ref: ref,
            content: newIndex,
            baseDescriptor: indexDescriptor
        )
    }

    @Test func resolveWithRetry() async throws {
        let counter = Mutex(0)
        let client = RegistryClient(
            host: "ghcr.io",
            retryOptions: RetryOptions(
                maxRetries: 3,
                retryInterval: 500_000_000,
                shouldRetry: ({ response in
                    if response.status == .notFound {
                        counter.withLock { $0 += 1 }
                        return true
                    }
                    return false
                })
            )
        )
        do {
            _ = try await client.resolve(name: "containerization/not-exists", tag: "foo")
        } catch {
            #expect(counter.withLock { $0 } <= 3)
        }
    }

    @Test func blobPushRestartsWithFreshSessionAfterECR416() async throws {
        let digest = "sha256:0123456789abcdef"
        let payload = Data("registry-blob".utf8)
        let nextSession = Mutex(0)
        let server = try await StubHTTPServer(binding: .tcp) { request in
            switch request.method {
            case .HEAD:
                return StubResponse.status(.notFound)
            case .POST:
                let session = nextSession.withLock { value in
                    value += 1
                    return value
                }
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/v2/example/blobs/uploads/session-\(session)")
                return StubResponse(status: .accepted, headers: headers)
            case .PUT where request.uri.contains("session-1"):
                let body = Data(#"{"errors":[{"code":"BLOB_UPLOAD_INVALID","message":"stale upload"}]}"#.utf8)
                return StubResponse.status(.rangeNotSatisfiable, body: body)
            case .PUT:
                var headers = HTTPHeaders()
                headers.add(name: "Docker-Content-Digest", value: digest)
                return StubResponse(status: .created, headers: headers)
            default:
                return StubResponse.status(.badRequest)
            }
        }
        defer { Task { try? await server.shutdown() } }
        let port = try #require(server.port)

        let client = RegistryClient(
            host: "127.0.0.1",
            scheme: "http",
            port: port,
            retryOptions: RetryOptions(maxRetries: 1, retryInterval: 0)
        )
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageLayer,
            digest: digest,
            size: Int64(payload.count)
        )

        try await client.push(
            name: "example",
            ref: "latest",
            descriptor: descriptor,
            streamGenerator: { Self.stream(payload) },
            progress: nil
        )

        let requests = server.recordedRequests()
        let posts = requests.filter { $0.method == .POST }
        let puts = requests.filter { $0.method == .PUT }
        #expect(posts.count == 2)
        #expect(puts.map(\.uri).contains { $0.contains("session-1") })
        #expect(puts.map(\.uri).contains { $0.contains("session-2") })
        #expect(puts.allSatisfy { $0.body == payload })
    }

    @Test func blobPushDoesNotInventRetries() async throws {
        let digest = "sha256:fedcba9876543210"
        let payload = Data("registry-blob".utf8)
        let server = try await StubHTTPServer(binding: .tcp) { request in
            switch request.method {
            case .HEAD:
                return StubResponse.status(.notFound)
            case .POST:
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/v2/example/blobs/uploads/session-1")
                return StubResponse(status: .accepted, headers: headers)
            case .PUT:
                let body = Data(#"{"errors":[{"code":"BLOB_UPLOAD_INVALID","message":"stale upload"}]}"#.utf8)
                return StubResponse.status(.rangeNotSatisfiable, body: body)
            default:
                return StubResponse.status(.badRequest)
            }
        }
        defer { Task { try? await server.shutdown() } }
        let port = try #require(server.port)

        let client = RegistryClient(host: "127.0.0.1", scheme: "http", port: port)
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageLayer,
            digest: digest,
            size: Int64(payload.count)
        )

        let error = await #expect(throws: RegistryClient.Error.self) {
            try await client.push(
                name: "example",
                ref: "latest",
                descriptor: descriptor,
                streamGenerator: { Self.stream(payload) },
                progress: nil
            )
        }
        #expect(error != nil)

        let requests = server.recordedRequests()
        #expect(requests.filter { $0.method == .POST }.count == 1)
        #expect(requests.filter { $0.method == .PUT }.count == 1)
    }

    @Test func blobPushRestartsWithFreshSessionAfterServerFailure() async throws {
        let digest = "sha256:1234567890abcdef"
        let payload = Data("registry-blob".utf8)
        let nextSession = Mutex(0)
        let server = try await StubHTTPServer(binding: .tcp) { request in
            switch request.method {
            case .HEAD:
                return StubResponse.status(.notFound)
            case .POST:
                let session = nextSession.withLock { value in
                    value += 1
                    return value
                }
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/v2/example/blobs/uploads/session-\(session)")
                return StubResponse(status: .accepted, headers: headers)
            case .PUT where request.uri.contains("session-1"):
                return StubResponse.status(.internalServerError)
            case .PUT:
                var headers = HTTPHeaders()
                headers.add(name: "Docker-Content-Digest", value: digest)
                return StubResponse(status: .created, headers: headers)
            default:
                return StubResponse.status(.badRequest)
            }
        }
        defer { Task { try? await server.shutdown() } }
        let port = try #require(server.port)

        let client = RegistryClient(
            host: "127.0.0.1",
            scheme: "http",
            port: port,
            retryOptions: RetryOptions(maxRetries: 1, retryInterval: 0)
        )
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageLayer,
            digest: digest,
            size: Int64(payload.count)
        )

        try await client.push(
            name: "example",
            ref: "latest",
            descriptor: descriptor,
            streamGenerator: { Self.stream(payload) },
            progress: nil
        )

        let requests = server.recordedRequests()
        #expect(requests.filter { $0.method == .POST }.count == 2)
        #expect(requests.filter { $0.method == .PUT }.count == 2)
    }

    @Test func blobPushDoesNotRestartForUnrelated416() async throws {
        let digest = "sha256:abcdef1234567890"
        let payload = Data("registry-blob".utf8)
        let server = try await StubHTTPServer(binding: .tcp) { request in
            switch request.method {
            case .HEAD:
                return StubResponse.status(.notFound)
            case .POST:
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/v2/example/blobs/uploads/session-1")
                return StubResponse(status: .accepted, headers: headers)
            case .PUT:
                let body = Data(#"{"errors":[{"code":"RANGE_INVALID","message":"bad range"}]}"#.utf8)
                return StubResponse.status(.rangeNotSatisfiable, body: body)
            default:
                return StubResponse.status(.badRequest)
            }
        }
        defer { Task { try? await server.shutdown() } }
        let port = try #require(server.port)

        let client = RegistryClient(
            host: "127.0.0.1",
            scheme: "http",
            port: port,
            retryOptions: RetryOptions(maxRetries: 1, retryInterval: 0)
        )
        let descriptor = Descriptor(
            mediaType: MediaTypes.imageLayer,
            digest: digest,
            size: Int64(payload.count)
        )

        let error = await #expect(throws: RegistryClient.Error.self) {
            try await client.push(
                name: "example",
                ref: "latest",
                descriptor: descriptor,
                streamGenerator: { Self.stream(payload) },
                progress: nil
            )
        }
        #expect(error != nil)

        let requests = server.recordedRequests()
        #expect(requests.filter { $0.method == .POST }.count == 1)
        #expect(requests.filter { $0.method == .PUT }.count == 1)
    }

    // MARK: private functions

    static var hasRegistryCredentials: Bool {
        authentication != nil
    }

    static var authentication: Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["REGISTRY_TOKEN"],
            let username = env["REGISTRY_USERNAME"]
        else {
            return nil
        }
        return BasicAuthentication(username: username, password: password)
    }

    private static func stream(_ data: Data) -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            continuation.yield(buffer)
            continuation.finish()
        }
    }

    @discardableResult
    private func pushDescriptor<T: Encodable>(
        client: RegistryClient,
        name: String,
        ref: String,
        content: T,
        baseDescriptor: Descriptor
    ) async throws -> Descriptor {
        let encoded = try self.encoder.encode(content)
        let digest = SHA256.hash(data: encoded)
        let descriptor = Descriptor(
            mediaType: baseDescriptor.mediaType,
            digest: digest.digest,
            size: Int64(encoded.count),
            urls: baseDescriptor.urls,
            annotations: baseDescriptor.annotations,
            platform: baseDescriptor.platform
        )
        let generator = {
            let stream = ReadStream(data: encoded)
            try stream.reset()
            return stream.stream
        }

        try await client.push(
            name: name,
            ref: ref,
            descriptor: descriptor,
            streamGenerator: generator,
            progress: nil
        )
        return descriptor
    }
}

extension OutputStream {
    fileprivate func withThrowingOpeningStream(_ closure: () async throws -> Void) async throws {
        self.open()
        defer { self.close() }

        try await closure()
    }
}

extension SHA256.Digest {
    fileprivate var digest: String {
        let parts = self.description.split(separator: ": ")
        return "sha256:\(parts[1])"
    }
}
