//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Synchronization
import Testing

@testable import ContainerizationOCI

private actor TokenFetcher {
    private(set) var count = 0

    func fetch(expiresIn: UInt, issuedAt: String? = nil, delay: Duration? = nil) async throws -> TokenResponse {
        count += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return TokenResponse(
            token: "token",
            accessToken: nil,
            expiresIn: expiresIn,
            issuedAt: issuedAt,
            refreshToken: nil)
    }
}

private enum TokenFetchError: Error {
    case failed
}

@Suite("Registry token cache")
struct RegistryTokenCacheTests {
    @Test func reusesTokenForTheSameChallenge() async throws {
        let fetcher = TokenFetcher()
        let cache = RegistryTokenCache()
        let request = Self.tokenRequest(scope: "repository:apple/container:pull")

        let first = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 60)
        }
        let second = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 60)
        }
        let fetchCount = await fetcher.count

        #expect(first == second)
        #expect(fetchCount == 1)
    }

    @Test func keepsTokensSeparatedByChallenge() async throws {
        let fetcher = TokenFetcher()
        let cache = RegistryTokenCache()

        _ = try await cache.token(for: Self.tokenRequest(scope: "repository:apple/container:pull")) {
            try await fetcher.fetch(expiresIn: 60)
        }
        _ = try await cache.token(for: Self.tokenRequest(scope: "repository:apple/container:push")) {
            try await fetcher.fetch(expiresIn: 60)
        }
        let fetchCount = await fetcher.count

        #expect(fetchCount == 2)
    }

    @Test func coalescesConcurrentTokenFetches() async throws {
        let fetcher = TokenFetcher()
        let cache = RegistryTokenCache()
        let request = Self.tokenRequest(scope: "repository:apple/container:pull")

        let results = try await withThrowingTaskGroup(of: TokenResponse.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.token(for: request) {
                        try await fetcher.fetch(expiresIn: 60, delay: .milliseconds(10))
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let fetchCount = await fetcher.count

        #expect(results.count == 8)
        #expect(fetchCount == 1)
    }

    @Test func refreshesExpiredTokens() async throws {
        let currentDate = Mutex(Date(timeIntervalSince1970: 1_000))
        let fetcher = TokenFetcher()
        let cache = RegistryTokenCache(now: { currentDate.withLock { $0 } })
        let request = Self.tokenRequest(scope: "repository:apple/container:pull")

        _ = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 10)
        }
        currentDate.withLock { $0.addTimeInterval(11) }
        _ = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 10)
        }
        let fetchCount = await fetcher.count

        #expect(fetchCount == 2)
    }

    @Test func respectsIssuedAtWithoutFractionalSeconds() async throws {
        let currentDate = Date(timeIntervalSince1970: 1_000)
        let fetcher = TokenFetcher()
        let cache = RegistryTokenCache(now: { currentDate })
        let request = Self.tokenRequest(scope: "repository:apple/container:pull")

        _ = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 10, issuedAt: "1970-01-01T00:16:00Z")
        }
        _ = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 60)
        }
        let fetchCount = await fetcher.count

        #expect(fetchCount == 2)
    }

    @Test func retriesAfterAFailedFetch() async throws {
        let fetcher = TokenFetcher()
        let cache = RegistryTokenCache()
        let request = Self.tokenRequest(scope: "repository:apple/container:pull")

        do {
            _ = try await cache.token(for: request) {
                throw TokenFetchError.failed
            }
            Issue.record("expected token fetch to fail")
        } catch is TokenFetchError {
        }

        _ = try await cache.token(for: request) {
            try await fetcher.fetch(expiresIn: 60)
        }
        let fetchCount = await fetcher.count

        #expect(fetchCount == 1)
    }

    private static func tokenRequest(scope: String?) -> TokenRequest {
        TokenRequest(
            realm: "https://example.com/token",
            service: "example.com",
            clientId: "test",
            scope: scope)
    }

}
