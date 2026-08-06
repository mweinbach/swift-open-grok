// NetworkPolicy.swift
//
// Pure policy modeling for child website egress. Ported from
// `xai-grok-sandbox/src/network_policy.rs`. Constructing a policy does not
// grant or restrict network access by itself.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Version of the compact JSON produced by `NetworkPolicySnapshot`.
public let networkPolicySnapshotVersion: UInt32 = 1

/// Requested child-network behavior for future enforcement backends.
public enum ChildNetworkPolicy: Codable, Sendable, Equatable, Hashable {
    case unrestricted
    case blocked
    case websites(WebsitePolicy)

    public static func from(restrictNetwork: Bool) -> ChildNetworkPolicy {
        restrictNetwork ? .blocked : .unrestricted
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case policy
    }

    private enum Mode: String, Codable {
        case unrestricted
        case blocked
        case websites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decode(Mode.self, forKey: .mode)
        switch mode {
        case .unrestricted: self = .unrestricted
        case .blocked: self = .blocked
        case .websites:
            let policy = try c.decode(WebsitePolicy.self, forKey: .policy)
            self = .websites(policy)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unrestricted:
            try c.encode(Mode.unrestricted, forKey: .mode)
        case .blocked:
            try c.encode(Mode.blocked, forKey: .mode)
        case .websites(let policy):
            try c.encode(Mode.websites, forKey: .mode)
            try c.encode(policy, forKey: .policy)
        }
    }
}

/// Result of exact-origin website policy evaluation.
public enum WebsiteAction: String, Codable, Sendable, Equatable, Hashable {
    case allow
    case deny
}

/// Exact HTTP(S) origin with ASCII hostname and effective nonzero port.
public struct WebsiteOrigin: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let scheme: String
    public let hostname: String
    public let port: UInt16

    public var description: String {
        "\(scheme)://\(hostname):\(port)"
    }

    public static func < (lhs: WebsiteOrigin, rhs: WebsiteOrigin) -> Bool {
        if lhs.scheme != rhs.scheme { return lhs.scheme < rhs.scheme }
        if lhs.hostname != rhs.hostname { return lhs.hostname < rhs.hostname }
        return lhs.port < rhs.port
    }

    public init(scheme: String, hostname: String, port: UInt16) {
        self.scheme = scheme
        self.hostname = hostname
        self.port = port
    }

    /// Parse only `http://authority`, `https://authority`, or either with `/`.
    public static func parse(_ value: String) throws -> WebsiteOrigin {
        try validateRawOrigin(value)
        guard let components = URLComponents(string: value) else {
            throw WebsiteOriginError.invalidSyntax
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw WebsiteOriginError.invalidSyntax
        }
        guard let host = components.host, !host.isEmpty else {
            throw WebsiteOriginError.invalidSyntax
        }
        // Reject IP literals.
        if host.contains(":") || IPv4Address(host) != nil {
            throw WebsiteOriginError.ipLiteral
        }
        var hostname = host
        if hostname.hasSuffix(".") {
            hostname = String(hostname.dropLast())
        }
        hostname = hostname.lowercased()
        guard validDNSHostname(hostname), IPv4Address(hostname) == nil else {
            throw WebsiteOriginError.invalidHost(hostname)
        }
        let port: UInt16
        if let p = components.port {
            guard p > 0, p <= Int(UInt16.max) else { throw WebsiteOriginError.portZero }
            port = UInt16(p)
        } else {
            port = scheme == "https" ? 443 : 80
        }
        if port == 0 { throw WebsiteOriginError.portZero }
        return WebsiteOrigin(scheme: scheme, hostname: hostname, port: port)
    }
}

public enum WebsiteOriginError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSyntax
    case invalidOrigin(value: String, reason: String)
    case ipLiteral
    case invalidHost(String)
    case portZero
    case userinfo
    case wildcard

    public var description: String {
        switch self {
        case .invalidSyntax: return "invalid origin syntax"
        case .invalidOrigin(let v, let r): return "invalid origin \(v): \(r)"
        case .ipLiteral: return "IP literal origins are not allowed"
        case .invalidHost(let h): return "invalid host: \(h)"
        case .portZero: return "port must be nonzero"
        case .userinfo: return "userinfo is not allowed in origins"
        case .wildcard: return "wildcard origins are not allowed"
        }
    }
}

/// Allow/deny list of exact origins.
public struct WebsitePolicy: Codable, Sendable, Equatable, Hashable {
    public var allow: Set<WebsiteOrigin>
    public var deny: Set<WebsiteOrigin>
    /// Default when an origin matches neither list.
    public var defaultAction: WebsiteAction

    public init(
        allow: Set<WebsiteOrigin> = [],
        deny: Set<WebsiteOrigin> = [],
        defaultAction: WebsiteAction = .deny
    ) {
        self.allow = allow
        self.deny = deny
        self.defaultAction = defaultAction
    }

