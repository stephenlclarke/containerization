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

import AsyncHTTPClient
import ContainerizationError
import ContainerizationExtras
import Dispatch
import Foundation
import NIOCore
import NIOHTTP1
import TLDExtractSwift

private final class PublicSuffixExtractor: @unchecked Sendable {
    private let extractor: TLDExtract?

    init() {
        self.extractor = try? TLDExtract(useFrozenData: true)
    }

    func registrableDomain(_ host: String) -> String? {
        extractor?.parse(host)?.rootDomain?.lowercased()
    }
}

private let publicSuffixExtractor = PublicSuffixExtractor()

private final class TokenRequestCompletion<Response: Sendable>: @unchecked Sendable {
    typealias RequestCancellation = @Sendable (any Swift.Error) -> Void

    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<Response, any Swift.Error>?
    private var pending: (result: Result<Response, any Swift.Error>, cancelUnderlyingRequest: Bool)?
    private var watchdog: (any DispatchSourceTimer)?
    private var requestCancellation: RequestCancellation?

    func install(
        continuation: CheckedContinuation<Response, any Swift.Error>,
        watchdog: any DispatchSourceTimer,
        requestCancellation: @escaping RequestCancellation
    ) {
        lock.lock()
        guard completed else {
            self.continuation = continuation
            self.watchdog = watchdog
            self.requestCancellation = requestCancellation
            lock.unlock()
            return
        }
        let pending = self.pending
        self.pending = nil
        lock.unlock()

        watchdog.cancel()
        guard let pending else {
            return
        }
        if pending.cancelUnderlyingRequest, case .failure(let error) = pending.result {
            requestCancellation(error)
        }
        continuation.resume(with: pending.result)
    }

    @discardableResult
    func resume(with result: Result<Response, any Swift.Error>, cancelUnderlyingRequest: Bool = false) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        guard let continuation else {
            pending = (result, cancelUnderlyingRequest)
            lock.unlock()
            return true
        }
        let watchdog = self.watchdog
        self.watchdog = nil
        let requestCancellation = self.requestCancellation
        self.requestCancellation = nil
        self.continuation = nil
        lock.unlock()

        watchdog?.cancel()
        if cancelUnderlyingRequest, case .failure(let error) = result {
            requestCancellation?(error)
        }
        continuation.resume(with: result)
        return true
    }
}

struct TokenRequest: Sendable {
    public static let authenticateHeaderName = "WWW-Authenticate"

    /// The realm against which the token should be requested.
    let realm: String
    /// The name of the service which hosts the resource. Optional: the parameter is a Docker
    /// registry convention, not a requirement of RFC 6750, and some registries (notably Google
    /// Artifact Registry) omit it from their challenge entirely.
    let service: String?
    /// Whether to return a refresh token along with the bearer token.
    let offlineToken: Bool
    /// String identifying the client.
    let clientId: String
    /// The resource in question, formatted as one of the space-delimited entries from the scope parameters from the WWW-Authenticate header shown above.
    let scope: String?

    init(
        realm: String,
        service: String?,
        clientId: String,
        scope: String?,
        offlineToken: Bool = false
    ) {
        self.realm = realm
        self.service = service
        self.offlineToken = offlineToken
        self.clientId = clientId
        self.scope = scope
    }
}

struct TokenResponse: Codable, Hashable, Sendable {
    /// An opaque Bearer token that clients should supply to subsequent requests in the Authorization header.
    let token: String?
    /// For compatibility with OAuth 2.0, we will also accept token under the name access_token.
    /// At least one of these fields must be specified, but both may also appear (for compatibility with older clients).
    /// When both are specified, they should be equivalent; if they differ the client's choice is undefined.
    let accessToken: String?
    ///  The duration in seconds since the token was issued that it will remain valid.
    ///  When omitted, this defaults to 60 seconds.
    let expiresIn: UInt?
    /// The RFC3339-serialized UTC standard time at which a given token was issued.
    /// If issued_at is omitted, the expiration is from when the token exchange completed.
    let issuedAt: String?
    /// Token which can be used to get additional access tokens for the same subject with different scopes.
    /// This token should be kept secure by the client and only sent to the authorization server which issues bearer tokens.
    /// This field will only be set when `offline_token=true` is provided in the request.
    let refreshToken: String?

    var scope: String?

    private enum CodingKeys: String, CodingKey {
        case token = "token"
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case issuedAt = "issued_at"
        case refreshToken = "refresh_token"
    }

