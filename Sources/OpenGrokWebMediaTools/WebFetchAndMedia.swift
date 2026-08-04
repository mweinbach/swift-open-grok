import Foundation
import OpenGrokHTTP

public struct WebFetchParams: Codable, Sendable, Equatable, Hashable {
    public var cacheTTLSeconds: UInt64?
    public var maxCacheEntries: Int?
    public var timeoutSeconds: UInt64?
    public var maxContentLength: Int?
    public var maxMarkdownLength: Int?
    public var contextWindowTokens: UInt64?
    public var allowedDomains: [String]?
    public var proxyEndpoint: String?
    public var allowLocal: Bool?

    public init(
        cacheTTLSeconds: UInt64? = nil,
        maxCacheEntries: Int? = nil,
        timeoutSeconds: UInt64? = nil,
        maxContentLength: Int? = nil,
        maxMarkdownLength: Int? = nil,
        contextWindowTokens: UInt64? = nil,
        allowedDomains: [String]? = nil,
        proxyEndpoint: String? = nil,
        allowLocal: Bool? = nil
    ) {
        self.cacheTTLSeconds = cacheTTLSeconds
        self.maxCacheEntries = maxCacheEntries
        self.timeoutSeconds = timeoutSeconds
        self.maxContentLength = maxContentLength
        self.maxMarkdownLength = maxMarkdownLength
        self.contextWindowTokens = contextWindowTokens
        self.allowedDomains = allowedDomains
        self.proxyEndpoint = proxyEndpoint
        self.allowLocal = allowLocal
    }

    public var cacheTTL: TimeInterval { TimeInterval(cacheTTLSeconds ?? 900) }
    public var cacheEntryLimit: Int { max(1, maxCacheEntries ?? 128) }
    public var timeout: TimeInterval { TimeInterval(timeoutSeconds ?? 60) }
    public var contentLimit: Int { max(1, maxContentLength ?? 10 * 1024 * 1024) }
    public var markdownLimit: Int { max(1, maxMarkdownLength ?? 100_000) }
    public var contextWindow: UInt64 { contextWindowTokens ?? 128_000 }
    public var localHostsAllowed: Bool { allowLocal ?? false }
    public var domainAllowlist: [String] {
        allowedDomains ?? Self.defaultAllowedDomains
    }

    public static let defaultAllowedDomains: [String] = [
        "x.ai", "console.x.ai", "docs.x.ai", "api.x.ai",
        "docs.python.org", "en.cppreference.com", "docs.oracle.com", "learn.microsoft.com",
        "developer.mozilla.org", "go.dev", "pkg.go.dev", "www.php.net", "docs.swift.org",
        "kotlinlang.org", "ruby-doc.org", "doc.rust-lang.org", "docs.rs", "www.typescriptlang.org",
        "react.dev", "angular.io", "vuejs.org", "nextjs.org", "expressjs.com", "nodejs.org",
        "bun.sh", "jquery.com", "getbootstrap.com", "tailwindcss.com", "d3js.org", "threejs.org",
        "redux.js.org", "webpack.js.org", "jestjs.io", "reactrouter.com", "docs.djangoproject.com",
        "flask.palletsprojects.com", "fastapi.tiangolo.com", "pandas.pydata.org", "numpy.org",
        "www.tensorflow.org", "pytorch.org", "scikit-learn.org", "matplotlib.org", "requests.readthedocs.io",
        "jupyter.org", "laravel.com", "symfony.com", "wordpress.org", "docs.spring.io", "hibernate.org",
        "tomcat.apache.org", "gradle.org", "maven.apache.org", "asp.net", "dotnet.microsoft.com",
        "nuget.org", "blazor.net", "reactnative.dev", "docs.flutter.dev", "developer.apple.com",
        "developer.android.com", "keras.io", "spark.apache.org", "huggingface.co", "www.kaggle.com",
        "redis.io", "www.postgresql.org", "dev.mysql.com", "www.sqlite.org", "graphql.org", "prisma.io",
        "docs.aws.amazon.com", "cloud.google.com", "kubernetes.io", "www.docker.com", "www.terraform.io",
        "www.ansible.com", "vercel.com/docs", "docs.netlify.com", "devcenter.heroku.com", "cypress.io",
        "selenium.dev", "docs.unity.com", "docs.unrealengine.com", "git-scm.com", "nginx.org", "httpd.apache.org"
    ]
}

