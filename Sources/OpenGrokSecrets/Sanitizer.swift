// Sanitizer.swift
//
// Port of `xai-grok-secrets` regex sanitizer for outbound data (Sentry /
// Mixpanel / product-event scrubbing). Never log raw secrets.

import Foundation

/// Redaction markers matching the Rust crate.
public enum SecretRedaction {
    public static let secret = "[REDACTED_SECRET]"
    public static let urlValue = "redacted"
    public static let userSegment = "<user>"
}

/// Regex-based secret scrubbing for logs, telemetry, and crash reports.
public enum SecretSanitizer: Sendable {
    private static let redacted = SecretRedaction.secret
    private static let redactedURLValue = SecretRedaction.urlValue

    private static let apiKeyPrefix = try! NSRegularExpression(
        pattern: #"\b(?:sk[-_]|xai-)[A-Za-z0-9_-]{20,}"#
    )
    private static let awsAccessKey = try! NSRegularExpression(
        pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#
    )
    private static let githubToken = try! NSRegularExpression(
        pattern: #"\b(?:gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#
    )
    private static let vendorToken = try! NSRegularExpression(
        pattern: #"\b(?:glpat-|xox[abp]-|xapp-)[A-Za-z0-9-]{10,}"#
    )
    private static let googleAPIKey = try! NSRegularExpression(
        pattern: #"\bAIza[0-9A-Za-z_-]{35}"#
    )
    private static let pemPrivateKey = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    )
    private static let bearerToken = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._\-]{16,}\b"#
    )
    private static let jwt = try! NSRegularExpression(
        pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#
    )
    private static let secretAssignment = try! NSRegularExpression(
        pattern: #"(?ix)\b(api[_-]?key|(?:access|refresh|id)[_-]token|token|secret|client[_-]secret|password)\b(\s*[:=]\s*)(["']?)[^\s"',&]{8,}"#
    )
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s"'<>(){}\[\],;`]+"#
    )
    private static let homeRootUser = try! NSRegularExpression(
        pattern: #"([/\\](?:Users|home)[/\\])([^/\\]+)"#
    )

    private static let sensitiveQueryParams: Set<String> = [
        "access_token", "api_key", "assertion", "auth", "client_secret",
        "code", "code_verifier", "id_token", "key", "password",
        "refresh_token", "requested_token", "session_id", "state",
        "subject_token", "token",
    ]

    /// Number of MATCH_ANY patterns (tripwire vs Rust count of 10).
    public static let matchPatternCount = 10

    /// Redact known secret shapes in free text. Returns the original string
    /// when nothing matched (cheap no-allocation path).
    public static func redactSecrets(_ input: String) -> String {
        if !mightContainSecret(input) {
            return input
        }
        var s = replace(pemPrivateKey, in: input, with: redacted)
        s = replace(apiKeyPrefix, in: s, with: redacted)
        s = replace(awsAccessKey, in: s, with: redacted)
        s = replace(githubToken, in: s, with: redacted)
        s = replace(vendorToken, in: s, with: redacted)
        s = replace(googleAPIKey, in: s, with: redacted)
        s = replace(bearerToken, in: s, with: "Bearer \(redacted)")
        s = replace(jwt, in: s, with: redacted)
        s = redactURLs(in: s)
        s = replaceSecretAssignments(in: s)
        return s
    }

    /// Redact string values inside a JSON object graph (recursive).
    public static func redactJSONStringValues(_ object: inout [String: Any]) {
        for key in object.keys {
            if var nested = object[key] as? [String: Any] {
                redactJSONStringValues(&nested)
                object[key] = nested
            } else if var arr = object[key] as? [Any] {
                redactJSONArray(&arr)
                object[key] = arr
            } else if let str = object[key] as? String {
                let red = redactSecrets(str)
                if red != str { object[key] = red }
            }
        }
    }

    /// Collapse `$HOME` to `~` and username path segments to `<user>`.
    public static func redactUserPaths(
        _ input: String,
        home: String? = ProcessInfo.processInfo.environment["HOME"]
            ?? ProcessInfo.processInfo.environment["USERPROFILE"],
        usernames: [String]? = nil
    ) -> String {
        let names = usernames ?? defaultUsernames()
        return redactUserPathsWithBackstop(input, home: home, usernames: names)
    }

    /// Redact credentials and sensitive query params in a URL string.
    public static func redactURLString(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                if sensitiveQueryParams.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: redactedURLValue)
                }
                return item
            }
        }
        return components.string ?? raw
    }

    // MARK: - Internals

    private static func mightContainSecret(_ input: String) -> Bool {
        // Cheap prefilter before allocating replacements.
        for re in [apiKeyPrefix, awsAccessKey, githubToken, vendorToken,
                   googleAPIKey, pemPrivateKey, bearerToken, jwt, urlPattern,
                   secretAssignment] {
            if re.firstMatch(in: input, range: nsRange(input)) != nil {
                return true
            }
        }
        return false
    }

    private static func replace(
        _ re: NSRegularExpression,
        in input: String,
        with template: String
    ) -> String {
        re.stringByReplacingMatches(
            in: input,
            range: nsRange(input),
            withTemplate: template
        )
    }

    private static func replaceSecretAssignments(in input: String) -> String {
        let matches = secretAssignment.matches(in: input, range: nsRange(input))
        guard !matches.isEmpty else { return input }
        var result = input
        // Replace from the end so ranges stay valid.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let full = Range(match.range, in: result)!
            let name = Range(match.range(at: 1), in: result).map { String(result[$0]) } ?? ""
            let sep = Range(match.range(at: 2), in: result).map { String(result[$0]) } ?? ""
            let quote = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? ""
            let replacement = "\(name)\(sep)\(quote)\(redacted)"
            result.replaceSubrange(full, with: replacement)
        }
        return result
    }

    private static func redactURLs(in text: String) -> String {
        let matches = urlPattern.matches(in: text, range: nsRange(text))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            result.replaceSubrange(range, with: redactURLString(raw))
        }
        return result
    }

    private static func redactJSONArray(_ array: inout [Any]) {
        for i in array.indices {
            if var nested = array[i] as? [String: Any] {
                redactJSONStringValues(&nested)
                array[i] = nested
            } else if var arr = array[i] as? [Any] {
                redactJSONArray(&arr)
                array[i] = arr
            } else if let str = array[i] as? String {
                let red = redactSecrets(str)
                if red != str { array[i] = red }
            }
        }
    }

    static func redactUserPathsWithBackstop(
        _ input: String,
        home: String?,
        usernames: [String]
    ) -> String {
        let envScrubbed = redactUserPathsEnv(input, home: home, usernames: usernames)
        if home != nil || !usernames.isEmpty {
            return envScrubbed
        }
        return homeRootUser.stringByReplacingMatches(
            in: envScrubbed,
            range: nsRange(envScrubbed),
            withTemplate: "$1<user>"
        )
    }

    static func redactUserPathsEnv(
        _ input: String,
        home: String?,
        usernames: [String]
    ) -> String {
        var stage1 = input
        if let home, !home.isEmpty, input.contains(home) {
            stage1 = replaceHomePrefix(input, home: home)
        }
        if !usernames.isEmpty {
            let stage2 = redactUsernameSegments(stage1, usernames: usernames)
            if stage2 != stage1 { return stage2 }
        }
        return stage1
    }

    private static func replaceHomePrefix(_ input: String, home: String) -> String {
        var out = ""
        var rest = input
        while let idx = rest.range(of: home) {
            let before = String(rest[..<idx.lowerBound])
            let after = String(rest[idx.upperBound...])
            let prevOK = before.last.map(isSegmentBoundary) ?? true
            let nextOK = after.first.map(isSegmentBoundary) ?? true
            out += before
            if prevOK && nextOK {
                out += "~"
            } else {
                out += home
            }
            rest = after
        }
        out += rest
        return out
    }

    private static func redactUsernameSegments(_ value: String, usernames: [String]) -> String {
        var out = ""
        var buf = ""
        for ch in value {
            if isSegmentBoundary(ch) {
                pushUsernameSegment(&out, segment: buf, usernames: usernames)
                buf = ""
                out.append(ch)
            } else {
                buf.append(ch)
            }
        }
        pushUsernameSegment(&out, segment: buf, usernames: usernames)
        return out
    }

    private static func pushUsernameSegment(
        _ out: inout String,
        segment: String,
        usernames: [String]
    ) {
        #if os(Windows)
        let matches = usernames.contains { $0.compare(segment, options: .caseInsensitive) == .orderedSame }
        #else
        let matches = usernames.contains(segment)
        #endif
        out += matches ? SecretRedaction.userSegment : segment
    }

    private static func isSegmentBoundary(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c == "_" || c == "-" || c == ".")
    }

    private static func defaultUsernames() -> [String] {
        var names: [String] = []
        for key in ["USERNAME", "USER"] {
            if let name = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespaces),
               name.count >= 3,
               !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
        }
        return names
    }

    private static func nsRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }
}
