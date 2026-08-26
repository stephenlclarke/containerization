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

actor RegistryTokenCache {
    private struct Key: Hashable {
        let realm: String
        let service: String
        let scope: String?

        init(_ request: TokenRequest) {
            self.realm = request.realm
            self.service = request.service
            self.scope = request.scope
        }
    }

    private struct Entry {
        let response: TokenResponse
        let expiresAt: Date
    }

    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<TokenResponse, Error>] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func token(
        for request: TokenRequest,
        fetch: @escaping @Sendable () async throws -> TokenResponse
    ) async throws -> TokenResponse {
        let key = Key(request)
        let currentDate = now()
        if let entry = entries[key], currentDate < entry.expiresAt {
            return entry.response
        }
        entries[key] = nil

        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task { try await fetch() }
        inFlight[key] = task
        do {
            let response = try await task.value
            entries[key] = Entry(
                response: response,
                expiresAt: expirationDate(for: response, receivedAt: now()))
            inFlight[key] = nil
            return response
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private func expirationDate(for response: TokenResponse, receivedAt: Date) -> Date {
        let issuedAt: Date
        if let value = response.issuedAt, let parsed = parseIssuedAt(value) {
            issuedAt = parsed
        } else {
            issuedAt = receivedAt
        }
        return issuedAt.addingTimeInterval(TimeInterval(response.expiresIn ?? 60))
    }

    private func parseIssuedAt(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
