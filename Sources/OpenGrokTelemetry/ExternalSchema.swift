// ExternalSchema.swift
//
// Open Grok — Swift port of the external OTEL stream's typed-key schema,
// content gating, and export-time fail-closed validator.
//
// Upstream reference (`~/Projects/grok-build` @ `9ed09e2a`):
//   - `ExternalKey::as_str` wire names
//     `crates/codegen/xai-grok-telemetry/src/external/schema.rs:169-239`
//   - `gate_for_key`  `external/schema.rs:329-337`
//   - `Gate`          `external/schema.rs:387-394`
//   - emit-time gate application  `external/emit.rs:62-107`
//   - `record_is_clean` fail-closed validator  `external/redact.rs:44-100`
//   - truncation constants  `external/truncate.rs:9-24`
//   - `sanitize_tool_name` / `file_extension`  `external/schema.rs:614-635`
//
// Two independent chokepoints, both ported, because upstream is explicit that
// the second one is the authority (`external/redact.rs:1-10`): emit-time
// gating decides what is *built*, and export-time validation decides what is
// *sent*. A schema bug in the first is contained by the second, and the
// second's response to any doubt is to drop the record — never to scrub it in
// place and send the remainder.

import Foundation
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokTracing

// MARK: - Typed attribute keys

/// Every attribute name the external stream may put on the wire.
///
/// The allowlist is built from this enum, so adding a key is the only way to
/// widen what can be exported — a stray string key is dropped by
/// ``ExternalRecordValidator/recordIsClean(_:gates:)`` rather than exported.
public enum ExternalKey: String, Sendable, Equatable, Hashable, CaseIterable {
    case sessionId = "session.id"
    case turnNumber = "turn_number"
    case promptId = "prompt.id"
    case eventSequence = "event.sequence"
    case userId = "user.id"
    case organizationId = "organization.id"
    case teamId = "team.id"
    case deploymentId = "deployment.id"
    case model
    case permissionMode = "permission_mode"
    case mcpServerCount = "mcp_server_count"
    case pluginCount = "plugin_count"
    case skillCount = "skill_count"
    case hookCount = "hook_count"
    case memoryEnabled = "memory_enabled"
    case isGitRepo = "is_git_repo"
    case clientIdentifier = "client_identifier"
    case durationSecs = "duration_secs"
    case turnCount = "turn_count"
    case toolCallCount = "tool_call_count"
    case compactionCount = "compaction_count"
    case promptLength = "prompt_length"
    case prompt
    case screenMode = "screen_mode"
    case outcome
    case durationMs = "duration_ms"
    case errorCategory = "error_category"
    case cancellationCategory = "cancellation_category"
    case stopReason = "stop_reason"
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case reasoningTokens = "reasoning_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case statusCode = "status_code"
    case toolName = "tool_name"
    case success
    case fileExtension = "file_extension"
    case toolParameters = "tool_parameters"
    case filePath = "file_path"
    case decision
    case accessKind = "access_kind"
    case source
    case status
    case transportType = "transport_type"
    case toolCount = "tool_count"
    case errorType = "error_type"
    case mcpServerName = "mcp_server.name"
    case toMode = "to_mode"
    case trigger
    case skillSource = "skill_source"
    case skillName = "skill.name"
    case installKind = "install_kind"
    case pluginScope = "plugin_scope"
    case pluginName = "plugin_name"
    case pluginVersion = "plugin_version"
    case compactionTrigger = "compaction_trigger"
    case compactionOutcome = "compaction_outcome"
    case tokensBefore = "tokens_before"
    case tokensAfter = "tokens_after"
    case phase
    case subagentType = "subagent_type"
    case authMethod = "auth_method"
    case fromModel = "from_model"
    case toModel = "to_model"
    case errorCode = "error_code"
    case tip
    case action

    public var wireName: String { rawValue }
}

/// The export allowlist: exactly the wire names of ``ExternalKey``.
public let externalAllowedKeys: Set<String> = Set(ExternalKey.allCases.map(\.rawValue))

// MARK: - Content gates

/// A content gate guarding an attribute.
public enum ExternalGate: String, Sendable, Equatable, Hashable {
    /// `OTEL_LOG_USER_PROMPTS`.
    case userPrompts
    /// `OTEL_LOG_TOOL_DETAILS`.
    case toolDetails
}