public enum WebFetchConfig: Codable, Sendable, Equatable {
    case disabled
    case enabled(params: WebFetchParams)

    private enum CodingKeys: String, CodingKey { case status, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "disabled": self = .disabled
        case "enabled": self = .enabled(params: try container.decodeIfPresent(WebFetchParams.self, forKey: .params) ?? WebFetchParams())
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "unknown web fetch status")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled: try container.encode("disabled", forKey: .status)
        case .enabled(let params):
            try container.encode("enabled", forKey: .status)
            try container.encode(params, forKey: .params)
        }
    }

    public static var `default`: WebFetchConfig { .disabled }
    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

public struct WebFetchInput: Sendable, Equatable, Hashable, Codable {
    public var url: String
    public init(url: String) { self.url = url }
}

public struct WebFetchOutput: Sendable, Equatable, Hashable, Codable {
    public var content: String
    public var finalURL: String
    public var contentType: String
    public var statusCode: Int
    public var totalBytes: Int
    public var truncated: Bool
    public var artifact: WebFetchArtifact?

    public init(
        content: String,
        finalURL: String,
        contentType: String,
        statusCode: Int = 200,
        totalBytes: Int,
        truncated: Bool,
        artifact: WebFetchArtifact? = nil
    ) {
        self.content = content
        self.finalURL = finalURL
        self.contentType = contentType
        self.statusCode = statusCode
        self.totalBytes = totalBytes
        self.truncated = truncated
        self.artifact = artifact
    }
}

public struct WebFetchArtifact: Sendable, Equatable, Hashable, Codable {
    public var localURL: String
    public var mimeType: String
    public var filename: String

    public init(localURL: String, mimeType: String, filename: String) {
        self.localURL = localURL
        self.mimeType = mimeType
        self.filename = filename
    }
}

