import Foundation
import OpenGrokConfigTypes

/// The transport facts an enterprise MCP rule is allowed to inspect.
///
/// ACP SDK servers do not disclose their backing transport to the agent. They
/// deliberately remain opaque so a URL/command rule cannot be bypassed by
/// relabelling an uninspectable server as an approved transport.
public struct ManagedMCPServerIdentity: Sendable, Equatable {
    public enum Transport: Sendable, Equatable {
        case http(url: String)
        case stdio(command: String)
        case opaque
    }

    public let name: String
    public let transport: Transport

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }

    public init(name: String, transport: McpServerTransportConfig) {
        self.name = name
        switch transport {
        case .stdio(let command, _, _, _):
            self.transport = .stdio(command: command)
        case .streamableHttp(let url, _, _, _, _, _, _):
            self.transport = .http(url: url)
        }
    }

    public init(name: String) {
        self.init(name: name, transport: .opaque)
    }
}

/// One supported entry in `allowedMcpServers` or `deniedMcpServers`.
public enum ManagedMCPServerRule: Sendable, Equatable {
    case serverURL(String)
    case command(String)
    case serverName(String)
}

/// Protected `managed-settings.json` MCP policy.
///
/// Rule matching follows `permission/resolution.rs:1026-1338`: server names
/// are normalized and prefix-insensitive; commands match exactly; URL allows
/// are literal globs while URL denies normalize host and ignore scheme/port.
/// An explicitly present empty allowlist is retained separately from an
/// absent key for inspection, but both remain unrestricted, exactly matching
/// upstream's empty-vector admission semantics. Malformed protected policy
/// fails closed because its intended restrictions cannot be evaluated safely.
public struct ManagedMCPPolicy: Sendable, Equatable {
    public let allowedServers: [ManagedMCPServerRule]?
    public let deniedServers: [ManagedMCPServerRule]?
    public let sourcePath: URL?
    public let invalidReason: String?

    public init(
        allowedServers: [ManagedMCPServerRule]? = nil,
        deniedServers: [ManagedMCPServerRule]? = nil,
        sourcePath: URL? = nil,
        invalidReason: String? = nil
    ) {
        self.allowedServers = allowedServers
        self.deniedServers = deniedServers
        self.sourcePath = sourcePath
        self.invalidReason = invalidReason
    }

    public static var unrestricted: ManagedMCPPolicy { ManagedMCPPolicy() }

    public var isRestricted: Bool {
        invalidReason != nil
            || !(allowedServers ?? []).isEmpty
            || !(deniedServers ?? []).isEmpty
    }

    /// A missing admin policy is unrestricted; an existing unreadable or
    /// malformed policy must never silently disable the administrator's gate.
    public static func load(from path: URL?) -> ManagedMCPPolicy {
        guard let path else { return .unrestricted }
        do {
            return parse(try Data(contentsOf: path), sourcePath: path)
        } catch {
            return ManagedMCPPolicy(
                sourcePath: path,
                invalidReason: "cannot read managed-settings.json: \(error)"
            )
        }
    }

    public static func parse(_ data: Data, sourcePath: URL? = nil) -> ManagedMCPPolicy {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            return ManagedMCPPolicy(
                sourcePath: sourcePath,
                invalidReason: "invalid managed-settings.json: \(error)"
            )
        }
        guard let object = value as? [String: Any] else {
            return ManagedMCPPolicy(
                sourcePath: sourcePath,
                invalidReason: "managed-settings.json must contain an object"
            )
        }

