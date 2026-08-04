import Foundation
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolTypes

public let perplexitySearchAPIBaseURL = "https://api.perplexity.ai"

public enum WebSearchConfig: Codable, Sendable, Equatable, CustomStringConvertible {
    case disabled
    case enabled(
        apiKey: String,
        baseURL: String,
        model: String,
        extraHeaders: [String: String] = [:],
        alphaTestKey: String? = nil
    )
    case perplexity(apiKey: String, baseURL: String = perplexitySearchAPIBaseURL)

    private enum CodingKeys: String, CodingKey {
        case status
        case apiKey = "api_key"
        case baseURL = "base_url"
        case model
        case extraHeaders = "extra_headers"
        case alphaTestKey = "alpha_test_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "disabled":
            self = .disabled
        case "enabled":
            self = .enabled(
                apiKey: try container.decode(String.self, forKey: .apiKey),
                baseURL: try container.decode(String.self, forKey: .baseURL),
                model: try container.decode(String.self, forKey: .model),
                extraHeaders: try container.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:],
                alphaTestKey: try container.decodeIfPresent(String.self, forKey: .alphaTestKey)
            )
        case "perplexity":
            self = .perplexity(
                apiKey: try container.decode(String.self, forKey: .apiKey),
                baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL) ?? perplexitySearchAPIBaseURL
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "unknown web search status")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled:
            try container.encode("disabled", forKey: .status)
        case .enabled(let apiKey, let baseURL, let model, let extraHeaders, let alphaTestKey):
            try container.encode("enabled", forKey: .status)
            try container.encode(apiKey, forKey: .apiKey)
            try container.encode(baseURL, forKey: .baseURL)
            try container.encode(model, forKey: .model)
            if !extraHeaders.isEmpty { try container.encode(extraHeaders, forKey: .extraHeaders) }
            try container.encodeIfPresent(alphaTestKey, forKey: .alphaTestKey)
        case .perplexity(let apiKey, let baseURL):
            try container.encode("perplexity", forKey: .status)
            try container.encode(apiKey, forKey: .apiKey)
            try container.encode(baseURL, forKey: .baseURL)
        }
    }

    public static var `default`: WebSearchConfig { .disabled }

    public var isEnabled: Bool {
        if case .disabled = self { return false }
        return true
    }

    public var isPerplexity: Bool {
        if case .perplexity = self { return true }
        return false
    }

    public func redacted() -> WebSearchConfig {
        switch self {
        case .disabled:
            return .disabled
        case .enabled(_, let baseURL, let model, let extraHeaders, _):
            return .enabled(apiKey: "***REDACTED***", baseURL: baseURL, model: model, extraHeaders: extraHeaders)
        case .perplexity(_, let baseURL):
            return .perplexity(apiKey: "***REDACTED***", baseURL: baseURL)
        }
    }

    public var description: String {
        switch redacted() {
        case .disabled:
            return "WebSearchConfig.disabled"
        case .enabled(_, let baseURL, let model, let extraHeaders, _):
            return "WebSearchConfig.enabled(apiKey: \"***REDACTED***\", baseURL: \"\(baseURL)\", model: \"\(model)\", extraHeaders: \(extraHeaders))"
        case .perplexity(_, let baseURL):
            return "WebSearchConfig.perplexity(apiKey: \"***REDACTED***\", baseURL: \"\(baseURL)\")"
        }
    }
}

public struct WebSearchRequest: Sendable, Equatable, Hashable {
    public var query: String
    public var allowedDomains: [String]?