private actor WebFetchCache {
    struct Entry: Sendable {
        var expiresAt: Date
        var value: WebFetchOutput
    }

    let ttl: TimeInterval
    let capacity: Int
    var entries: [String: Entry] = [:]
    var order: [String] = []

    init(ttl: TimeInterval, capacity: Int) {
        self.ttl = max(0, ttl)
        self.capacity = max(1, capacity)
    }

    func value(for key: String, now: Date = Date()) -> WebFetchOutput? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        return entry.value
    }

    func insert(_ value: WebFetchOutput, for key: String, now: Date = Date()) {
        guard ttl > 0 else { return }
        entries[key] = Entry(expiresAt: now.addingTimeInterval(ttl), value: value)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

public struct WebFetchClient: Sendable {
    public static let maximumURLLength = 2_000
    public static let maximumRedirects = 10
    public static let userAgent = "Mozilla/5.0 (compatible; grok-agent/1.0; +https://x.ai)"

    public var params: WebFetchParams
    public var transport: any HTTPTransport
    public var artifactDirectory: URL
    private let cache: WebFetchCache

    public init(
        params: WebFetchParams = WebFetchParams(),
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        artifactDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.params = params
        self.transport = transport
        self.artifactDirectory = artifactDirectory ?? Self.defaultArtifactDirectory(environment: environment)
        self.cache = WebFetchCache(ttl: params.cacheTTL, capacity: params.cacheEntryLimit)
    }

    public static func defaultArtifactDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let configured = environment["OPENGROK_HOME"], !configured.isEmpty {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            base = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".opengrok", isDirectory: true)
        }
        return base.appendingPathComponent("media", isDirectory: true)
    }

    public func fetch(_ input: WebFetchInput) async throws -> WebFetchOutput {
        var currentURL = try validateAndNormalize(input.url)
        let cacheKey = currentURL.absoluteString
        if let cached = await cache.value(for: cacheKey) { return cached }

        var redirects = 0
        while true {
            try Task.checkCancellation()
            let request = HTTPRequest(
                method: .get,
                url: currentURL,
                headers: [
                    "Accept": "text/markdown,text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "en-US,en;q=0.9",
                    "User-Agent": Self.userAgent
                ],
                timeout: params.timeout,
                idempotency: .idempotent
            )
            let response = try await send(request, tool: "web_fetch")
            if (300..<400).contains(response.metadata.statusCode) {
                redirects += 1
                guard redirects <= Self.maximumRedirects else {
                    throw WebMediaToolError.invalidRequest("web_fetch followed more than \(Self.maximumRedirects) redirects")
                }
                guard let location = header("location", in: response.metadata.headers),
                      let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL
                else {
                    throw WebMediaToolError.malformedResponse(tool: "web_fetch", detail: "redirect response has no valid Location header")
                }
                let normalizedNext = try validateAndNormalize(nextURL.absoluteString)
                guard normalizedNext.host == currentURL.host else {
                    throw WebMediaToolError.crossHostRedirect(
                        originalHost: currentURL.host ?? "unknown",
                        redirectURL: normalizedNext.absoluteString
                    )
                }
                currentURL = normalizedNext
                continue
            }
            guard (200..<300).contains(response.metadata.statusCode) else {
                throw WebMediaToolError.remoteFailure(
                    tool: "web_fetch",
                    status: response.metadata.statusCode,
                    detail: String(data: response.body.prefix(512), encoding: .utf8) ?? ""
                )
            }
            guard response.body.count <= params.contentLimit else {
                throw WebMediaToolError.responseTooLarge(tool: "web_fetch", limit: params.contentLimit)
            }
            let contentType = normalizedContentType(response.metadata.contentType)
            let finalURL = response.metadata.url?.absoluteString ?? currentURL.absoluteString
            let output = try makeOutput(
                body: response.body,
                contentType: contentType,
                statusCode: response.metadata.statusCode,
                finalURL: finalURL,
                requestURL: currentURL
            )
            await cache.insert(output, for: cacheKey)
            return output
        }
    }

    public func fetch(url: String) async throws -> WebFetchOutput {
        try await fetch(WebFetchInput(url: url))
    }

    private func send(_ request: HTTPRequest, tool: String) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as HTTPError {
            throw WebMediaToolError.http(error)
        } catch {
            throw WebMediaToolError.remoteFailure(tool: tool, status: 0, detail: String(describing: error))
        }
    }

    private func makeOutput(
        body: Data,
        contentType: String,
        statusCode: Int,
        finalURL: String,
        requestURL: URL
    ) throws -> WebFetchOutput {
        if contentType == "application/pdf" || contentType.hasPrefix("image/") || contentType.hasPrefix("video/") {
            guard matchesMediaMagic(contentType: contentType, body: body) else {
                throw WebMediaToolError.contentTypeMismatch(contentType: contentType, url: finalURL)
            }
            let filename = "web-fetch-\(UUID().uuidString.lowercased()).\(extensionForContentType(contentType))"
            let directory = artifactDirectory.appendingPathComponent("web_fetch", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(filename)
            try body.write(to: destination, options: .atomic)
            return WebFetchOutput(
                content: "Fetched media saved to \(destination.path)",
                finalURL: finalURL,
                contentType: contentType,
                statusCode: statusCode,
                totalBytes: body.count,
                truncated: false,
                artifact: WebFetchArtifact(localURL: destination.path, mimeType: contentType, filename: filename)
            )
        }
        guard supportedContentTypes.contains(contentType) else {
            throw WebMediaToolError.invalidRequest("web_fetch does not support content type \(contentType) from \(requestURL.absoluteString)")
        }
        let raw = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
        let markdown = contentType == "text/html" || contentType == "application/xhtml+xml" ? htmlToMarkdown(raw) : stripBase64DataURIs(raw)
        let inlineLimit = min(params.markdownLimit, max(1, Int(params.contextWindow * 3 / 100)))
        let (bounded, truncated) = boundedUTF8(markdown, limit: inlineLimit)
        return WebFetchOutput(
            content: bounded,
            finalURL: finalURL,
            contentType: contentType == "text/html" || contentType == "application/xhtml+xml" ? "markdown" : contentType,
            statusCode: statusCode,
            totalBytes: body.count,
            truncated: truncated
        )
    }

    private func validateAndNormalize(_ raw: String) throws -> URL {
        guard raw.utf8.count <= Self.maximumURLLength else {
            throw WebMediaToolError.invalidRequest("URL exceeds maximum length of \(Self.maximumURLLength) characters")
        }
        guard var components = URLComponents(string: raw) else {
            throw WebMediaToolError.invalidRequest("URL is invalid")
        }
        let originalHost = components.host ?? ""
        if components.scheme?.lowercased() == "http", !isExplicitLocalHost(originalHost) { components.scheme = "https" }
        guard components.scheme?.lowercased() == "https" else {
            throw WebMediaToolError.invalidRequest("web_fetch only supports HTTP and HTTPS URLs")
        }
        guard components.user == nil, components.password == nil else {
            throw WebMediaToolError.invalidRequest("URLs with embedded credentials are not allowed")
        }
        guard let host = components.host, !host.isEmpty else {
            throw WebMediaToolError.invalidRequest("URL has no hostname")
        }
        if host.split(separator: ".").count < 2 && !isExplicitLocalHost(host) {
            throw WebMediaToolError.invalidRequest("hostname must have at least two dot-separated parts: \(host)")
        }
        if isPrivateHost(host), !(params.localHostsAllowed && isExplicitLocalHost(host)) {
            throw WebMediaToolError.blockedURL(host)
        }
        guard (params.localHostsAllowed && isExplicitLocalHost(host))
            || params.domainAllowlist.isEmpty
            || matchesAllowedDomain(host, path: components.path, allowlist: params.domainAllowlist)
        else {
            throw WebMediaToolError.blockedURL("\(host) is not in the configured domain allowlist")
        }
        guard let url = components.url else { throw WebMediaToolError.invalidRequest("URL cannot be represented") }
        return url
    }
}

