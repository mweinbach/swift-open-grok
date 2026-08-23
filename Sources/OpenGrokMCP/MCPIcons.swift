import Foundation
import OpenGrokShared

/// MCP icon limits mirror the Rust protocol bridge; icon sources are metadata
/// only and are never resolved, fetched, or decoded by the agent.
/// Upstream: `xai-grok-mcp/src/servers.rs:100-176` at `ac7c8953`.
public enum MCPIconLimits: Sendable {
    public static let maximumIconsPerEntity = 8
    public static let maximumSourceBytes = 64 * 1_024
    public static let maximumMIMETypeBytes = 128
    public static let maximumSizes = 8
    public static let maximumSizeTokenBytes = 32
}

public enum MCPIconTheme: String, Codable, Sendable, Hashable, CaseIterable {
    case light
    case dark
}

public struct MCPIcon: Codable, Sendable, Hashable {
    public let src: String
    public let mimeType: String?
    public let sizes: [String]?
    public let theme: MCPIconTheme?

    public init?(
        src: String,
        mimeType: String? = nil,
        sizes: [String]? = nil,
        theme: MCPIconTheme? = nil
    ) {
        let source = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              source.utf8.count <= MCPIconLimits.maximumSourceBytes,
              source.hasPrefix("https://") || source.hasPrefix("data:image/")
        else {
            return nil
        }
        self.src = source

        if let mimeType {
            let trimmed = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
            self.mimeType = trimmed.isEmpty || trimmed.utf8.count > MCPIconLimits.maximumMIMETypeBytes
                ? nil : trimmed
        } else {
            self.mimeType = nil
        }

        let normalizedSizes = sizes?.lazy.compactMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.utf8.count <= MCPIconLimits.maximumSizeTokenBytes
            else { return nil }
            return trimmed
        }.prefix(MCPIconLimits.maximumSizes).map { $0 }
        self.sizes = normalizedSizes?.isEmpty == false ? normalizedSizes : nil
        self.theme = theme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(String.self, forKey: .src)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let sizes = try container.decodeIfPresent([String].self, forKey: .sizes)
        let themeName = try container.decodeIfPresent(String.self, forKey: .theme)
        let theme = themeName.flatMap(MCPIconTheme.init(rawValue:))
        guard let sanitized = MCPIcon(src: source, mimeType: mimeType, sizes: sizes, theme: theme) else {
            throw DecodingError.dataCorruptedError(
                forKey: .src,
                in: container,
                debugDescription: "MCP icon source is insecure, empty, or exceeds its byte limit"
            )
        }
        self = sanitized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(src, forKey: .src)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(sizes, forKey: .sizes)
        try container.encodeIfPresent(theme, forKey: .theme)
    }

    public static func sanitize(_ values: [JSONValue]) -> [MCPIcon] {
        var icons: [MCPIcon] = []
        for value in values {
            guard let object = value.objectValue,
                  let source = object["src"]?.stringValue
            else { continue }
            let sizes = object["sizes"]?.arrayValue?.compactMap(\.stringValue)
            let theme = object["theme"]?.stringValue.flatMap(MCPIconTheme.init(rawValue:))
            guard let icon = MCPIcon(
                src: source,
                mimeType: object["mimeType"]?.stringValue,
                sizes: sizes,
                theme: theme
            ) else { continue }
            icons.append(icon)
            if icons.count == MCPIconLimits.maximumIconsPerEntity { break }
        }
        return icons
    }

    private enum CodingKeys: String, CodingKey {
        case src
        case mimeType
        case sizes
        case theme
    }
}
