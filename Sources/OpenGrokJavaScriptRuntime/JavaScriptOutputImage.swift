// JavaScriptOutputImage.swift
//
// `image()` / `generatedImage()` argument normalization. Ported from
// `crates/codegen/xai-grok-code-mode/src/runtime/value.rs`
// (`normalize_output_image`, `parse_non_mcp_output_image`,
// `parse_mcp_output_image`, `parse_image_detail_value`).
//
// The Rust version inspects the live V8 value; this port inspects the
// value after the same `JSON.stringify` round-trip the rest of the bridge
// uses, which observes the same object shapes (a `toJSON`-bearing exotic
// object is the only divergence, and neither engine promises anything
// there).

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

enum JavaScriptOutputImage {
    static let expectsMessage =
        "image expects a non-empty image URL string, an object with image_url and optional detail, or a raw MCP image block"
    static let remoteURLError =
        "Tool call failed: remote image URLs are not supported in tool outputs. Pass a base64 data URI instead"
    static let invalidURLError =
        "Tool call failed: invalid image output. Pass a base64 data URI instead"
    static let detailError = "image detail must be one of: auto, low, high, original"
    private static let imageDetailMetaKey = "codex/imageDetail"

    /// Normalize one `image()` argument into a content item, or return the
    /// error text the helper should throw.
    static func normalize(
        value: JSONValue?,
        detailOverride: String?
    ) -> Result<FunctionCallOutputContentItem, CodeModeError> {
        let parsed: (imageURL: String, detail: String?)
        switch value {
        case .string(let text):
            parsed = (text, nil)
        case .object(let fields):
            switch parseObject(fields) {
            case .success(let value): parsed = value
            case .failure(let error): return .failure(error)
            }
        default:
            return .failure(CodeModeError(expectsMessage))
        }

        let imageURL = parsed.imageURL
        if imageURL.isEmpty { return .failure(CodeModeError(expectsMessage)) }

        // Only `data:` URLs are valid tool-output images. Remote http(s)
        // gets a specific error; everything else (file paths, bare
        // strings, other schemes) is an invalid image output.
        guard let schemeEnd = imageURL.firstIndex(of: ":") else {
            return .failure(CodeModeError(invalidURLError))
        }
        let scheme = imageURL[imageURL.startIndex..<schemeEnd].lowercased()
        if scheme == "http" || scheme == "https" { return .failure(CodeModeError(remoteURLError)) }
        if scheme != "data" { return .failure(CodeModeError(invalidURLError)) }

        let detailText = detailOverride ?? parsed.detail
        let detail: ImageDetail
        if let detailText {
            switch detailText.lowercased() {
            case "auto": detail = .auto
            case "low": detail = .low
            case "high": detail = .high
            case "original": detail = .original
            default: return .failure(CodeModeError(detailError))
            }
        } else {
            detail = DEFAULT_IMAGE_DETAIL
        }
        return .success(.inputImage(imageUrl: imageURL, detail: detail))
    }

    /// The `output_hint` field `generatedImage()` appends as extra text.
    /// Mirrors `generated_image_output_hint` (runtime/callbacks.rs:164).
    static func generatedImageOutputHint(value: JSONValue?) -> Result<String?, CodeModeError> {
        guard case .object(let fields)? = value else {
            return .failure(CodeModeError("generatedImage expects an image generation result object"))
        }
        guard let hint = fields["output_hint"], !hint.isNull else { return .success(nil as String?) }
        guard case .string(let text) = hint else {
            return .failure(CodeModeError("generatedImage output_hint must be a string when provided"))
        }
        return .success(text)
    }

    // MARK: - Object shapes

    private static func parseObject(
        _ fields: [String: JSONValue]
    ) -> Result<(String, String?), CodeModeError> {
        if let imageURL = fields["image_url"], !imageURL.isNull {
            guard case .string(let text) = imageURL else { return .failure(CodeModeError(expectsMessage)) }
            switch parseDetail(fields["detail"]) {
            case .success(let detail): return .success((text, detail))
            case .failure(let error): return .failure(error)
            }
        }
        return parseMCPImage(fields)
    }

    private static func parseDetail(_ value: JSONValue?) -> Result<String?, CodeModeError> {
        switch value {
        case nil, .null: return .success(nil as String?)
        case .string(let text): return .success(text)
        default: return .failure(CodeModeError("image detail must be a string when provided"))
        }
    }

    private static func parseMCPImage(
        _ fields: [String: JSONValue]
    ) -> Result<(String, String?), CodeModeError> {
        guard case .string(let itemType)? = fields["type"] else {
            return .failure(CodeModeError(expectsMessage))
        }
        guard itemType == "image" else {
            return .failure(CodeModeError("image only accepts MCP image blocks, got \"\(itemType)\""))
        }
        guard case .string(let data)? = fields["data"], !data.isEmpty else {
            return .failure(CodeModeError("image expected MCP image data"))
        }

        let imageURL: String
        if data.lowercased().hasPrefix("data:") {
            imageURL = data
        } else {
            var mimeType = "application/octet-stream"
            if case .string(let declared)? = fields["mimeType"] ?? fields["mime_type"],
                !declared.isEmpty
            {
                mimeType = declared
            }
            imageURL = "data:\(mimeType);base64,\(data)"
        }

        var detail: String?
        if case .object(let meta)? = fields["_meta"],
            case .string(let declared)? = meta[imageDetailMetaKey],
            ["auto", "low", "high", "original"].contains(declared)
        {
            detail = declared
        }
        return .success((imageURL, detail))
    }
}