private let supportedContentTypes: Set<String> = [
    "text/markdown", "text/html", "application/xhtml+xml", "text/plain", "text/csv",
    "application/json", "application/xml", "text/xml", "application/javascript",
    "application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/tiff",
    "video/mp4", "video/webm", "video/quicktime", "video/x-msvideo"
]

private func normalizedContentType(_ value: String?) -> String {
    guard let value else { return "text/html" }
    return value
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? "text/html"
}

private func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

private func matchesMediaMagic(contentType: String, body: Data) -> Bool {
    switch contentType {
    case "application/pdf":
        return body.starts(with: Data("%PDF-".utf8))
    case "image/png":
        return body.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    case "image/jpeg":
        return body.starts(with: [0xFF, 0xD8, 0xFF])
    case "image/gif":
        return body.starts(with: Data("GIF87a".utf8)) || body.starts(with: Data("GIF89a".utf8))
    case "image/webp":
        return body.count >= 12
            && body.starts(with: Data("RIFF".utf8))
            && body.subdata(in: 8..<12) == Data("WEBP".utf8)
    case "image/bmp":
        return body.starts(with: [0x42, 0x4D])
    case "image/tiff":
        return body.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || body.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    case "video/mp4", "video/quicktime":
        return body.count >= 8 && body.subdata(in: 4..<8) == Data("ftyp".utf8)
    case "video/webm":
        return body.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
    case "video/x-msvideo":
        return body.count >= 12
            && body.starts(with: Data("RIFF".utf8))
            && body.subdata(in: 8..<12) == Data("AVI ".utf8)
    default:
        return false
    }
}

private func extensionForContentType(_ contentType: String) -> String {
    switch contentType {
    case "application/pdf": return "pdf"
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/bmp": return "bmp"
    case "image/tiff": return "tiff"
    case "video/mp4": return "mp4"
    case "video/webm": return "webm"
    case "video/quicktime": return "mov"
    case "video/x-msvideo": return "avi"
    default: return "bin"
    }
}

private func stripBase64DataURIs(_ value: String) -> String {
    let pattern = #"data:([^;,\s]{1,80});base64,[A-Za-z0-9+/=]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = regex.matches(in: value, range: fullRange)
    guard !matches.isEmpty else { return value }
    let source = value as NSString
    var output = value
    for match in matches.reversed() {
        let mime = source.substring(with: match.range(at: 1))
        output = (output as NSString).replacingCharacters(
            in: match.range,
            with: "[base64 \(mime) data removed]"
        )
    }
    return output
}

private func matchesAllowedDomain(_ host: String, path: String, allowlist: [String]) -> Bool {
    let normalizedHost = normalizeDomain(host)
    return allowlist.contains { entry in
        let normalizedEntry = normalizeDomain(entry)
        let parts = normalizedEntry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let entryHost = parts.first else { return false }
        guard normalizedHost == entryHost || normalizedHost.hasSuffix(".\(entryHost)") else { return false }
        guard parts.count == 2 else { return true }
        let prefix = "/" + parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == prefix || path.hasPrefix(prefix + "/")
    }
}

