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

private final class TokenTaskWaiter<Response: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<Response, any Swift.Error>?
    private var pending: Result<Response, any Swift.Error>?

    func install(_ continuation: CheckedContinuation<Response, any Swift.Error>) {
        lock.lock()
        guard completed else {
            self.continuation = continuation
            lock.unlock()
            return
        }
        let pending = self.pending
        self.pending = nil
        lock.unlock()

        if let pending {
            continuation.resume(with: pending)
        }
    }

    func resume(with result: Result<Response, any Swift.Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        continuation.resume(with: result)
    }
}

actor RegistryTokenCache {
    private struct Key: Hashable {
        let realm: String
        let service: String?
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

    private struct InFlight {
        let id: UUID
        let task: Task<TokenResponse, any Swift.Error>
    }

    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: InFlight] = [:]

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

        if let inFlight = inFlight[key] {
            return try await Self.value(of: inFlight.task)
        }

        let id = UUID()
        let task = Task { try await fetch() }
        inFlight[key] = InFlight(id: id, task: task)
        Task {
            let result = await task.result
            guard self.inFlight[key]?.id == id else {
                return
            }
            self.inFlight[key] = nil
            guard case .success(let response) = result else {
                return
            }
            entries[key] = Entry(
                response: response,
                expiresAt: expirationDate(for: response, receivedAt: now()))
        }
        return try await Self.value(of: task)
    }

    /// Awaits a shared fetch without making one caller's cancellation cancel the
    /// request on behalf of every waiter. The caller still resumes immediately;
    /// the shared task continues and populates the cache when it completes.
    private nonisolated static func value(
        of task: Task<TokenResponse, any Swift.Error>
    ) async throws -> TokenResponse {
        let waiter = TokenTaskWaiter<TokenResponse>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    waiter.resume(with: await task.result)
                }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
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