    public init(query: String, allowedDomains: [String]? = nil) throws {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { throw WebMediaToolError.invalidRequest("web_search query is empty") }
        self.query = normalizedQuery
        self.allowedDomains = allowedDomains?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct WebSearchCitation: Sendable, Equatable, Hashable, Codable {
    public var title: String
    public var url: String

    public init(title: String = "", url: String) {
        self.title = title
        self.url = url
    }
}

public struct WebSearchResult: Sendable, Equatable, Hashable, Codable {
    public var content: String
    public var citations: [WebSearchCitation]

    public init(content: String, citations: [WebSearchCitation] = []) {
        self.content = content
        self.citations = citations
    }

    public var citationURLs: [String] { citations.map(\.url) }
}

public struct WebSearchClient: Sendable {
    public var configuration: WebSearchConfig
    public var transport: any HTTPTransport

    public init(
        configuration: WebSearchConfig,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) throws {
        switch configuration {
        case .disabled:
            throw WebMediaToolError.invalidConfiguration("cannot create WebSearchClient from disabled config")
        case .enabled(let apiKey, let baseURL, let model, _, _):
            guard !apiKey.isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WebMediaToolError.invalidConfiguration("enabled web search requires api_key and model")
            }
            guard URL(string: baseURL)?.scheme != nil else {
                throw WebMediaToolError.invalidConfiguration("web search base_url is invalid")
            }
        case .perplexity(let apiKey, let baseURL):
            guard !apiKey.isEmpty else { throw WebMediaToolError.invalidConfiguration("Perplexity requires api_key") }
            guard URL(string: baseURL)?.scheme != nil else {
                throw WebMediaToolError.invalidConfiguration("Perplexity base_url is invalid")
            }
        }
        self.configuration = configuration
        self.transport = transport
    }

    public func search(_ request: WebSearchRequest) async throws -> WebSearchResult {
        switch configuration {
        case .enabled(let apiKey, let baseURL, let model, let extraHeaders, _):
            let body: [String: Any] = [
                "model": model,
                "input": request.query,
                "store": false,
                "temperature": 0.1,
                "top_p": 0.95,
                "max_output_tokens": 8_192,
                "tools": [[
                    "type": "web_search_preview",
                    "filters": request.allowedDomains.map { ["allowed_domains": $0] } ?? [:]
                ]]
            ]
            let response = try await send(
                tool: "web_search",
                url: endpoint(baseURL, path: "responses"),
                apiKey: apiKey,
                extraHeaders: extraHeaders,
                body: body
            )
            return try parseResponsesResult(response)
        case .perplexity(let apiKey, let baseURL):
            let body: [String: Any] = [
                "query": request.query,
                "max_results": 10,
                "max_tokens_per_page": 1_024
            ]
            var requestBody = body
            if let domains = request.allowedDomains { requestBody["search_domain_filter"] = domains }
            let response = try await send(
                tool: "web_search",
                url: endpoint(baseURL, path: "search"),
                apiKey: apiKey,
                extraHeaders: [:],
                body: requestBody
            )
            return try parsePerplexityResult(response)
        case .disabled:
            throw WebMediaToolError.invalidConfiguration("web search is disabled")
        }
    }

    public func search(query: String, allowedDomains: [String]? = nil) async throws -> WebSearchResult {
        try await search(WebSearchRequest(query: query, allowedDomains: allowedDomains))
    }

    public func xSearch(query: String) async throws -> WebSearchResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw WebMediaToolError.invalidRequest("x_search query is empty")
        }
        guard case .enabled(let apiKey, let baseURL, let model, let extraHeaders, _) = configuration else {
            throw WebMediaToolError.invalidRequest("x_search requires the xAI backend")
        }
        let body: [String: Any] = [
            "model": model,
            "input": normalizedQuery,
            "store": false,
            "temperature": 0.1,
            "top_p": 0.95,
            "max_output_tokens": 8_192,
            "tools": [["type": "x_search"]]
        ]
        let response = try await send(tool: "x_search", url: endpoint(baseURL, path: "responses"), apiKey: apiKey, extraHeaders: extraHeaders, body: body)
        return try parseResponsesResult(response)
    }

    private func send(
        tool: String,
        url: URL?,
        apiKey: String,
        extraHeaders: [String: String],
        body: [String: Any]
    ) async throws -> [String: Any] {
        guard let url else { throw WebMediaToolError.invalidConfiguration("\(tool) endpoint URL is invalid") }
        guard JSONSerialization.isValidJSONObject(body) else { throw WebMediaToolError.invalidRequest("\(tool) request is not valid JSON") }
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var headers = extraHeaders
        headers["Authorization"] = "Bearer \(apiKey)"
        headers["Content-Type"] = "application/json"
        let request = HTTPRequest(method: .post, url: url, headers: headers, body: bodyData, timeout: 60, idempotency: .nonIdempotent)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HTTPError {
            throw WebMediaToolError.http(error)
        } catch {
            throw WebMediaToolError.remoteFailure(tool: tool, status: 0, detail: String(describing: error))
        }
        let detail = String(data: response.body, encoding: .utf8) ?? ""
        guard (200..<300).contains(response.metadata.statusCode) else {
            switch response.metadata.statusCode {
            case 401, 403: throw WebMediaToolError.unauthorized(tool: tool)
            case 429: throw WebMediaToolError.rateLimited(tool: tool)
            default: throw WebMediaToolError.remoteFailure(tool: tool, status: response.metadata.statusCode, detail: detail.prefix(512).description)
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw WebMediaToolError.malformedResponse(tool: tool, detail: "top-level value is not an object")
        }
        return object
    }
}

private func parseResponsesResult(_ response: [String: Any]) throws -> WebSearchResult {
    let content = response["output_text"] as? String ?? extractOutputText(response["output"])
    let citations = uniqueCitations(extractCitationValues(response))
    return WebSearchResult(content: content.isEmpty ? "No search results found." : content, citations: citations)
}