private func normalizeDomain(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
        .replacingOccurrences(of: "www.", with: "", options: [.anchored])
}

private func isExplicitLocalHost(_ host: String) -> Bool {
    let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
    let octets = normalized.split(separator: ".").compactMap { Int($0) }
    return octets.count == 4 && octets[0] == 127
        || normalized == "::1"
        || normalized == "0:0:0:0:0:0:0:1"
        || normalized == "::ffff:127.0.0.1"
}

private func isPrivateHost(_ host: String) -> Bool {
    let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if isExplicitLocalHost(normalized) || normalized.hasSuffix(".local") { return true }
    if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") || normalized.hasPrefix("fe80:") { return true }
    let octets = normalized.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4 else { return false }
    if octets[0] == 0 || octets[0] == 10 || octets[0] == 100 && (64...127).contains(octets[1])
        || octets[0] == 169 && octets[1] == 254
        || octets[0] == 192 && octets[1] == 168
        || octets[0] == 192 && octets[1] == 0 && octets[2] == 0
        || octets[0] == 192 && octets[1] == 0 && octets[2] == 2
        || octets[0] == 198 && (18...19).contains(octets[1])
        || octets[0] == 198 && octets[1] == 51 && octets[2] == 100
        || octets[0] == 203 && octets[1] == 0 && octets[2] == 113
        || octets[0] >= 240 {
        return true
    }
    return octets[0] == 172 && (16...31).contains(octets[1])
}

private func htmlToMarkdown(_ raw: String) -> String {
    var text = raw
    for tag in ["script", "style", "noscript", "template", "svg", "iframe", "object", "embed"] {
        let pattern = "(?is)<\(tag)(?:\\s[^>]*)?>.*?</\(tag)\\s*>"
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    text = replaceHTMLMatches(
        text,
        pattern: #"(?is)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#
    ) { match, source in
        let url = source.substring(with: match.range(at: 1))
        let label = stripHTMLTags(source.substring(with: match.range(at: 2)))
        return "[\(label)](\(url))"
    }
    text = text.replacingOccurrences(of: "(?is)<!--.*?-->", with: "", options: .regularExpression)
    for level in 1...6 {
        text = text.replacingOccurrences(
            of: "(?i)<h\(level)(?:\\s[^>]*)?>",
            with: String(repeating: "#", count: level) + " ",
            options: .regularExpression
        )
    }
    text = text.replacingOccurrences(of: "(?i)<li(?:\\s[^>]*)?>", with: "- ", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|tr|pre|section|article)>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)</(td|th)>", with: " | ", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    text = decodeHTMLEntities(text)
    return text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func replaceHTMLMatches(
    _ value: String,
    pattern: String,
    replacement: (NSTextCheckingResult, NSString) -> String
) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let source = value as NSString
    let matches = regex.matches(in: value, range: NSRange(location: 0, length: source.length))
    var output = value
    for match in matches.reversed() {
        output = (output as NSString).replacingCharacters(
            in: match.range,
            with: replacement(match, source)
        )
    }
    return output
}

private func stripHTMLTags(_ value: String) -> String {
    value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
}

private func decodeHTMLEntities(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ")
}

private func boundedUTF8(_ value: String, limit: Int) -> (String, Bool) {
    let data = Data(value.utf8)
    guard data.count > limit else { return (value, false) }
    let prefix = data.prefix(limit)
    return (String(decoding: prefix, as: UTF8.self), true)
}

public struct MediaGenerationConfiguration: Sendable, Equatable, Hashable {
    public var apiKey: String
    public var baseURL: String
    public var extraHeaders: [String: String]
    public var imageModel: String
    public var editModel: String
    public var videoModel: String
    public var videoPollIntervalSeconds: UInt64
    public var videoTimeoutSeconds: UInt64

    public init(
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String] = [:],
        imageModel: String = "grok-imagine-image-quality",
        editModel: String = "grok-imagine-image-quality",
        videoModel: String = "grok-imagine-video",
        videoPollIntervalSeconds: UInt64 = 5,
        videoTimeoutSeconds: UInt64 = 300
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.imageModel = imageModel
        self.editModel = editModel
        self.videoModel = videoModel
        self.videoPollIntervalSeconds = videoPollIntervalSeconds
        self.videoTimeoutSeconds = videoTimeoutSeconds
    }
}