/// Keys permitted only when their gate is open. `external/schema.rs:329-337`.
///
/// This is the whole privacy contract in five key names: with both gates shut,
/// no prompt text, no tool arguments, no filesystem path, and no verbatim
/// MCP/skill/plugin identifier can appear on an exported record.
public func externalGate(forKey key: String) -> ExternalGate? {
    switch key {
    case ExternalKey.prompt.rawValue:
        return .userPrompts
    case ExternalKey.toolParameters.rawValue,
         ExternalKey.filePath.rawValue,
         ExternalKey.skillName.rawValue,
         ExternalKey.pluginName.rawValue,
         ExternalKey.pluginVersion.rawValue:
        return .toolDetails
    default:
        return nil
    }
}

extension OTELContentGates {
    /// `external/emit.rs:62-67`, `external/redact.rs:44-49`.
    public func isOpen(_ gate: ExternalGate) -> Bool {
        switch gate {
        case .userPrompts: return logUserPrompts
        case .toolDetails: return logToolDetails
        }
    }

    /// Tighten-only merge for the remote kill switch. A remote policy may force
    /// gates off; it may never force them on (`external/mod.rs:371-389`).
    public func tightened(forceOff: Bool) -> OTELContentGates {
        guard forceOff else { return self }
        return OTELContentGates(logUserPrompts: false, logToolDetails: false)
    }
}

// MARK: - Truncation

/// `external/truncate.rs:9-24`.
public enum ExternalTruncation {
    public static let maxStringLength = 512
    public static let truncatedPrefixLength = 128
    public static let truncationMarker = "…[truncated]"
    public static let maxToolInputJSONBytes = 4 * 1024
    public static let maxJSONDepth = 2
    public static let maxCollectionItems = 20
    public static let maxContentBytes = 60 * 1024
    public static let maxFileExtensionLength = 10

    /// Standard value truncation: over 512 chars collapses to 128 + marker.
    public static func truncateValue(_ s: String) -> String {
        guard s.count > maxStringLength else { return s }
        return String(s.prefix(truncatedPrefixLength)) + truncationMarker
    }

    /// Gated prompt/content cap at 60 KB, on a character boundary.
    public static func truncateContent(_ s: String) -> String {
        var bytes = 0
        var end = s.startIndex
        for idx in s.indices {
            let width = String(s[idx]).utf8.count
            if bytes + width > maxContentBytes { break }
            bytes += width
            end = s.index(after: idx)
        }
        guard end < s.endIndex else { return s }
        return String(s[s.startIndex..<end]) + truncationMarker
    }
}

// MARK: - Sanitizers

/// Built-in tool names that may be reported verbatim with the tool-details
/// gate shut. `external/schema.rs:614-622`.
public let externalBuiltinToolNames: Set<String> = [
    "bash", "edit", "read", "write", "glob", "grep", "ls", "task",
    "todo_write", "web_fetch", "web_search", "notebook_edit",
    "multi_edit", "exit_plan_mode",
]

/// Reduce a tool name to a non-identifying category when the tool-details gate
/// is shut. `external/schema.rs:614-622`.
public func sanitizeToolName(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if externalBuiltinToolNames.contains(name.lowercased()) { return name.lowercased() }
    // `__` is the MCP server/tool separator; its presence identifies the
    // family without revealing which server the user connected.
    if name.contains("__") { return "mcp_tool" }
    return "custom_tool"
}

/// The file extension of a path, lowercased and capped — the only part of a
/// path that survives with the tool-details gate shut.
/// `external/schema.rs:628-635`.
public func externalFileExtension(_ path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    guard !ext.isEmpty, ext.count <= ExternalTruncation.maxFileExtensionLength else {
        return nil
    }
    return ext
}

// MARK: - Record model

/// A flat attribute value. No nested or array variants: the external schema is
/// flat, and the validator treats any non-scalar as content.
public enum ExternalAttrValue: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int64)
    case bool(Bool)
}