private func parsePerplexityResult(_ response: [String: Any]) throws -> WebSearchResult {
    guard let results = response["results"] as? [[String: Any]], !results.isEmpty else {
        throw WebMediaToolError.malformedResponse(tool: "web_search", detail: "Perplexity returned no results")
    }
    var content = "Ranked web search results:\n"
    var citations: [WebSearchCitation] = []
    var seen = Set<String>()
    for (index, result) in results.enumerated() {
        let title = result["title"] as? String ?? "Untitled result"
        let url = result["url"] as? String ?? ""
        let snippet = result["snippet"] as? String ?? ""
        let date = (result["date"] as? String) ?? (result["last_updated"] as? String) ?? "Unavailable"
        content += "\n\(index + 1). \(title)\nURL: \(url)\nDate: \(date)\nSnippet: \(snippet)\n"
        if !url.isEmpty, seen.insert(url).inserted { citations.append(WebSearchCitation(title: title, url: url)) }
    }
    return WebSearchResult(content: content, citations: citations)
}

private func extractOutputText(_ value: Any?) -> String {
    guard let values = value as? [[String: Any]] else { return "" }
    var pieces: [String] = []
    for item in values {
        if let content = item["content"] as? [[String: Any]] {
            for part in content {
                if let text = part["text"] as? String { pieces.append(text) }
                if let text = part["output_text"] as? String { pieces.append(text) }
            }
        }
        if let text = item["text"] as? String { pieces.append(text) }
        if let text = item["output_text"] as? String { pieces.append(text) }
    }
    return pieces.joined()
}

private func extractCitationValues(_ value: Any) -> [WebSearchCitation] {
    var citations: [WebSearchCitation] = []
    if let object = value as? [String: Any] {
        if let url = object["url"] as? String,
           !url.isEmpty,
           let type = object["type"] as? String,
           type.lowercased().contains("citation") {
            citations.append(WebSearchCitation(title: object["title"] as? String ?? "", url: url))
        }
        for child in object.values { citations.append(contentsOf: extractCitationValues(child)) }
    } else if let array = value as? [Any] {
        for child in array { citations.append(contentsOf: extractCitationValues(child)) }
    }
    return citations
}

private func uniqueCitations(_ citations: [WebSearchCitation]) -> [WebSearchCitation] {
    var seen = Set<String>()
    return citations.filter { seen.insert($0.url).inserted }
}

private func endpoint(_ baseURL: String, path: String) -> URL? {
    URL(string: "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path)")
}

public enum WebMediaToolCatalog {
    public static let descriptions: [ToolDescription] = [
        ToolDescription(name: "web_search", description: "Search the web and return a synthesized answer with source citations.")
            .withKind("web_search")
            .withArgumentsSchema(.object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("The search query.")]),
                    "allowed_domains": .object(["type": .array([.string("string")]), "description": .string("Optional domains to restrict the search to.")])
                ]),
                "required": .array([.string("query")])
            ])),
        ToolDescription(name: "web_fetch", description: "Fetch the content of a specific public URL and return it as markdown.")
            .withKind("web_fetch")
            .withArgumentsSchema(.object([
                "type": .string("object"),
                "properties": .object(["url": .object(["type": .string("string"), "description": .string("The URL to fetch content from.")])]),
                "required": .array([.string("url")])
            ])),
        ToolDescription(name: "x_search", description: "Search public posts on X using the configured xAI Responses API.")
            .withKind("web_search")
            .withArgumentsSchema(.object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("The X search query.")])
                ]),
                "required": .array([.string("query")])
            ])),
        ToolDescription(name: "image_gen", description: "Generate a new image from a text description using the configured image API.")
            .withKind("image_gen")
            .withArgumentsSchema(.object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string")]),
                    "aspect_ratio": .object(["type": .string("string")])
                ]),
                "required": .array([.string("prompt")])
            ])),
        ToolDescription(name: "image_edit", description: "Edit or transform one or more reference images using the configured image API.")
            .withKind("image_gen")
            .withArgumentsSchema(.object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string")]),
                    "image": .object(["type": .array([.string("string")])]),
                    "aspect_ratio": .object(["type": .string("string")])
                ]),
                "required": .array([.string("prompt"), .string("image")])
            ])),
        ToolDescription(name: "video_gen", description: "Generate a video from a text description using the configured media API.")
            .withKind("video_gen")
            .withArgumentsSchema(.object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string")]),
                    "duration": .object(["type": .string("integer")]),
                    "resolution": .object(["type": .string("string")])
                ]),
                "required": .array([.string("prompt")])
            ]))
    ]
}
