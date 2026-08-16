// JavaScriptRuntimeTypes.swift
//
// Wire types shared between the cell actor and the embedded JavaScript
// runtime thread. Ported from
// `crates/codegen/xai-grok-code-mode/src/runtime/mod.rs`
// (`RuntimeCommand`, `RuntimeControlCommand`, `RuntimeEvent`,
// `PendingRuntimeMode`, `RuntimeConfig`).

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

/// Sentinel thrown by the `exit()` global. A rejection carrying this exact
/// string with `exitRequested` set is reported as a clean completion, not an
/// error. Mirrors `EXIT_SENTINEL` in runtime/mod.rs:25.
public let CODE_MODE_EXIT_SENTINEL = "__codex_code_mode_exit__"

/// Everything the runtime thread needs to evaluate one cell.
///
/// Mirrors the Rust `RuntimeConfig` (runtime/mod.rs:138) plus the
/// `max_output_tokens` budget that the Rust runtime accepts on
/// `ExecuteRequest` but never enforces (see `JavaScriptOutputBudget`).
public struct JavaScriptCellConfiguration: Sendable, Codable {
    /// The outer `exec` tool call id. Echoed back on `notify` events.
    public var toolCallId: String
    /// Tools exposed through the generated `tools.*` namespace.
    public var enabledTools: [EnabledToolMetadata]
    /// Raw JavaScript source for the cell.
    public var source: String
    /// Session-scoped values readable through `load()`.
    public var storedValues: [String: JSONValue]
    /// Optional cap on the text this cell may emit. `nil` (the Rust
    /// default) means unbounded.
    public var maxOutputTokens: Int?
    /// Ceiling on one uninterrupted JavaScript entry. Also the worst-case
    /// latency for terminating a cell that is spinning inside JavaScript;
    /// see `JavaScriptExecutionWatchdog`.
    public var executionCeilingMs: UInt64

    public init(
        toolCallId: String,
        enabledTools: [EnabledToolMetadata] = [],
        source: String,
        storedValues: [String: JSONValue] = [:],
        maxOutputTokens: Int? = nil,
        executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
    ) {
        self.toolCallId = toolCallId
        self.enabledTools = enabledTools
        self.source = source
        self.storedValues = storedValues
        self.maxOutputTokens = maxOutputTokens
        self.executionCeilingMs = executionCeilingMs
    }
}

/// What the runtime thread does when it runs out of work.
///
/// Mirrors `PendingRuntimeMode` (runtime/mod.rs:36). `pauseUntilResumed` is
/// the production mode: the thread announces `.pending` and blocks on the
/// control channel so the cell actor can observe a stable frontier.
public enum JavaScriptPendingMode: Sendable, Hashable, Codable {
    /// Announce `.pending` then immediately block for the next command.
    /// Test-only in Rust (`#[cfg(test)] Continue`).
    case continueImmediately
    case pauseUntilResumed
}

/// Work submitted to the runtime thread. Mirrors `RuntimeCommand`
/// (runtime/mod.rs:28).
public enum JavaScriptRuntimeCommand: Sendable, Codable {
    case toolResponse(id: String, result: JSONValue)
    case toolError(id: String, errorText: String)
    case timeoutFired(id: UInt64)
    case observePendingFrontier
    case terminate
}

/// Out-of-band control for a paused runtime thread. Mirrors
/// `RuntimeControlCommand` (runtime/mod.rs:44).
public enum JavaScriptRuntimeControlCommand: Sendable, Codable {
    /// Leave the pending frontier and block for the next command.
    case `continue`
    /// Leave the pending frontier and re-poll immediately.
    case resume
    case terminate
}

/// Everything the runtime thread reports back. Mirrors `RuntimeEvent`
/// (runtime/mod.rs:51).
public enum JavaScriptRuntimeEvent: Sendable, Codable {
    case started
    case pending
    case contentItem(FunctionCallOutputContentItem)
    case yieldRequested
    case toolCall(id: String, name: ToolName, kind: CodeModeToolKind, input: JSONValue?)
    case notify(callId: String, text: String)
    case result(storedValueWrites: [String: JSONValue], errorText: String?)
    /// The runtime thread trapped. Mirrors `RuntimeEvent::ThreadPanicked`.
    case runtimeFailed(String)
}

/// Failures raised while starting or driving the embedded runtime.
public struct JavaScriptRuntimeError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        /// JavaScriptCore is not available for this platform.
        case unsupportedPlatform
        /// The engine could not be created.
        case initializationFailed
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }

    public static let unsupportedPlatform = JavaScriptRuntimeError(
        kind: .unsupportedPlatform,
        message: "code mode requires JavaScriptCore, which is unavailable on this platform"
    )

    public static func initializationFailed(_ message: String) -> JavaScriptRuntimeError {
        JavaScriptRuntimeError(kind: .initializationFailed, message: message)
    }
}

/// Platform capability for the in-process JavaScript runtime.
///
/// The conditional implementation lives here so callers can gate Code Mode
/// before advertising a transport that cannot start. The startup seam still
/// throws `unsupportedPlatform` defensively if a caller bypasses the gate.
public struct JavaScriptRuntimeCapability: Sendable, Equatable {
    public let isAvailable: Bool
    public let unavailableError: JavaScriptRuntimeError?

    public init(
        isAvailable: Bool,
        unavailableError: JavaScriptRuntimeError? = nil
    ) {
        self.isAvailable = isAvailable
        self.unavailableError = isAvailable
            ? nil
            : (unavailableError ?? .unsupportedPlatform)
    }

    public static let available = JavaScriptRuntimeCapability(isAvailable: true)
    public static let unavailable = JavaScriptRuntimeCapability(
        isAvailable: false,
        unavailableError: .unsupportedPlatform
    )

    public static var current: JavaScriptRuntimeCapability {
        #if canImport(JavaScriptCore)
        return .available
        #else
        return .unavailable
        #endif
    }
}
