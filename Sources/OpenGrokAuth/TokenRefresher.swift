// TokenRefresher.swift
//
// Token refresh protocols and OIDC / external refresh implementations.

import Foundation
import OpenGrokHTTP

/// Why a token refresh is being requested.
public enum RefreshReason: String, Sendable, Equatable {
    /// Pre-request check. Return cached token if still valid.
    case preRequest
    /// Server returned 401/403. Must obtain a different token.
    case serverRejected
}

/// Outcome of a refresh attempt (data only; manager applies mutations).
public enum RefreshOutcome: Sendable {
    case success(GrokAuth)
    case permanentFailure(reason: RefreshTokenFailedReason, triedKey: String?)
    case transientFailure(message: String)
}

/// Capability to obtain a fresh credential from an authority.
public protocol TokenRefresher: Sendable {
    func refresh(reason: RefreshReason, current: GrokAuth?) async -> RefreshOutcome
}

/// OIDC refresh_token grant against a discovery / token endpoint.
public struct OIDCTokenRefresher: TokenRefresher {
    public var tokenEndpoint: URL
    public var clientID: String
    public var transport: any HTTPTransport
    public var issuer: String

    public init(
        tokenEndpoint: URL,
        clientID: String,
        issuer: String,
        transport: any HTTPTransport
    ) {
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.issuer = issuer
        self.transport = transport
    }

    public func refresh(reason: RefreshReason, current: GrokAuth?) async -> RefreshOutcome {
        guard let auth = current, let refreshToken = auth.refreshToken, !refreshToken.isEmpty else {
            return .transientFailure(message: "no refresh token")
        }
        let body = formURLEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        ]
        let request = HTTPRequest(
            method: .post,
            url: tokenEndpoint,
            headers: headers,
            body: Data(body.utf8),
            timeout: 30,
            idempotency: .nonIdempotent
        )
        do {
            let response = try await transport.send(request)
            if response.metadata.statusCode == 401 || response.metadata.statusCode == 400 {
                let code = oauthErrorCode(from: response.body)
                let reason = classifyTerminal(code: code)
                return .permanentFailure(reason: reason, triedKey: auth.key)
            }
            if !(200..<300).contains(response.metadata.statusCode) {
                return .transientFailure(
                    message: "token refresh HTTP \(response.metadata.statusCode)"
                )
            }
            guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let access = json["access_token"] as? String
            else {
                return .transientFailure(message: "malformed token response")
            }
            var next = auth
            next.key = access
            if let rt = json["refresh_token"] as? String, !rt.isEmpty {
                next.refreshToken = rt
            }
            if let expiresIn = json["expires_in"] as? Double
                ?? (json["expires_in"] as? Int).map(Double.init)
                ?? (json["expires_in"] as? NSNumber).map({ $0.doubleValue })
            {
                next.expiresAt = Date().addingTimeInterval(expiresIn)
            }
            next.createTime = Date()
            next.oidcIssuer = issuer
            next.oidcClientID = clientID
            next.authMode = .oidc
            next.carryUserProfile(from: auth)
            return .success(next)
        } catch is CancellationError {
            return .transientFailure(message: "cancelled")
        } catch {
            return .transientFailure(message: "network error")
        }
    }
}

/// External binary refresher. Runs an injectible command runner.
public struct ExternalTokenRefresher: TokenRefresher {
    public var command: String
    public var runner: @Sendable (String, Bool) async -> GrokAuth?

    public init(
        command: String,
        runner: @escaping @Sendable (String, Bool) async -> GrokAuth?
    ) {
        self.command = command
        self.runner = runner
    }

    public func refresh(reason: RefreshReason, current: GrokAuth?) async -> RefreshOutcome {
        if let auth = await runner(command, true) {
            var next = auth
            if let current {
                next.carryUserProfile(from: current)
            }
            return .success(next)
        }
        return .permanentFailure(reason: .other, triedKey: current?.key)
    }
}

/// Mock refresher for tests.
public struct MockTokenRefresher: TokenRefresher {
    public var outcome: RefreshOutcome
    public var callCountBox: CallCounter

    public init(outcome: RefreshOutcome, callCount: CallCounter = CallCounter()) {
        self.outcome = outcome
        self.callCountBox = callCount
    }

    public func refresh(reason: RefreshReason, current: GrokAuth?) async -> RefreshOutcome {
        callCountBox.increment()
        return outcome
    }
}

/// Thread-safe call counter for tests.
public final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    public init() {}
    public func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

func formURLEncoded(_ fields: [String: String]) -> String {
    fields.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        return "\(k)=\(v)"
    }
    .joined(separator: "&")
}

func oauthErrorCode(from body: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return nil
    }
    if let s = json["error"] as? String { return s }
    if let obj = json["error"] as? [String: Any], let code = obj["code"] as? String {
        return code
    }
    return json["code"] as? String
}

func classifyTerminal(code: String?) -> RefreshTokenFailedReason {
    switch code {
    case "invalid_grant", "refresh_token_expired", "refresh_token_reused",
         "refresh_token_invalidated":
        return .refreshTokenRejected
    case "invalid_client":
        return .clientRejected
    default:
        // Unrecognized terminal HTTP 400/401 is treated as permanent-other
        // for the middleware path; OIDC refresher maps unknown to permanent
        // only when status was 400/401.
        return .refreshTokenRejected
    }
}

/// Resolve which credential to send to the IdP.
public func resolveRefreshCredential(
    disk: GrokAuth?,
    expired: GrokAuth?,
    current: GrokAuth?,
    reason: RefreshReason
) -> GrokAuth? {
    if let disk, disk.refreshToken != nil { return disk }
    if let expired { return expired }
    if reason == .serverRejected { return current }
    return nil
}
