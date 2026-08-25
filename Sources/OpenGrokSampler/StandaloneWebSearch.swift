import Foundation
import OpenGrokShared

/// Provider-local `/alpha/search` request, separate from the model-facing tool schema.
public struct StandaloneSearchRequest: Codable, Sendable, Equatable {
    public var id: String
    public var model: String
    public var reasoning: JSONValue?
    public var input: StandaloneSearchInput?
    public var commands: JSONValue
    public var settings: StandaloneSearchSettings
    public var maxOutputTokens: UInt64?

    public init(
        id: String,
        model: String,
        reasoning: JSONValue? = nil,
        input: StandaloneSearchInput? = nil,
        commands: JSONValue,
        settings: StandaloneSearchSettings,
        maxOutputTokens: UInt64? = nil
    ) {
        self.id = id
        self.model = model
        self.reasoning = reasoning
        self.input = input
        self.commands = commands
        self.settings = settings
        self.maxOutputTokens = maxOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case reasoning
        case input
        case commands
        case settings
        case maxOutputTokens = "max_output_tokens"
    }
}

public enum StandaloneSearchInput: Codable, Sendable, Equatable {
    case text(String)
    case items([StandaloneSearchMessage])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .items(try container.decode([StandaloneSearchMessage].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .items(let items):
            try container.encode(items)
        }
    }
}

public struct StandaloneSearchMessage: Codable, Sendable, Equatable {
    public var type: StandaloneSearchMessageType
    public var role: StandaloneSearchRole
    public var content: [StandaloneSearchContent]

    public init(
        type: StandaloneSearchMessageType = .message,
        role: StandaloneSearchRole,
        content: [StandaloneSearchContent]
    ) {
        self.type = type
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Self {
        Self(role: .user, content: [.inputText(text: text)])
    }

    public static func assistant(_ text: String) -> Self {
        Self(role: .assistant, content: [.outputText(text: text)])
    }
}

public enum StandaloneSearchMessageType: String, Codable, Sendable, Equatable {
    case message
}

public enum StandaloneSearchRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

public enum StandaloneSearchContent: Codable, Sendable, Equatable {
    case inputText(text: String)
    case outputText(text: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        switch try container.decode(String.self, forKey: .type) {
        case "input_text":
            self = .inputText(text: text)
        case "output_text":
            self = .outputText(text: text)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown standalone search content type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .outputText(let text):
            try container.encode("output_text", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

public struct StandaloneSearchSettings: Codable, Sendable, Equatable {
    public var userLocation: StandaloneSearchApproximateLocation?
    public var searchContextSize: StandaloneSearchContextSize?
    public var filters: StandaloneSearchFilters?
    public var imageSettings: StandaloneSearchImageSettings?
    public var allowedCallers: [StandaloneSearchCaller]?
    public var externalWebAccess: StandaloneExternalWebAccess?

    public init(
        userLocation: StandaloneSearchApproximateLocation? = nil,
        searchContextSize: StandaloneSearchContextSize? = nil,
        filters: StandaloneSearchFilters? = nil,
        imageSettings: StandaloneSearchImageSettings? = nil,
        allowedCallers: [StandaloneSearchCaller]? = nil,
        externalWebAccess: StandaloneExternalWebAccess? = nil
    ) {
        self.userLocation = userLocation
        self.searchContextSize = searchContextSize
        self.filters = filters
        self.imageSettings = imageSettings
        self.allowedCallers = allowedCallers
        self.externalWebAccess = externalWebAccess
    }

    public static func directWithExternalWebAccess() -> Self {
        Self(allowedCallers: [.direct], externalWebAccess: .boolean(true))
    }

    private enum CodingKeys: String, CodingKey {
        case userLocation = "user_location"
        case searchContextSize = "search_context_size"
        case filters
        case imageSettings = "image_settings"
        case allowedCallers = "allowed_callers"
        case externalWebAccess = "external_web_access"
    }
}

public struct StandaloneSearchApproximateLocation: Codable, Sendable, Equatable {
    public var type: StandaloneSearchLocationType
    public var country: String?
    public var region: String?
    public var city: String?
    public var timezone: String?

    public init(
        type: StandaloneSearchLocationType = .approximate,
        country: String? = nil,
        region: String? = nil,
        city: String? = nil,
        timezone: String? = nil
    ) {
        self.type = type
        self.country = country
        self.region = region
        self.city = city
        self.timezone = timezone
    }
}

public enum StandaloneSearchLocationType: String, Codable, Sendable, Equatable {
    case approximate
}

public enum StandaloneSearchContextSize: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
}

public struct StandaloneSearchFilters: Codable, Sendable, Equatable {
    public var allowedDomains: [String]?
    public var blockedDomains: [String]?

    public init(allowedDomains: [String]? = nil, blockedDomains: [String]? = nil) {
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
    }

    private enum CodingKeys: String, CodingKey {
        case allowedDomains = "allowed_domains"
        case blockedDomains = "blocked_domains"
    }
}

public struct StandaloneSearchImageSettings: Codable, Sendable, Equatable {
    public var maxResults: UInt64?
    public var caption: Bool?

    public init(maxResults: UInt64? = nil, caption: Bool? = nil) {
        self.maxResults = maxResults
        self.caption = caption
    }

    private enum CodingKeys: String, CodingKey {
        case maxResults = "max_results"
        case caption
    }
}

public enum StandaloneExternalWebAccessMode: String, Codable, Sendable, Equatable {
    case cached
    case indexed
    case live
}

public enum StandaloneExternalWebAccess: Codable, Sendable, Equatable {
    case boolean(Bool)
    case mode(StandaloneExternalWebAccessMode)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .mode(try container.decode(StandaloneExternalWebAccessMode.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value):
            try container.encode(value)
        case .mode(let value):
            try container.encode(value)
        }
    }
}

public enum StandaloneSearchCaller: String, Codable, Sendable, Equatable {
    case direct
    case shell
    case codeInterpreter = "code_interpreter"
}

public struct StandaloneSearchResponse: Codable, Sendable, Equatable {
    public var encryptedOutput: String?
    public var output: String
    /// Opaque results retain fields introduced by newer endpoint variants.
    public var results: [JSONValue]?

    public init(encryptedOutput: String? = nil, output: String, results: [JSONValue]? = nil) {
        self.encryptedOutput = encryptedOutput
        self.output = output
        self.results = results
    }

    private enum CodingKeys: String, CodingKey {
        case encryptedOutput = "encrypted_output"
        case output
        case results
    }
}