public struct ImageGenerationRequest: Sendable, Equatable, Hashable {
    public var prompt: String
    public var aspectRatio: String
    public init(prompt: String, aspectRatio: String = "auto") { self.prompt = prompt; self.aspectRatio = aspectRatio }
}

public struct ImageEditRequest: Sendable, Equatable, Hashable {
    public var prompt: String
    public var references: [String]
    public var aspectRatio: String
    public init(prompt: String, references: [String], aspectRatio: String = "auto") {
        self.prompt = prompt
        self.references = references
        self.aspectRatio = aspectRatio
    }
}

public struct VideoGenerationRequest: Sendable, Equatable, Hashable {
    public var prompt: String
    public var duration: Int
    public var resolution: String
    public init(prompt: String, duration: Int = 6, resolution: String = "480p") {
        self.prompt = prompt
        self.duration = duration
        self.resolution = resolution
    }
}

public struct GeneratedMedia: Sendable, Equatable, Hashable {
    public var data: Data?
    public var mimeType: String
    public var remoteURL: String?
    public var suggestedFilename: String

    public init(data: Data? = nil, mimeType: String, remoteURL: String? = nil, suggestedFilename: String) {
        self.data = data
        self.mimeType = mimeType
        self.remoteURL = remoteURL
        self.suggestedFilename = suggestedFilename
    }

    public func write(to directory: URL) throws -> URL {
        guard let data else { throw WebMediaToolError.invalidRequest("media has no local bytes; use remoteURL") }
        guard suggestedFilename == URL(fileURLWithPath: suggestedFilename).lastPathComponent,
              !suggestedFilename.isEmpty,
              !suggestedFilename.hasPrefix(".")
        else {
            throw WebMediaToolError.invalidRequest("media filename is not a safe basename")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(suggestedFilename)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func writeToOpenGrokHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let directory = WebFetchClient.defaultArtifactDirectory(environment: environment)
            .appendingPathComponent(mimeType.hasPrefix("video/") ? "videos" : "images", isDirectory: true)
        return try write(to: directory)
    }
}

public struct MediaGenerationClient: Sendable {
    public var configuration: MediaGenerationConfiguration
    public var transport: any HTTPTransport

    public init(configuration: MediaGenerationConfiguration, transport: any HTTPTransport = URLSessionHTTPTransport()) throws {
        guard !configuration.apiKey.isEmpty else { throw WebMediaToolError.invalidConfiguration("media generation requires api_key") }
        guard URL(string: configuration.baseURL)?.scheme != nil else { throw WebMediaToolError.invalidConfiguration("media base_url is invalid") }
        self.configuration = configuration
        self.transport = transport
    }

    public func generateImage(_ request: ImageGenerationRequest) async throws -> GeneratedMedia {
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebMediaToolError.invalidRequest("image_gen prompt is empty") }
        let body: [String: Any] = [
            "model": configuration.imageModel,
            "prompt": request.prompt,
            "n": 1,
            "aspect_ratio": request.aspectRatio,
            "resolution": "1k",
            "response_format": "b64_json"
        ]
        return try await sendMedia(path: "images/generations", body: body, mimeType: "image/jpeg", filename: "image.jpg", tool: "image_gen")
    }