    func getToken() -> String? {
        if let t = token ?? accessToken {
            return "Bearer \(t)"
        }
        return nil
    }

}

struct AuthenticateChallenge: Equatable {
    let type: String
    let realm: String?
    let service: String?
    let scope: String?
    let error: String?

    init(type: String, realm: String?, service: String?, scope: String?, error: String?) {
        self.type = type
        self.realm = realm
        self.service = service
        self.scope = scope
        self.error = error
    }

    init(type: String, values: [String: String]) {
        self.type = type
        self.realm = values["realm"]
        self.service = values["service"]
        self.scope = values["scope"]
        self.error = values["error"]
    }
}

extension RegistryClient {
    /// Fetch an auto token for all subsequent HTTP requests
    /// See https://docs.docker.com/registry/spec/auth/token/
    internal func fetchToken(request: TokenRequest) async throws -> TokenResponse {
        guard var components = URLComponents(string: request.realm) else {
            throw ContainerizationError(.invalidArgument, message: "cannot create URL from \(request.realm)")
        }
        try validateRealm(components)
        components.queryItems = [
            URLQueryItem(name: "client_id", value: request.clientId)
        ]
        if let service = request.service {
            components.queryItems?.append(URLQueryItem(name: "service", value: service))
        }
        var scope = ""
        if let reqScope = request.scope {
            scope = reqScope
            components.queryItems?.append(URLQueryItem(name: "scope", value: reqScope))
        }

        if request.offlineToken {
            components.queryItems?.append(URLQueryItem(name: "offline_token", value: "true"))
        }
        guard let url = components.url?.absoluteString else {
            throw ContainerizationError(.invalidArgument, message: "invalid url \(components.path)")
        }

        var tokenHeaders = HTTPHeaders()
        tokenHeaders.add(name: "User-Agent", value: clientID)
        if let credentials = try await authentication?.token() {
            tokenHeaders.add(name: "Authorization", value: credentials)
        }
        let tokenHTTPRequest = try HTTPClient.Request(url: url, headers: tokenHeaders)
        let responseAccumulator = ResponseAccumulator(
            request: tokenHTTPRequest,
            maxBodySize: self.bufferSize
        )
        // Authorization responses are small control-plane documents. Bound the complete
        // exchange as well as socket inactivity so a server that sends headers (or trickles
        // bytes) cannot hold the token path open indefinitely.
        let requestTask = tokenClient.execute(
            request: tokenHTTPRequest,
            delegate: responseAccumulator
        )
        let completion = TokenRequestCompletion<HTTPClient.Response>()
        let httpResponse: HTTPClient.Response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Keep the deadline off Swift's cooperative executor: callers may saturate it
                // with blocking I/O, but that must not prevent an authorization timeout.
                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                let timeoutNanoseconds = max(0, Int(clamping: tokenRequestTimeout.nanoseconds))
                watchdog.schedule(deadline: .now() + .nanoseconds(timeoutNanoseconds))
                watchdog.setEventHandler { [weak completion] in
                    completion?.resume(with: .failure(HTTPClientError.deadlineExceeded), cancelUnderlyingRequest: true)
                }
                watchdog.resume()
                completion.install(
                    continuation: continuation,
                    watchdog: watchdog,
                    requestCancellation: { error in requestTask.fail(reason: error) }
                )
                requestTask.futureResult.whenComplete { result in
                    completion.resume(with: result)
                }
            }
        } onCancel: {
            completion.resume(with: .failure(CancellationError()), cancelUnderlyingRequest: true)
        }

        guard !(300..<400).contains(httpResponse.status.code) else {
            throw Error.insecureCredentialExchange(message: "authorization server \(request.realm) redirected the token request")
        }
        guard httpResponse.headers[TokenRequest.authenticateHeaderName].isEmpty else {
            throw Error.insecureCredentialExchange(message: "authorization server \(request.realm) issued its own authentication challenge")
        }
        guard httpResponse.status == .ok else {
            let reason = ErrorResponse.fromResponseBody(httpResponse.body)?.jsonString
            throw Error.invalidStatus(url: url, httpResponse.status, reason: reason)
        }

        guard let body = httpResponse.body else {
            throw ContainerizationError(.internalError, message: "authorization server returned no token response body")
        }
        var response = try JSONDecoder().decode(TokenResponse.self, from: Data(body.readableBytesView))
        response.scope = scope
        return response
    }

    /// Credentials and bearer tokens are only ever exchanged with an authorization server that
    /// the registry itself demonstrably controls, over TLS.
    internal func validateRealm(_ realm: URLComponents) throws {
        guard let registryHost = base.host, let realmHost = realm.host else {
            throw Error.insecureCredentialExchange(message: "cannot determine registry or authorization server host")
        }
        guard base.scheme == "https", realm.scheme == "https" else {
            throw Error.insecureCredentialExchange(message: "token exchange between \(registryHost) and \(realmHost) requires https on both endpoints")
        }

        let registryDomain = Self.registrableDomain(registryHost)
        let realmDomain = Self.registrableDomain(realmHost)
        if registryDomain != nil || realmDomain != nil {
            guard let registryDomain, let realmDomain, registryDomain == realmDomain else {
                throw Error.insecureCredentialExchange(message: "authorization server \(realmHost) is not in the same registrable domain as registry \(registryHost)")
            }
            return
        }

        guard registryHost.lowercased() == realmHost.lowercased(), base.port ?? 443 == realm.port ?? 443 else {
            throw Error.insecureCredentialExchange(message: "authorization server \(realmHost) does not match registry \(registryHost)")
        }
    }

    /// The public-suffix-aware registrable domain of a fully qualified host name, or `nil` if the
    /// host is unqualified, an IP literal, or cannot be parsed using the bundled suffix snapshot.
    private static func registrableDomain(_ host: String) -> String? {
        if host.contains(":") || (try? IPv4Address(host)) != nil {
            return nil
        }
        return publicSuffixExtractor.registrableDomain(host)
    }

    internal func createTokenRequest(parsing authenticateHeaders: [String]) throws -> TokenRequest {
        guard base.scheme == "https" else {
            throw Error.insecureCredentialExchange(message: "registry \(host()) requested authentication over an insecure connection")
        }
        let parsedHeaders = Self.parseWWWAuthenticateHeaders(headers: authenticateHeaders)
        return try createTokenRequest(from: parsedHeaders)
    }

    internal func createTokenRequest(from parsedHeaders: [AuthenticateChallenge]) throws -> TokenRequest {
        let bearerChallenge = parsedHeaders.first { $0.type.caseInsensitiveCompare("Bearer") == .orderedSame }
        guard let bearerChallenge else {
            throw ContainerizationError(.invalidArgument, message: "missing Bearer challenge in \(TokenRequest.authenticateHeaderName) header")
        }
        guard let realm = bearerChallenge.realm else {
            throw ContainerizationError(.invalidArgument, message: "cannot parse realm from \(TokenRequest.authenticateHeaderName) header")
        }
        let scope = bearerChallenge.scope
        let tokenRequest = TokenRequest(realm: realm, service: bearerChallenge.service, clientId: self.clientID, scope: scope)
        return tokenRequest
    }

    internal static func authenticationFailureReason(authentication: Authentication?, challenges: [AuthenticateChallenge]) -> String? {
        guard authentication is BasicAuthentication else {
            return nil
        }
        let hasBearerChallenge = challenges.contains { $0.type.caseInsensitiveCompare("Bearer") == .orderedSame }
        guard !hasBearerChallenge else {
            return nil
        }
        let hasBasicChallenge = challenges.contains { $0.type.caseInsensitiveCompare("Basic") == .orderedSame }
        guard hasBasicChallenge else {
            return nil
        }
        return "access denied or wrong credentials"
    }

    internal static func parseWWWAuthenticateHeaders(headers: [String]) -> [AuthenticateChallenge] {
        var parsed: [String: [String: String]] = [:]
        for challenge in headers {
            let trimmedChallenge = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmedChallenge.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            guard let scheme = parts.first else {
                continue
            }
            var params: [String: String] = [:]
            let header = String(parts[1])
            let pattern = #"(\w+)="([^"]+)"#
            let regex = try! NSRegularExpression(pattern: pattern, options: [])
            let matches = regex.matches(in: header, options: [], range: NSRange(header.startIndex..., in: header))
            for match in matches {
                if let keyRange = Range(match.range(at: 1), in: header),
                    let valueRange = Range(match.range(at: 2), in: header)
                {
                    let key = String(header[keyRange])
                    let value = String(header[valueRange])
                    params[key] = value
                }
            }
            parsed[String(scheme)] = params
        }
        var parsedChallenges: [AuthenticateChallenge] = []
        for (type, values) in parsed {
            parsedChallenges.append(.init(type: type, values: values))
        }
        return parsedChallenges
    }
}