        do {
            return try ManagedMCPPolicy(
                allowedServers: parseEntries(object["allowedMcpServers"], key: "allowedMcpServers"),
                deniedServers: parseEntries(object["deniedMcpServers"], key: "deniedMcpServers"),
                sourcePath: sourcePath
            )
        } catch {
            return ManagedMCPPolicy(
                sourcePath: sourcePath,
                invalidReason: String(describing: error)
            )
        }
    }

    public func isServerAllowed(_ server: ManagedMCPServerIdentity) -> Bool {
        blockReason(for: server) == nil
    }

    public func isServerDenied(_ server: ManagedMCPServerIdentity) -> Bool {
        guard invalidReason == nil else { return true }
        let denied = deniedServers ?? []
        if denied.contains(where: { matches($0, server: server, isDeny: true) }) {
            return true
        }
        if case .opaque = server.transport,
           denied.contains(where: Self.isTransportRule) {
            return true
        }
        return false
    }

    public func blockReason(for server: ManagedMCPServerIdentity) -> String? {
        if let invalidReason {
            return "invalid managed MCP server policy\(sourceSuffix): \(invalidReason)"
        }
        if isServerDenied(server) {
            return "matches deniedMcpServers\(sourceSuffix)"
        }
        guard let allowed = allowedServers, !allowed.isEmpty else { return nil }

        var restricted = false
        var matched = false
        for rule in allowed {
            switch (rule, server.transport) {
            case (.serverName, _), (.serverURL, .http), (.command, .stdio):
                restricted = true
                matched = matched || matches(rule, server: server, isDeny: false)
            case (.serverURL, .opaque), (.command, .opaque):
                restricted = true
            default:
                continue
            }
        }
        return !restricted || matched ? nil : "not in allowedMcpServers\(sourceSuffix)"
    }

    private var sourceSuffix: String {
        sourcePath.map { " (\($0.path))" } ?? ""
    }

    private static func parseEntries(
        _ value: Any?,
        key: String
    ) throws -> [ManagedMCPServerRule]? {
        guard let value else { return nil }
        guard let entries = value as? [Any] else {
            throw ParseFailure("\(key) must be an array")
        }
        var parsed: [ManagedMCPServerRule] = []
        parsed.reserveCapacity(entries.count)
        for (index, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else {
                throw ParseFailure("\(key)[\(index)] must be an object")
            }
            let rule: ManagedMCPServerRule
            if let pattern = entry["serverUrl"] as? String {
                guard !pattern.isEmpty, globExpression(pattern) != nil else {
                    throw ParseFailure("\(key)[\(index)].serverUrl is empty or invalid")
                }
                if key == "deniedMcpServers", splitHostPath(pattern).host == nil {
                    throw ParseFailure("\(key)[\(index)].serverUrl has no host")
                }
                rule = .serverURL(pattern)
            } else if let command = entry["command"] as? String {
                guard !command.isEmpty else {
                    throw ParseFailure("\(key)[\(index)].command must not be empty")
                }
                rule = .command(command)
            } else if let name = entry["serverName"] as? String {
                guard !normalizedName(name).isEmpty else {
                    throw ParseFailure("\(key)[\(index)].serverName must not be empty")
                }
                rule = .serverName(name)
            } else {
                throw ParseFailure(
                    "\(key)[\(index)] must contain serverUrl, command, or serverName"
                )
            }
            parsed.append(rule)
        }
        return parsed
    }

    private func matches(
        _ rule: ManagedMCPServerRule,
        server: ManagedMCPServerIdentity,
        isDeny: Bool
    ) -> Bool {
        switch (rule, server.transport) {
        case (.serverName(let expected), _):
            let expectedKey = Self.normalizedName(expected)
            return !expectedKey.isEmpty && expectedKey == Self.normalizedName(server.name)
        case (.command(let expected), .stdio(let actual)):
            return expected == actual
        case (.serverURL(let pattern), .http(let actual)):
            return isDeny
                ? Self.deniedURLMatches(pattern: pattern, actual: actual)
                : Self.globMatches(pattern: pattern, actual: Self.stripQuery(actual))
        default:
            return false
        }
    }

    private static func isTransportRule(_ rule: ManagedMCPServerRule) -> Bool {
        switch rule {
        case .serverURL, .command: true
        case .serverName: false
        }
    }

    private static let managedPrefix = "grok_com_"
    private static let maximumBareNameScalars = 39 - managedPrefix.count

    private static func normalizedName(_ value: String) -> String {
        let bare = value.hasPrefix(managedPrefix)
            ? String(value.dropFirst(managedPrefix.count))
            : value
        let normalized = bare.lowercased().replacingOccurrences(of: " ", with: "_")
        let limited = normalized.unicodeScalars.prefix(maximumBareNameScalars)
        return String(String.UnicodeScalarView(limited))
    }

    private static func deniedURLMatches(pattern: String, actual: String) -> Bool {
        let expected = splitHostPath(pattern)
        let observed = splitHostPath(stripQuery(actual))
        guard let expectedHost = expected.host,
              let observedHost = observed.host,
              globMatches(pattern: expectedHost, actual: observedHost) else {
            return false
        }
        guard !expected.path.isEmpty else { return true }
        return globMatches(
            pattern: expected.path,
            actual: observed.path.isEmpty ? "/" : observed.path
        )
    }

    private static func splitHostPath(_ value: String) -> (host: String?, path: String) {
        let remainder: Substring
        if let scheme = value.range(of: "://") {
            remainder = value[scheme.upperBound...]
        } else {
            remainder = value[...]
        }
        let authority: Substring
        let path: String
        if let separator = remainder.firstIndex(of: "/") {
            authority = remainder[..<separator]
            path = String(remainder[separator...])
        } else {
            authority = remainder
            path = ""
        }
        let withoutUser = authority.split(separator: "@", omittingEmptySubsequences: false)
            .last ?? authority
        let withoutPort = withoutUser.split(separator: ":", omittingEmptySubsequences: false)
            .first ?? withoutUser
        var host = String(withoutPort).lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return (host.isEmpty ? nil : host, path)
    }

    private static func stripQuery(_ value: String) -> String {
        let withoutFragment = value.split(
            separator: "#", maxSplits: 1, omittingEmptySubsequences: false
        ).first ?? value[...]
        return String(withoutFragment.split(
            separator: "?", maxSplits: 1, omittingEmptySubsequences: false
        ).first ?? withoutFragment)
    }

    private static func globMatches(pattern: String, actual: String) -> Bool {
        guard let expression = globExpression(pattern) else { return false }
        let range = NSRange(actual.startIndex..<actual.endIndex, in: actual)
        return expression.firstMatch(in: actual, options: [], range: range) != nil
    }

    private static func globExpression(_ pattern: String) -> NSRegularExpression? {
        let characters = Array(pattern)
        var regex = "\\A"
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case "[":
                guard let close = characters[(index + 1)...].firstIndex(of: "]"),
                      close > index + 1 else { return nil }
                var contents = String(characters[(index + 1)..<close])
                if contents.hasPrefix("!") {
                    contents.replaceSubrange(contents.startIndex...contents.startIndex, with: "^")
                } else if contents.hasPrefix("^") {
                    contents.insert("\\", at: contents.startIndex)
                }
                regex += "[\(contents)]"
                index = close
            default:
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        regex += "\\z"
        return try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])
    }

    private struct ParseFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