    public func editImage(_ request: ImageEditRequest) async throws -> GeneratedMedia {
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebMediaToolError.invalidRequest("image_edit prompt is empty") }
        guard !request.references.isEmpty else { throw WebMediaToolError.invalidRequest("image_edit requires at least one reference image") }
        let resolvedReferences = try await resolveReferences(request.references)
        var body: [String: Any] = [
            "model": configuration.editModel,
            "prompt": request.prompt,
            "n": 1,
            "resolution": "1k",
            "response_format": "b64_json"
        ]
        if resolvedReferences.count == 1 {
            body["image"] = ["url": resolvedReferences[0]]
        } else {
            body["images"] = resolvedReferences.map { ["url": $0] }
            body["aspect_ratio"] = request.aspectRatio
        }
        return try await sendMedia(path: "images/edits", body: body, mimeType: "image/jpeg", filename: "edited-image.jpg", tool: "image_edit")
    }

    public func generateVideo(_ request: VideoGenerationRequest) async throws -> GeneratedMedia {
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebMediaToolError.invalidRequest("video_gen prompt is empty") }
        guard [6, 10].contains(request.duration) else { throw WebMediaToolError.invalidRequest("video duration must be 6 or 10 seconds") }
        guard ["480p", "720p"].contains(request.resolution) else { throw WebMediaToolError.invalidRequest("video resolution must be 480p or 720p") }
        let body: [String: Any] = [
            "model": configuration.videoModel,
            "prompt": request.prompt,
            "duration": request.duration,
            "resolution": request.resolution
        ]
        let response = try await sendResponse(
            method: .post,
            path: "videos/generations",
            body: body,
            timeout: TimeInterval(configuration.videoTimeoutSeconds),
            tool: "video_gen"
        )
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "top-level value is not an object")
        }
        if let encoded = firstString(in: object, keys: ["b64_json", "b64_data", "base64"]) {
            guard let data = Data(base64Encoded: encoded) else {
                throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "base64 video data is invalid")
            }
            return GeneratedMedia(data: data, mimeType: "video/mp4", suggestedFilename: "video.mp4")
        }
        if let remoteURL = firstString(in: object, keys: ["url", "output_url", "video_url"]) {
            return try await downloadVideo(remoteURL)
        }
        guard let requestID = firstString(in: object, keys: ["request_id", "id"]) else {
            throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "response contained neither request_id nor media")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(configuration.videoTimeoutSeconds))
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: configuration.videoPollIntervalSeconds * 1_000_000_000)
            let poll = try await sendResponse(method: .get, path: "videos/\(requestID)", body: nil, timeout: 30, tool: "video_gen")
            guard let pollObject = try JSONSerialization.jsonObject(with: poll.body) as? [String: Any] else {
                throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "poll response is not an object")
            }
            let status = (pollObject["status"] as? String ?? "").lowercased()
            switch status {
            case "done", "completed", "succeeded":
                if let encoded = firstString(in: pollObject, keys: ["b64_json", "b64_data", "base64"]) {
                    guard let data = Data(base64Encoded: encoded) else {
                        throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "completed video base64 is invalid")
                    }
                    return GeneratedMedia(data: data, mimeType: "video/mp4", suggestedFilename: "video.mp4")
                }
                guard let remoteURL = firstString(in: pollObject, keys: ["url", "output_url", "video_url"]) else {
                    throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "completed poll has no video URL")
                }
                return try await downloadVideo(remoteURL)
            case "failed", "error", "expired":
                throw WebMediaToolError.remoteFailure(tool: "video_gen", status: 422, detail: status)
            default:
                continue
            }
        }
        throw WebMediaToolError.commandTimedOut(command: "video_gen", timeout: TimeInterval(configuration.videoTimeoutSeconds))
    }

    private func sendMedia(path: String, body: [String: Any], mimeType: String, filename: String, tool: String) async throws -> GeneratedMedia {
        let response = try await sendResponse(method: .post, path: path, body: body, timeout: 300, tool: tool)
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw WebMediaToolError.malformedResponse(tool: tool, detail: "top-level value is not an object")
        }
        if let encoded = firstString(in: object, keys: ["b64_json", "b64_data", "base64"]) {
            guard let decoded = Data(base64Encoded: encoded) else { throw WebMediaToolError.malformedResponse(tool: tool, detail: "base64 media data is invalid") }
            return GeneratedMedia(data: decoded, mimeType: mimeType, suggestedFilename: filename)
        }
        if let remoteURL = firstString(in: object, keys: ["url", "output_url", "video_url"]) {
            return GeneratedMedia(mimeType: mimeType, remoteURL: remoteURL, suggestedFilename: filename)
        }
        throw WebMediaToolError.malformedResponse(tool: tool, detail: "response contained neither media data nor a URL")
    }

    private func sendResponse(
        method: HTTPMethod,
        path: String,
        body: [String: Any]?,
        timeout: TimeInterval,
        tool: String
    ) async throws -> HTTPResponse {
        guard let url = URL(string: "\(configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path)") else {
            throw WebMediaToolError.invalidConfiguration("\(tool) endpoint URL is invalid")
        }
        let bodyData: Data?
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else {
                throw WebMediaToolError.invalidRequest("\(tool) request is not valid JSON")
            }
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } else {
            bodyData = nil
        }
        var headers = configuration.extraHeaders
        headers["Authorization"] = "Bearer \(configuration.apiKey)"
        if bodyData != nil { headers["Content-Type"] = "application/json" }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(
                method: method,
                url: url,
                headers: headers,
                body: bodyData,
                timeout: timeout,
                idempotency: method == .get ? .idempotent : .nonIdempotent
            ))
        } catch let error as HTTPError {
            throw WebMediaToolError.http(error)
        } catch {
            throw WebMediaToolError.remoteFailure(tool: tool, status: 0, detail: String(describing: error))
        }
        guard (200..<300).contains(response.metadata.statusCode) || (method == .get && response.metadata.statusCode == 202) else {
            switch response.metadata.statusCode {
            case 401, 403: throw WebMediaToolError.unauthorized(tool: tool)
            case 429: throw WebMediaToolError.rateLimited(tool: tool)
            default: throw WebMediaToolError.remoteFailure(tool: tool, status: response.metadata.statusCode, detail: String(data: response.body.prefix(512), encoding: .utf8) ?? "")
            }
        }
        return response
    }

    private func resolveReferences(_ references: [String]) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self, returning: [String].self) { group in
            for (index, reference) in references.enumerated() {
                group.addTask { (index, try await resolveImageReference(reference)) }
            }
            var resolved: [(Int, String)] = []
            for try await value in group { resolved.append(value) }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func downloadVideo(_ value: String) async throws -> GeneratedMedia {
        guard let url = URL(string: value, relativeTo: URL(string: configuration.baseURL))?.absoluteURL else {
            throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "video URL is invalid")
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: .get, url: url, timeout: 120, idempotency: .idempotent))
        } catch let error as HTTPError {
            throw WebMediaToolError.http(error)
        } catch {
            throw WebMediaToolError.remoteFailure(tool: "video_gen", status: 0, detail: String(describing: error))
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            throw WebMediaToolError.remoteFailure(tool: "video_gen", status: response.metadata.statusCode, detail: "video download failed")
        }
        guard !response.body.isEmpty else {
            throw WebMediaToolError.malformedResponse(tool: "video_gen", detail: "video download was empty")
        }
        return GeneratedMedia(data: response.body, mimeType: "video/mp4", remoteURL: value, suggestedFilename: "video.mp4")
    }
}

