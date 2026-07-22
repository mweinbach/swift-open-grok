// DeviceCode.swift
//
// RFC 8628 Device Authorization Grant (CLI side) with injectable transport.

import Foundation
import OpenGrokHTTP

public let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
public let defaultDevicePollIntervalSeconds: Int = 5

public enum DeviceCodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case notEnabled
    case invalidUserCode
    case invalidVerificationURI
    case timeout
    case cancelled
    case denied(String)
    case other(String)

    public var description: String {
        switch self {
        case .notEnabled:
            return "Device-code login is not available for this deployment. Try `open-grok login` or set XAI_API_KEY instead."
        case .invalidUserCode:
            return "Server returned invalid user_code format"
        case .invalidVerificationURI:
            return "Server returned invalid verification_uri"
        case .timeout:
            return "Device-code login timed out"
        case .cancelled:
            return "Device-code login cancelled"
        case .denied(let m):
            return "Device-code login denied: \(SecretSafe.message(m))"
        case .other(let m):
            return SecretSafe.message(m)
        }
    }
}

/// Client surface for device-flow metrics.
public enum ClientSurface: String, Sendable, Equatable {
    case ui
    case cli
    case headless
}

/// Result of requesting a device code.
public struct DeviceCode: Sendable, Equatable {
    public var verificationURI: String
    public var verificationURIComplete: String?
    public var userCode: String
    public var deviceCode: String
    public var interval: Int
    public var expiresIn: Int64

    public init(
        verificationURI: String,
        verificationURIComplete: String? = nil,
        userCode: String,
        deviceCode: String,
        interval: Int = defaultDevicePollIntervalSeconds,
        expiresIn: Int64
    ) {
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// Request a device code from the OAuth2 provider.
public func requestDeviceCode(
    issuer: String,
    clientID: String,
    scopes: [String],
    surface: ClientSurface = .cli,
    transport: any HTTPTransport,
    clientVersion: String = "open-grok"
) async throws -> DeviceCode {
    try Task.checkCancellation()
    let base = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/oauth2/device/code") else {
        throw DeviceCodeError.other("invalid issuer URL")
    }
    let scopeStr = scopes.joined(separator: " ")
    let body = formURLEncoded([
        "client_id": clientID,
        "scope": scopeStr,
        "referrer": "grok-build",
    ])
    let request = HTTPRequest(
        method: .post,
        url: url,
        headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "x-grok-client-version": clientVersion,
            "x-grok-client-surface": surface.rawValue,
        ],
        body: Data(body.utf8),
        timeout: 30,
        idempotency: .nonIdempotent
    )
    let response = try await transport.send(request)
    if response.metadata.statusCode == 404 {
        throw DeviceCodeError.notEnabled
    }
    guard (200..<300).contains(response.metadata.statusCode) else {
        let text = String(data: response.body, encoding: .utf8) ?? ""
        throw DeviceCodeError.other("Device code request failed (HTTP \(response.metadata.statusCode)): \(text)")
    }
    guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let deviceCode = json["device_code"] as? String,
          let userCode = json["user_code"] as? String,
          let verificationURI = json["verification_uri"] as? String,
          let expiresIn = int64Value(json["expires_in"])
    else {
        throw DeviceCodeError.other("malformed device code response")
    }
    guard userCode.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || $0 == "-"
    }) else {
        throw DeviceCodeError.invalidUserCode
    }
    try validateVerificationURI(verificationURI)
    let complete = json["verification_uri_complete"] as? String
    if let complete {
        try validateVerificationURI(complete)
    }
    let interval = (json["interval"] as? Int)
        ?? (json["interval"] as? NSNumber)?.intValue
        ?? defaultDevicePollIntervalSeconds
    return DeviceCode(
        verificationURI: verificationURI,
        verificationURIComplete: complete,
        userCode: userCode,
        deviceCode: deviceCode,
        interval: interval,
        expiresIn: expiresIn
    )
}

/// Poll until approved; return tokens. Cancellation leaves prior credentials intact.
public func pollDeviceCodeToken(
    issuer: String,
    clientID: String,
    device: DeviceCode,
    transport: any HTTPTransport,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int64?) {
    let base = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(base)/oauth2/token") else {
        throw DeviceCodeError.other("invalid issuer URL")
    }
    let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
    var interval = TimeInterval(max(1, device.interval))

    while Date() < deadline {
        try Task.checkCancellation()
        let body = formURLEncoded([
            "grant_type": deviceGrantType,
            "device_code": device.deviceCode,
            "client_id": clientID,
        ])
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 30,
            idempotency: .nonIdempotent
        )
        let response = try await transport.send(request)
        if (200..<300).contains(response.metadata.statusCode) {
            guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let access = json["access_token"] as? String
            else {
                throw DeviceCodeError.other("malformed token response")
            }
            let refresh = json["refresh_token"] as? String
            let expiresIn = int64Value(json["expires_in"])
            return (access, refresh, expiresIn)
        }
        if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           let err = json["error"] as? String {
            switch err {
            case "authorization_pending":
                break
            case "slow_down":
                interval += 5
            case "access_denied", "expired_token":
                throw DeviceCodeError.denied(err)
            default:
                throw DeviceCodeError.other(err)
            }
        }
        try await sleep(interval)
    }
    throw DeviceCodeError.timeout
}

/// Complete device login: poll + build GrokAuth + optional persist via manager.
public func completeDeviceCodeLogin(
    issuer: String,
    clientID: String,
    device: DeviceCode,
    transport: any HTTPTransport,
    manager: AuthManager?,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
) async throws -> GrokAuth {
    let tokens = try await pollDeviceCodeToken(
        issuer: issuer,
        clientID: clientID,
        device: device,
        transport: transport,
        sleep: sleep
    )
    var auth = GrokAuth(
        key: tokens.accessToken,
        authMode: .oidc,
        createTime: Date(),
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
        oidcIssuer: issuer,
        oidcClientID: clientID
    )
    if let payload = decodeJWTPayload(tokens.accessToken) {
        if let sub = payload["sub"] as? String { auth.userID = sub }
        if let email = payload["email"] as? String { auth.email = email }
        if let principal = peekAccessTokenPrincipal(tokens.accessToken) {
            auth.principalType = principal.principalType
            auth.principalID = principal.principalID
            auth.teamID = principal.teamID
        }
    }
    if let manager {
        try await manager.loginWithSession(auth)
    }
    return auth
}

func validateVerificationURI(_ uri: String) throws {
    guard let url = URL(string: uri),
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http"
    else {
        throw DeviceCodeError.invalidVerificationURI
    }
}

func int64Value(_ any: Any?) -> Int64? {
    if let i = any as? Int64 { return i }
    if let i = any as? Int { return Int64(i) }
    if let n = any as? NSNumber { return n.int64Value }
    if let s = any as? String { return Int64(s) }
    return nil
}
