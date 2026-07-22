// WireCodec.swift
//
// Wire-form parsers for catalog enums. OpenGrokSamplingTypes uses Swift
// camelCase raw values for some enums, while Rust emits snake_case
// (`chat_completions`, `code_mode_only`). Catalog decoding always goes
// through these helpers so embedded JSON and remote payloads remain
// wire-compatible without depending on SamplingTypes encode fixes.

import Foundation
import OpenGrokSamplingTypes

enum WireCodec {
    /// Decode `ApiBackend` from a Rust snake_case (or camelCase) string.
    static func apiBackend(_ raw: String?) -> ApiBackend? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "chat_completions", "chatcompletions": return .chatCompletions
        case "responses": return .responses
        case "messages": return .messages
        default: return nil
        }
    }

    static func apiBackendWire(_ backend: ApiBackend) -> String {
        switch backend {
        case .chatCompletions: return "chat_completions"
        case .responses: return "responses"
        case .messages: return "messages"
        }
    }

    static func toolMode(_ raw: String?) -> ToolMode? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "direct": return .direct
        case "code_mode", "codemode": return .codeMode
        case "code_mode_only", "codemodeonly": return .codeModeOnly
        default: return nil
        }
    }

    static func toolModeWire(_ mode: ToolMode) -> String {
        switch mode {
        case .direct: return "direct"
        case .codeMode: return "code_mode"
        case .codeModeOnly: return "code_mode_only"
        }
    }

    static func authScheme(_ raw: String?) -> AuthScheme? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "bearer": return .bearer
        case "x_api_key", "xapikey", "x-api-key": return .xApiKey
        default: return nil
        }
    }

    static func reasoningEffort(_ raw: String?) -> ReasoningEffort? {
        guard let raw else { return nil }
        return ReasoningEffort(rawValue: raw.lowercased())
    }

    static func reasoningSummary(_ raw: String?) -> ReasoningSummary? {
        guard let raw else { return nil }
        return ReasoningSummary(rawValue: raw.lowercased())
    }
}