private func firstString(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = object[key] as? String, !value.isEmpty { return value }
    }
    if let data = object["data"] as? [[String: Any]] {
        for item in data {
            if let value = firstString(in: item, keys: keys) { return value }
        }
    }
    if let result = object["result"] as? [String: Any] {
        return firstString(in: result, keys: keys)
    }
    if let nested = object["data"] as? [String: Any] {
        return firstString(in: nested, keys: keys)
    }
    for key in ["video", "output", "response"] {
        if let nested = object[key] as? [String: Any],
           let value = firstString(in: nested, keys: keys) {
            return value
        }
    }
    return nil
}

private func resolveImageReference(_ reference: String) async throws -> String {
    let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WebMediaToolError.invalidRequest("image reference is empty") }
    if trimmed.hasPrefix("data:image/") {
        guard let comma = trimmed.firstIndex(of: ",") else {
            throw WebMediaToolError.invalidRequest("image references only support base64 data URLs")
        }
        let header = String(trimmed[..<comma]).lowercased()
        guard header.hasPrefix("data:image/"), header.contains(";base64") else {
            throw WebMediaToolError.invalidRequest("image references only support base64 data URLs")
        }
        let payload = String(trimmed[trimmed.index(after: comma)...])
        guard let data = Data(base64Encoded: payload), !data.isEmpty else {
            throw WebMediaToolError.invalidRequest("image reference contains invalid base64")
        }
        let mime = mimeType(for: data)
        guard mime.hasPrefix("image/") else {
            throw WebMediaToolError.invalidRequest("image reference is not a supported image")
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
    let path: String
    if let fileURL = URL(string: trimmed), fileURL.isFileURL {
        path = fileURL.path
    } else {
        path = trimmed
    }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    } catch {
        throw WebMediaToolError.invalidRequest("image reference is not readable: \(path)")
    }
    guard !data.isEmpty else { throw WebMediaToolError.invalidRequest("image reference contained no data") }
    let mime = mimeType(for: data)
    guard mime.hasPrefix("image/") else { throw WebMediaToolError.invalidRequest("image reference is not a supported image") }
    return "data:\(mime);base64;\(Data(data).base64EncodedString())".replacingOccurrences(of: ";base64;", with: ";base64,")
}