/// An attribute emitted only when its gate is open.
///
/// When a gated attribute shares a key with a default one — verbatim versus
/// sanitized `tool_name` is the motivating case — the gated value *replaces*
/// the default at emit time (`external/emit.rs:92-107`).
public struct ExternalGatedAttr: Sendable, Equatable {
    public var key: ExternalKey
    public var gate: ExternalGate
    public var value: ExternalAttrValue

    public init(key: ExternalKey, gate: ExternalGate, value: ExternalAttrValue) {
        self.key = key
        self.gate = gate
        self.value = value
    }
}

/// One mapped external event, before gating and validation.
public struct ExternalRecord: Sendable, Equatable {
    /// Wire event name, e.g. `grok_code.user_prompt`.
    public var eventName: String
    /// Ungated attributes, always safe to export.
    public var attrs: [(ExternalKey, ExternalAttrValue)]
    /// Attributes awaiting their gate.
    public var gated: [ExternalGatedAttr]

    public init(
        eventName: String,
        attrs: [(ExternalKey, ExternalAttrValue)] = [],
        gated: [ExternalGatedAttr] = []
    ) {
        self.eventName = eventName
        self.attrs = attrs
        self.gated = gated
    }

    public static func == (lhs: ExternalRecord, rhs: ExternalRecord) -> Bool {
        lhs.eventName == rhs.eventName
            && lhs.gated == rhs.gated
            && lhs.attrs.count == rhs.attrs.count
            && zip(lhs.attrs, rhs.attrs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// Wire event names for the mapped external families.
/// `external/schema.rs:53-70`.
public enum ExternalEventName {
    public static let sessionStart = "grok_code.session_start"
    public static let sessionEnd = "grok_code.session_end"
    public static let userPrompt = "grok_code.user_prompt"
    public static let turnCompleted = "grok_code.turn_completed"
    public static let apiRequest = "grok_code.api_request"
    public static let apiError = "grok_code.api_error"
    public static let toolResult = "grok_code.tool_result"
    public static let toolDecision = "grok_code.tool_decision"
    public static let mcpServerConnection = "grok_code.mcp_server_connection"
    public static let permissionModeChanged = "grok_code.permission_mode_changed"
    public static let skillActivated = "grok_code.skill_activated"
    public static let pluginLoaded = "grok_code.plugin_loaded"
    public static let compaction = "grok_code.compaction"
    public static let subagent = "grok_code.subagent"
    public static let auth = "grok_code.auth"
    public static let internalError = "grok_code.internal_error"
    public static let modelSwitched = "grok_code.model_switched"
    public static let contextualTip = "grok_code.contextual_tip"
}

// MARK: - Emit-time gating

public enum ExternalRecordEmitter {
    /// Apply the content gates and scrub every string value.
    ///
    /// Defense in depth only — the export-time validator enforces the result
    /// (`external/emit.rs:69-79`). A closed gate drops the gated attribute
    /// entirely; it never falls back to a partial or hashed form, because a
    /// partial prompt is still a prompt.
    public static func applyGates(
        _ record: ExternalRecord,
        gates: OTELContentGates
    ) -> ExternalRecord {
        var out = record
        for gated in record.gated {
            guard gates.isOpen(gated.gate) else { continue }
            if let idx = out.attrs.firstIndex(where: { $0.0 == gated.key }) {
                out.attrs[idx].1 = gated.value
            } else {
                out.attrs.append((gated.key, gated.value))
            }
        }
        out.gated = []
        out.attrs = out.attrs.map { key, value in
            guard case .string(let s) = value else { return (key, value) }
            return (key, .string(scrubString(key: key, s)))
        }
        return out
    }

    /// Secret + home-path scrub, then the per-key size cap.
    /// `external/emit.rs:69-79`.
    static func scrubString(key: ExternalKey, _ s: String) -> String {
        let scrubbed = TelemetryRedaction.redactString(s)
        switch key {
        case .prompt:
            return ExternalTruncation.truncateContent(scrubbed)
        default:
            return ExternalTruncation.truncateValue(scrubbed)
        }
    }
}

// MARK: - Export-time fail-closed validation

/// Why a record was refused, for diagnostics and for tests that need to prove
/// *which* guard fired rather than only that something did.
public enum ExternalRecordRejection: Sendable, Equatable, Hashable {
    case nonSchemaKey(String)
    case closedGate(key: String, gate: ExternalGate)
    case unscrubbedString(key: String)
    case unappliedGatedAttribute(key: String)
}

public enum ExternalRecordValidator {
    /// The authoritative chokepoint. `external/redact.rs:55-100`.
    ///
    /// Returns `nil` when the record may be exported, or the first violation
    /// found. Any violation means *drop the whole record*: partial export of a
    /// record that failed schema validation is how a leak gets reclassified as
    /// a formatting bug.
    public static func rejection(
        _ record: ExternalRecord,
        gates: OTELContentGates
    ) -> ExternalRecordRejection? {
        // A record still carrying gated attributes never went through
        // `applyGates`. Fail closed rather than assume the caller meant to
        // drop them: the alternative silently exports whatever `attrs` holds
        // from a code path that clearly did not finish.
        if let stray = record.gated.first {
            return .unappliedGatedAttribute(key: stray.key.rawValue)
        }
        for (key, value) in record.attrs {
            let name = key.rawValue
            guard externalAllowedKeys.contains(name) else {
                return .nonSchemaKey(name)
            }
            if let gate = externalGate(forKey: name), !gates.isOpen(gate) {
                return .closedGate(key: name, gate: gate)
            }
            if case .string(let s) = value,
               TelemetryRedaction.redactedIfChanged(s) != nil {
                return .unscrubbedString(key: name)
            }
        }
        return nil
    }

    public static func isClean(
        _ record: ExternalRecord,
        gates: OTELContentGates
    ) -> Bool {
        rejection(record, gates: gates) == nil
    }

    /// Gate, scrub, then validate. Returns `nil` when the record must not be
    /// exported.
    ///
    /// This is the only supported way to turn an ``ExternalRecord`` into
    /// exportable attributes; exporting `record.attrs` directly bypasses both
    /// chokepoints.
    public static func prepareForExport(
        _ record: ExternalRecord,
        gates: OTELContentGates
    ) -> ExternalRecord? {
        let gated = ExternalRecordEmitter.applyGates(record, gates: gates)
        return isClean(gated, gates: gates) ? gated : nil
    }
}

// MARK: - Exporter seam

extension ExternalRecord {
    /// Flatten to the attribute dictionary the OTLP span encoder takes.
    public func spanAttributes() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in attrs {
            switch value {
            case .string(let s): out[key.rawValue] = .string(s)
            case .int(let i): out[key.rawValue] = .number(.int64(i))
            case .bool(let b): out[key.rawValue] = .bool(b)
            }
        }
        return out
    }
}

extension OTLPExporter {
    /// Export one schema-mapped record through both privacy chokepoints.
    ///
    /// This is the only export entry point emission call sites should use.
    /// ``exportSpan(name:attributes:provider:)`` takes free-form attributes and
    /// so cannot tell a gated key from an ordinary one; a caller that reaches
    /// for it with a prompt in hand gets key-denylist scrubbing but not gate
    /// enforcement.
    ///
    /// Returns `false` without producing bytes when the record is vetoed by
    /// policy, by a closed gate, or by the export-time validator.
    @discardableResult
    public func exportRecord(
        _ record: ExternalRecord,
        provider: String? = nil
    ) async throws -> Bool {
        guard let clean = ExternalRecordValidator.prepareForExport(
            record,
            gates: config.gates
        ) else {
            return false
        }
        return try await exportSpan(
            name: clean.eventName,
            attributes: clean.spanAttributes(),
            provider: provider
        )
    }

    /// Build (but do not send) the wire request for a record — the hermetic
    /// twin of ``exportRecord(_:provider:)`` for byte-level privacy tests.
    public func makeRecordWireRequest(
        _ record: ExternalRecord,
        provider: String? = nil,
        nowNanos: UInt64? = nil
    ) throws -> (request: HTTPRequest, body: Data)? {
        guard let clean = ExternalRecordValidator.prepareForExport(
            record,
            gates: config.gates
        ) else {
            return nil
        }
        return try makeSpanWireRequest(
            name: clean.eventName,
            attributes: clean.spanAttributes(),
            provider: provider,
            nowNanos: nowNanos
        )
    }
}
