// Response.swift
//
// Function-call output content items and the default image-detail
// constant. Ported from
// `crates/codegen/xai-grok-code-mode-protocol/src/response.rs`.
//
// These types describe what a `text(...)` / `image(...)` /
// `generatedImage(...)` helper inside an `exec` JS isolate can append to
// the running cell's output. The exec tool description (see
// `Description.swift`) documents the helper signatures; the runtime crate
// (`OpenGrokCodeMode`) produces these items when the JS isolate calls
// them.

import Foundation

/// Image detail hint carried on `FunctionCallOutputContentItem.inputImage`.
///
/// Wire form is lowercase (matches the Rust `#[serde(rename_all =
/// "lowercase")]`). The `auto` / `low` / `high` / `original` values
/// match the OpenAI image-detail vocabulary.
public enum ImageDetail: Hashable, Sendable, Codable, Equatable {
    case auto
    case low
    case high
    case original

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "auto": self = .auto
        case "low": self = .low
        case "high": self = .high
        case "original": self = .original
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown ImageDetail: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .low: try c.encode("low")
        case .high: try c.encode("high")
        case .original: try c.encode("original")
        }
    }
}

/// Default image detail when an MCP image block does not specify one.
public let DEFAULT_IMAGE_DETAIL: ImageDetail = .high

/// One content item emitted by a code-mode cell, surfaced to the model as
/// a `function_call_output` content block.
///
/// Internally tagged with `tag = "type"` and snake_case variants
/// (`#[serde(tag = "type", rename_all = "snake_case")]` in Rust). The
/// `input_text` variant carries plain text; the `input_image` variant
/// carries a base64-encoded `data:` URL plus an optional detail hint
/// (defaults to `DEFAULT_IMAGE_DETAIL` at the runtime layer when absent).
public enum FunctionCallOutputContentItem: Hashable, Sendable, Codable, Equatable {
    case inputText(text: String)
    case inputImage(imageUrl: String, detail: ImageDetail?)

    private enum Tag: String, Codable {
        case inputText = "input_text"
        case inputImage = "input_image"
    }
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
        case detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .inputText:
            self = .inputText(text: try c.decode(String.self, forKey: .text))
        case .inputImage:
            self = .inputImage(
                imageUrl: try c.decode(String.self, forKey: .imageUrl),
                // `#[serde(default, skip_serializing_if = "Option::is_none")]`.
                detail: try c.decodeIfPresent(ImageDetail.self, forKey: .detail)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try c.encode(Tag.inputText, forKey: .type)
            try c.encode(text, forKey: .text)
        case .inputImage(let imageUrl, let detail):
            try c.encode(Tag.inputImage, forKey: .type)
            try c.encode(imageUrl, forKey: .imageUrl)
            try c.encodeIfPresent(detail, forKey: .detail)
        }
    }
}