    /// Evaluate an exact origin. Deny list wins over allow.
    public func evaluate(_ origin: WebsiteOrigin) -> WebsiteAction {
        if deny.contains(origin) { return .deny }
        if allow.contains(origin) { return .allow }
        return defaultAction
    }
}

/// Compact snapshot for telemetry / persistence.
public struct NetworkPolicySnapshot: Codable, Sendable, Equatable {
    public var version: UInt32
    public var policy: ChildNetworkPolicy
    public var digest: String

    public init(policy: ChildNetworkPolicy) throws {
        self.version = networkPolicySnapshotVersion
        self.policy = policy
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(policy)
        self.digest = sha256Hex(data)
    }
}

private func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    let hash = SHA256.hash(data: data)
    return hash.map { String(format: "%02x", $0) }.joined()
    #else
    // Portable fallback: FNV-1a 64-bit over bytes, expanded for stable length.
    // Full SHA-256 is used on Apple platforms via CryptoKit.
    var hash: UInt64 = 0xcbf29ce484222325
    for b in data {
        hash ^= UInt64(b)
        hash &*= 0x100000001b3
    }
    return String(format: "%016llx%016llx", hash, hash &+ UInt64(data.count))
    #endif
}

// MARK: - Helpers

private func validateRawOrigin(_ value: String) throws {
    if value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) {
        throw WebsiteOriginError.invalidSyntax
    }
    if value.contains("\\") { throw WebsiteOriginError.invalidSyntax }
    guard let authority = value.hasPrefix("http://")
        ? value.dropFirst("http://".count)
        : value.hasPrefix("https://")
            ? value.dropFirst("https://".count)
            : nil
    else {
        throw WebsiteOriginError.invalidSyntax
    }
    var auth = String(authority)
    if auth.hasSuffix("/") { auth = String(auth.dropLast()) }
    if auth.isEmpty || auth.contains("/") || auth.contains("?") || auth.contains("#") {
        throw WebsiteOriginError.invalidSyntax
    }
    if auth.contains("@") { throw WebsiteOriginError.userinfo }
    if auth.contains("*") { throw WebsiteOriginError.wildcard }
}

private func validDNSHostname(_ hostname: String) -> Bool {
    guard !hostname.isEmpty, hostname.count <= 253 else { return false }
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
    for label in labels {
        if label.isEmpty || label.count > 63 { return false }
        guard let first = label.first, let last = label.last else { return false }
        if !first.isASCII || !last.isASCII { return false }
        if !first.isLetter && !first.isNumber { return false }
        if !last.isLetter && !last.isNumber { return false }
        for ch in label {
            guard ch.isASCII, ch.isLetter || ch.isNumber || ch == "-" else { return false }
        }
    }
    return true
}

/// Minimal IPv4 detector (no Network framework dependency required).
private struct IPv4Address {
    init?(_ s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        for p in parts {
            if p.isEmpty { return nil }
            guard let n = Int(p), n >= 0, n <= 255 else { return nil }
        }
    }
}

// MARK: - Child Network Launch Restriction

extension ChildNetworkPolicy {
    /// Transform a child launch to enforce this policy at spawn time.
    ///
    /// `.blocked` maps to the Linux `unshare` namespace re-exec in
    /// `ChildNetworkRestriction.swift`, failing closed with
    /// `SandboxError.unsupported` when the host cannot enforce. Off Linux it
    /// is a deliberate no-op, matching upstream's non-Linux child filter
    /// (`child_net.rs:226-229` returns `Ok(())`). macOS keeps process-level
    /// network access available for provider sampling rather than denying it
    /// in Seatbelt.
    ///
    /// `.websites` is a typed unsupported on every platform: upstream models
    /// the per-origin list but never enforces it (`network_policy.rs:3`:
    /// "not selected by sandbox profiles or enforced by the current"
    /// runtime). Degrading an allow-list to all-or-nothing would break the
    /// origins the user allowed, and degrading to a no-op would claim
    /// enforcement that does not exist — so it refuses loudly instead.
    public func restrictedLaunch(
        executable: String,
        arguments: [String]
    ) throws -> (executable: String, arguments: [String]) {
        switch self {
        case .unrestricted:
            return (executable, arguments)
        case .blocked:
            #if os(Linux)
            return try LinuxChildNetworkRestriction.wrappedCommand(
                executable: executable,
                arguments: arguments
            )
            #else
            return (executable, arguments)
            #endif
        case .websites:
            throw SandboxError.unsupported(
                "per-origin child network policies are not enforceable: upstream "
                    + "models ChildNetworkPolicy::Websites but never enforces it"
            )
        }
    }
}
