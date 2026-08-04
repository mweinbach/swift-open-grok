import Foundation

public let DEFAULT_SAMPLE_RATE: UInt32 = 16_000

public struct VoiceConfig: Codable, Equatable, Sendable {
    public var apiBase: String
    public var sttWebSocketPath: String
    public var language: String
    public var sampleRate: UInt32
    public var sttEndpointingMilliseconds: UInt32
    public var sttInterimResults: Bool
    public var clientIdentifier: String
    public var userAgent: String

    public init(
        apiBase: String = "https://api.x.ai",
        sttWebSocketPath: String = "/v1/stt",
        language: String = "en",
        sampleRate: UInt32 = DEFAULT_SAMPLE_RATE,
        sttEndpointingMilliseconds: UInt32 = 400,
        sttInterimResults: Bool = true,
        clientIdentifier: String = "",
        userAgent: String = ""
    ) {
        self.apiBase = apiBase
        self.sttWebSocketPath = sttWebSocketPath
        self.language = language
        self.sampleRate = sampleRate
        self.sttEndpointingMilliseconds = sttEndpointingMilliseconds
        self.sttInterimResults = sttInterimResults
        self.clientIdentifier = clientIdentifier
        self.userAgent = userAgent
    }

    private enum CodingKeys: String, CodingKey {
        case apiBase
        case sttWebSocketPath
        case language
        case sampleRate
        case sttEndpointingMilliseconds
        case sttInterimResults
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            apiBase: try values.decodeIfPresent(String.self, forKey: .apiBase) ?? "https://api.x.ai",
            sttWebSocketPath: try values.decodeIfPresent(String.self, forKey: .sttWebSocketPath) ?? "/v1/stt",
            language: try values.decodeIfPresent(String.self, forKey: .language) ?? "en",
            sampleRate: try values.decodeIfPresent(UInt32.self, forKey: .sampleRate) ?? DEFAULT_SAMPLE_RATE,
            sttEndpointingMilliseconds: try values.decodeIfPresent(UInt32.self, forKey: .sttEndpointingMilliseconds) ?? 400,
            sttInterimResults: try values.decodeIfPresent(Bool.self, forKey: .sttInterimResults) ?? true
        )
    }

    public static func fromConfigTable(
        _ root: [String: [String: String]],
        resolvedEndpointsBase: String? = nil
    ) -> VoiceConfig {
        var result = VoiceConfig()
        let voice = root["voice"] ?? [:]
        result.apiBase = firstNonEmpty(
            voice["api_base"],
            root["endpoints"]?["xai_api_base_url"],
            resolvedEndpointsBase
        )?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? result.apiBase
        if let value = voice["stt_ws_path"]?.trimmedNonEmpty {
            result.sttWebSocketPath = value
        }
        if let value = voice["language"]?.trimmedNonEmpty {
            result.language = value
        }
        if let value = voice["sample_rate"].flatMap(UInt32.init) {
            result.sampleRate = value
        }
        if let value = voice["stt_endpointing_ms"].flatMap(UInt32.init) {
            result.sttEndpointingMilliseconds = value
        }
        if let value = voice["stt_interim_results"].flatMap(Bool.init) {
            result.sttInterimResults = value
        }
        return result
    }

    public func sttWebSocketURL() throws -> URL {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lower = base.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("ws://") {
            throw VoiceError.configuration(
                "insecure voice api_base \(apiBase.debugDescription): voice requires a TLS endpoint (https:// / wss://)"
            )
        }
        let rest: String
        if lower.hasPrefix("https://") || lower.hasPrefix("wss://") {
            rest = String(base.dropFirst(8))
        } else {
            rest = base
        }
        var path = sttWebSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rest.hasSuffix("/v1"), path.hasPrefix("v1/") {
            path = String(path.dropFirst("v1/".count))
        }
        guard let url = URL(string: "wss://\(rest)/\(path)"), url.host != nil else {
            throw VoiceError.configuration("invalid voice STT endpoint")
        }
        return url
    }

    public func makeTranscriptionRequest(bearer: String) throws -> VoiceTranscriptionRequest {
        guard !bearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bearer.validHeaderValue != nil else {
            throw VoiceError.authentication("empty or invalid bearer token")
        }
        var components = URLComponents(url: try sttWebSocketURL(), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: sttInterimResults ? "true" : "false"),
            URLQueryItem(name: "language", value: languageForAPI(language)),
            URLQueryItem(name: "endpointing", value: String(sttEndpointingMilliseconds))
        ]
        guard let url = components?.url else {
            throw VoiceError.configuration("invalid voice STT URL")
        }
        var headers = ["Authorization": "Bearer \(bearer)"]
        if let value = clientIdentifier.validHeaderValue {
            headers["x-grok-client-identifier"] = value
        }
        if let value = userAgent.validHeaderValue {
            headers["User-Agent"] = value
        }
        return VoiceTranscriptionRequest(
            url: url,
            headers: headers,
            format: VoiceAudioFormat(sampleRate: sampleRate)
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { $0?.trimmedNonEmpty }.first
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var validHeaderValue: String? {
        guard !isEmpty else { return nil }
        return unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
            ? nil
            : self
    }
}
