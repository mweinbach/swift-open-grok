// OpenGrokACP.swift
//
// ACP wire types, method-name constants, channel primitives, and the
// Open Grok extension metadata. This is the Swift port of the Rust
// crate `xai-acp-lib` (crates/codegen/xai-acp-lib).
//
// Scope: this target owns the wire contracts and channel primitives
// that let later provider, session, and pager slices compile
// independently against protocols rather than concrete implementations.
// Transport implementations (stdio, leader IPC, WebSocket serve, relay)
// arrive in Wave 7 (`OpenGrokACPRuntime`, W7-S5). Typed request and
// response schemas for core ACP methods, reverse requests, and the
// Open Grok `x.ai/ask_user_question` extension live alongside the
// channel primitives in this module.
//
// Acceptance:
//   * ACP JSON-RPC IDs, methods, notifications, reverse requests,
//     errors, and Open Grok extension metadata match captured Rust
//     fixtures (`ProtocolFixtures/acp-methods.json`).
//   * Core methods use typed request/response payloads with typed
//     dispatch rather than JSONValue-only envelopes.
//   * Channel cancellation closes pending continuations exactly once
//     and never resumes a Swift continuation twice.
//
// Rust crate mapping: xai-acp-lib (crates/codegen/xai-acp-lib).
// See CRATE_MAP.md and PORT_PLAN.md (W1-S2).

import Foundation
import OpenGrokShared

// MARK: - Open Grok extension metadata

/// Open Grok–specific extension metadata advertised in `initialize`
/// responses and `_meta` payloads. Mirrors the
/// `ProtocolFixtures/acp-methods.json` `extensions.openGrok` block, which
/// is the captured Rust fixture for the wire contract.
///
/// Wire form: `{"product": "Open Grok", "executable": "open-grok",
/// "stateDirectory": ".opengrok", "homeEnvironmentVariable":
/// "OPENGROK_HOME"}`. Keys are stable; never rename without a fixture
/// refresh.
public enum OpenGrokACPExtension {
    /// The extension namespace used on the wire (`extensions.openGrok`).
    public static let namespace = "openGrok"

    /// Product name advertised to ACP peers.
    public static let product = "Open Grok"

    /// Public executable product name.
    public static let executable = "open-grok"

    /// Default state directory under the user's home (`~/.opengrok`).
    public static let stateDirectory = ".opengrok"

    /// Environment variable that overrides the default state home.
    public static let homeEnvironmentVariable = "OPENGROK_HOME"

    /// The JSON dictionary form expected on the wire. Encoded with
    /// sorted keys for deterministic comparison against the fixture.
    public static let wireDictionary: [String: String] = [
        "product": product,
        "executable": executable,
        "stateDirectory": stateDirectory,
        "homeEnvironmentVariable": homeEnvironmentVariable,
    ]
}

// MARK: - Method name constants

/// Method names for requests/notifications flowing client → agent
/// (`AGENT_METHOD_NAMES` in the Rust schema crate).
///
/// The snake_case forms (`session/set_mode`, `session/set_model`) are
/// the canonical wire names from `agent-client_protocol_schema` 0.11.4.
/// The camelCase forms (`session/setMode`, `session/setModel`) are
/// accepted by Open Grok's leader bridge (see
/// `xai-grok-shell/src/leader/server.rs`) for compatibility with
/// clients that send the older camelCase spelling; both forms classify
/// the same method. The `ProtocolFixtures/acp-methods.json` fixture
/// captures the camelCase spellings as the documented surface.
public enum AgentMethodNames {
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionResume = "session/resume"
    public static let sessionFork = "session/fork"
    public static let sessionList = "session/list"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    /// Canonical snake_case wire name.
    public static let sessionSetModel = "session/set_model"
    /// CamelCase alias accepted by the Open Grok leader bridge.
    public static let sessionSetModelCamel = "session/setModel"
    /// Canonical snake_case wire name.
    public static let sessionSetMode = "session/set_mode"
    /// CamelCase alias accepted by the Open Grok leader bridge.
    public static let sessionSetModeCamel = "session/setMode"
    public static let sessionSetConfigOption = "session/set_config_option"
    public static let sessionClose = "session/close"
    public static let logout = "logout"
}

/// Method names for requests/notifications flowing agent → client
/// (`CLIENT_METHOD_NAMES` in the Rust schema crate).
public enum ClientMethodNames {
    public static let sessionUpdate = "session/update"
    public static let sessionRequestPermission = "session/request_permission"
    public static let fsWriteTextFile = "fs/write_text_file"
    public static let fsReadTextFile = "fs/read_text_file"
    public static let terminalCreate = "terminal/create"
    public static let terminalOutput = "terminal/output"
    public static let terminalRelease = "terminal/release"
    public static let terminalWaitForExit = "terminal/wait_for_exit"
    public static let terminalKill = "terminal/kill"
    public static let sessionElicitation = "session/elicitation"
    public static let sessionElicitationComplete = "session/elicitation/complete"
}

/// The full set of ACP method names recognized by Open Grok, mirroring
/// the `methods` array in `ProtocolFixtures/acp-methods.json`. The
/// fixture is the captured Rust wire contract; this list MUST stay in
/// sync with the fixture (CI verifies via the proto-build plugin's
/// fixture validator).
public enum OpenGrokACPMethodCatalog {
    /// The complete list of recognized ACP method names. Order matches
    /// the fixture for deterministic comparison.
    public static let allMethods: [String] = [
        AgentMethodNames.initialize,
        AgentMethodNames.authenticate,
        AgentMethodNames.sessionNew,
        AgentMethodNames.sessionLoad,
        AgentMethodNames.sessionResume,
        AgentMethodNames.sessionFork,
        AgentMethodNames.sessionList,
        AgentMethodNames.sessionPrompt,
        AgentMethodNames.sessionCancel,
        AgentMethodNames.sessionSetModelCamel,
        AgentMethodNames.sessionSetModeCamel,
    ]

    /// `true` when `method` is a recognized ACP method name (either
    /// snake_case canonical or camelCase alias).
    public static func contains(_ method: String) -> Bool {
        allMethods.contains(method)
            || method == AgentMethodNames.sessionSetModel
            || method == AgentMethodNames.sessionSetMode
            || method == AgentMethodNames.sessionSetConfigOption
            || method == AgentMethodNames.sessionClose
            || method == AgentMethodNames.logout
            // Client-side (reverse) requests and notifications.
            || method == ClientMethodNames.sessionUpdate
            || method == ClientMethodNames.sessionRequestPermission
            || method == ClientMethodNames.fsWriteTextFile
            || method == ClientMethodNames.fsReadTextFile
            || method == ClientMethodNames.terminalCreate
            || method == ClientMethodNames.terminalOutput
            || method == ClientMethodNames.terminalRelease
            || method == ClientMethodNames.terminalWaitForExit
            || method == ClientMethodNames.terminalKill
            || method == ClientMethodNames.sessionElicitation
            || method == ClientMethodNames.sessionElicitationComplete
            || method == OpenGrokACPExtMethods.askUserQuestion
    }
}

// MARK: - ACP error model

/// JSON-RPC 2.0 error codes following the ACP spec, plus ACP-specific
/// extensions in the reserved -32000 to -32099 range.
///
/// Swift port of `agent_client_protocol_schema::error::ErrorCode`. The
/// wire form is the raw `i32`; Swift enums retain the case distinction
/// for typed matching while serializing as the integer.
public enum AcpErrorCode: Hashable, Sendable, Codable {
    // Standard JSON-RPC 2.0 errors.
    case parseError          // -32700
    case invalidRequest      // -32600
    case methodNotFound      // -32601
    case invalidParams       // -32602
    case internalError       // -32603
    case requestCancelled    // -32800 (unstable_cancel_request)
    // ACP-specific errors in the reserved -32000 to -32099 range.
    case authRequired        // -32000
    case resourceNotFound    // -32002
    case urlElicitationRequired  // -32042 (unstable_elicitation)
    /// Other undefined error code.
    case other(Int32)

    /// The integer wire form.
    public var code: Int32 {
        switch self {
        case .parseError: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case .requestCancelled: return -32800
        case .authRequired: return -32000
        case .resourceNotFound: return -32002
        case .urlElicitationRequired: return -32042
        case .other(let v): return v
        }
    }

    /// Human-readable string matching the Rust `strum::Display` impl.
    public var displayName: String {
        switch self {
        case .parseError: return "Parse error"
        case .invalidRequest: return "Invalid request"
        case .methodNotFound: return "Method not found"
        case .invalidParams: return "Invalid params"
        case .internalError: return "Internal error"
        case .requestCancelled: return "Request cancelled"
        case .authRequired: return "Authentication required"
        case .resourceNotFound: return "Resource not found"
        case .urlElicitationRequired: return "URL elicitation required"
        case .other: return "Unknown error"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int32.self)
        self = AcpErrorCode.fromCode(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    /// Recover the enum case from an integer code.
    public static func fromCode(_ value: Int32) -> AcpErrorCode {
        switch value {
        case -32700: return .parseError
        case -32600: return .invalidRequest
        case -32601: return .methodNotFound
        case -32602: return .invalidParams
        case -32603: return .internalError
        case -32800: return .requestCancelled
        case -32000: return .authRequired
        case -32002: return .resourceNotFound
        case -32042: return .urlElicitationRequired
        default: return .other(value)
        }
    }
}

/// JSON-RPC error object.
///
/// Swift port of `agent_client_protocol_schema::error::Error`. Wire
/// form: `{"code": <i32>, "message": <string>, "data"?: <json>}`. The
/// `data` field is omitted when `nil` (Rust
/// `skip_serializing_if = "Option::is_none"`).
public struct AcpError: Error, Hashable, Sendable, Codable {
    public var code: AcpErrorCode
    public var message: String
    /// Optional primitive or structured value with additional
    /// information about the error. Stored as `JSONValue` for lossless
    /// round-tripping.
    public var data: JSONValue?

    public init(code: AcpErrorCode, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Convenience: build an error from a raw integer code.
    public init(code: Int32, message: String, data: JSONValue? = nil) {
        self.init(code: AcpErrorCode.fromCode(code), message: message, data: data)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(AcpErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        // Mirror Rust `skip_serializing_if = "Option::is_none"`.
        try container.encodeIfPresent(data, forKey: .data)
    }

    // MARK: Convenience constructors mirroring the Rust `Error::*` helpers.

    public static func parseError() -> AcpError {
        AcpError(code: .parseError, message: AcpErrorCode.parseError.displayName)
    }
    public static func invalidRequest() -> AcpError {
        AcpError(code: .invalidRequest, message: AcpErrorCode.invalidRequest.displayName)
    }
    public static func methodNotFound() -> AcpError {
        AcpError(code: .methodNotFound, message: AcpErrorCode.methodNotFound.displayName)
    }
    public static func invalidParams() -> AcpError {
        AcpError(code: .invalidParams, message: AcpErrorCode.invalidParams.displayName)
    }
    public static func internalError() -> AcpError {
        AcpError(code: .internalError, message: AcpErrorCode.internalError.displayName)
    }
    public static func requestCancelled() -> AcpError {
        AcpError(code: .requestCancelled, message: AcpErrorCode.requestCancelled.displayName)
    }
    public static func authRequired() -> AcpError {
        AcpError(code: .authRequired, message: AcpErrorCode.authRequired.displayName)
    }
    public static func resourceNotFound(uri: String? = nil) -> AcpError {
        if let uri = uri {
            return AcpError(
                code: .resourceNotFound,
                message: AcpErrorCode.resourceNotFound.displayName,
                data: .object(["uri": .string(uri)])
            )
        }
        return AcpError(code: .resourceNotFound, message: AcpErrorCode.resourceNotFound.displayName)
    }
    public static func urlElicitationRequired() -> AcpError {
        AcpError(code: .urlElicitationRequired, message: AcpErrorCode.urlElicitationRequired.displayName)
    }

    /// Build an `INTERNAL_ERROR` with a custom message. Mirrors Rust
    /// `acp_internal_error`.
    public static func internalError(_ message: String) -> AcpError {
        AcpError(code: .internalError, message: message)
    }

    /// Chainable `data` setter. Mirrors Rust `Error::data`.
    @discardableResult
    public func withData(_ value: JSONValue) -> AcpError {
        var copy = self
        copy.data = value
        return copy
    }
}

extension AcpError: LocalizedError {
    public var errorDescription: String? {
        if message.isEmpty {
            return "\(code.code)"
        }
        if let data = data {
            // Match Rust Display: `message: <pretty data>`.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(data),
               let str = String(data: data, encoding: .utf8) {
                return "\(message): \(str)"
            }
            return "\(message): \(data)"
        }
        return message
    }
}

// MARK: - Result typealiases

/// `Result<T, AcpError>` — the standard ACP result type. Mirrors
/// `agent_client_protocol::Result<T>` (which is `Result<T, Error>`).
public typealias AcpResult<T> = Result<T, AcpError>

// MARK: - Meta

/// ACP `_meta` payload — an arbitrary JSON object. Mirrors
/// `agent_client_protocol_schema::ext::Meta =
/// serde_json::Map<String, serde_json::Value>`.
public typealias AcpMeta = [String: JSONValue]

// MARK: - Sides

/// Marker protocol representing one side of the ACP connection.
///
/// Swift port of `xai_acp_lib::message::AcpSide`. The Rust trait has
/// associated types for `InMessage`, `OutMessage`, and `OtherSide`;
/// the Swift port uses PATs for the same. The `name` is the display
/// name ("agent" or "client") used in tracing.
public protocol AcpSide: Sendable {
    associatedtype InMessage: AcpMethod
    associatedtype OutMessage: AcpMethod
    associatedtype OtherSide: AcpSide where OtherSide.OtherSide == Self

    /// Display name for this side.
    static var name: String { get }
}

/// The agent's view of the ACP connection. Inbound messages are
/// `AcpAgentMessage` (messages meant FOR the agent); outbound messages
/// are `AcpClientMessage` (messages meant FOR the client).
public enum AgentSide: AcpSide {
    public typealias InMessage = AcpAgentMessage
    public typealias OutMessage = AcpClientMessage
    public typealias OtherSide = ClientSide

    public static let name = "agent"
}

/// The client's view of the ACP connection. Inbound messages are
/// `AcpClientMessage` (messages meant FOR the client); outbound
/// messages are `AcpAgentMessage` (messages meant FOR the agent).
public enum ClientSide: AcpSide {
    public typealias InMessage = AcpClientMessage
    public typealias OutMessage = AcpAgentMessage
    public typealias OtherSide = AgentSide

    public static let name = "client"
}

// MARK: - Method/request protocols

/// Extends each request/response type pair with the side marker type
/// and schema method name.
///
/// Swift port of `xai_acp_lib::message::AcpMethod`. Concrete adopters
/// report the JSON-RPC method name they correspond to.
public protocol AcpMethod: Sendable {
    /// The JSON-RPC method name on the wire.
    var methodName: String { get }
}

/// Connects an ACP request type to its response type.
///
/// Swift port of `xai_acp_lib::message::AcpRequest`. The Rust trait
/// requires `Clone + Debug + Serialize + AcpMethod`; the Swift port
/// adds `Codable` so requests can be encoded for the wire.
public protocol AcpRequest: AcpMethod, Codable {
    associatedtype Response: Codable & Sendable
}

// MARK: - Type-erased request/response envelopes
//
// Retained for extension methods and transport layers that need a
// method-name + raw-params path. Core methods use the typed schemas in
// AcpAgentSchema / AcpClientSchema and the typed AcpAgentMessage /
// AcpClientMessage enums.

/// A type-erased ACP request envelope: a method name plus the JSON
/// params payload. Prefer typed `AcpRequest` adopters for core methods.
public struct AcpRequestEnvelope: Hashable, Sendable, Codable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }

    public var methodName: String { method }
}

extension AcpRequestEnvelope: AcpRequest {
    public typealias Response = AcpResponseEnvelope
}

/// A type-erased ACP response envelope: the JSON result payload (or
/// `nil` for notifications).
public struct AcpResponseEnvelope: Hashable, Sendable, Codable {
    public var result: JSONValue?

    public init(result: JSONValue? = nil) {
        self.result = result
    }
}

// MARK: - AcpArgs (request + oneshot response channel)

/// The pair of an ACP request and the channel that carries its
/// response. Mirrors `xai_acp_lib::message::AcpArgsGeneric<T, S>`.
///
/// In Rust this holds a `oneshot::Sender<AcpResult<T::Response>>`; in
/// Swift the equivalent is a `CheckedContinuation` adapter that
/// resumes exactly once. The `ResponseChannel` type below wraps a
/// single-shot continuation safely — see the channel's documentation
/// for the "exactly once" guarantee required by the acceptance
/// criterion.
public final class AcpArgs<T: AcpRequest>: @unchecked Sendable {
    public let request: T
    /// The single-shot response channel. Holds the continuation until
    /// `resume(_:)` is called exactly once.
    private let responseChannel: ResponseChannel<T.Response>

    public init(request: T, responseChannel: ResponseChannel<T.Response>) {
        self.request = request
        self.responseChannel = responseChannel
    }

    /// Convenience: create an args pair with a fresh response channel.
    public convenience init(request: T) {
        self.init(request: request, responseChannel: ResponseChannel<T.Response>())
    }

    public var methodName: String { request.methodName }

    /// Deliver the response to the waiting sender. Returns `true` if
    /// this was the first delivery (channel was open), `false` if the
    /// channel was already closed (duplicate or cancelled).
    @discardableResult
    public func respond(_ result: AcpResult<T.Response>) -> Bool {
        responseChannel.resume(with: result)
    }

    /// The single-shot response channel, exposed so callers can await
    /// the response independently (mirrors `AcpArgs.response_tx` +
    /// `response_rx.await` in Rust).
    public var response: ResponseChannel<T.Response> {
        responseChannel
    }
}

// MARK: - Single-shot response channel (cancellation-safe)

/// A single-shot channel that delivers exactly one `AcpResult<T>` to a
/// waiting continuation. This is the Swift equivalent of a Tokio
/// `oneshot::Sender<AcpResult<T>>` + `oneshot::Receiver` pair.
///
/// Acceptance criterion: "Channel cancellation closes pending
/// continuations exactly once and never resumes a Swift continuation
/// twice." This type enforces that invariant:
///   * `resume(with:)` and `cancel()` both flip an atomic
///     `AtomicBool` from `false` to `true`; the FIRST caller wins and
///     resumes the continuation (with the result or a cancellation
///     error respectively); subsequent callers are no-ops.
///   * `awaitResponse()` registers a `CheckedContinuation` that Swift's
///     runtime guarantees is resumed at most once. The channel's
///     atomic guard adds a SECOND layer: even if two callers race to
///     resume, only one wins the atomic CAS and the continuation is
///     only resumed from the winning path.
///   * `deinit` cancels any pending continuation so the awaiter never
///     hangs when the sender is dropped without responding (Rust
///     `oneshot` parity: dropping the sender surfaces as a `RecvFailed`
///     `AcpChannelFailure` on the receiver side).
public final class ResponseChannel<T: Sendable>: @unchecked Sendable {
    /// Guard ensuring the continuation is resumed at most once.
    private let state = NSLock()
    private var _closed = false
    /// Stored continuation, set by `awaitResponse()` and consumed by
    /// `resume(with:)` / `cancel()`. Guarded by `state`.
    private var continuation: CheckedContinuation<AcpResult<T>, Never>?
    /// Result delivered before the waiter registered. Tokio oneshot
    /// buffers this so a race between send and await still delivers.
    private var pendingResult: AcpResult<T>?
    /// Optional side-channel observer fired exactly once on first
    /// delivery. Used by transport bridges so a type-erased
    /// `ResponseChannel<JSONValue>` can observe typed completion
    /// without stealing the primary waiter slot.
    private var firstDeliveryObserver: ((AcpResult<T>) -> Void)?

    public init() {}

    deinit {
        // If a continuation is still pending when the channel is
        // deinitialized, cancel it so the awaiter doesn't hang. This
        // mirrors the Rust `oneshot::Sender` drop semantics: the
        // receiver gets a `RecvFailed` error.
        cancel()
    }

    /// Register a side-channel observer that fires exactly once when
    /// the first result is delivered (success, error, or cancel).
    ///
    /// If a result is already buffered, the observer is invoked
    /// immediately. Subsequent deliveries never re-fire. Observers do
    /// not consume the primary `awaitResponse()` waiter.
    public func onFirstDelivery(_ observer: @escaping @Sendable (AcpResult<T>) -> Void) {
        state.lock()
        if let pending = pendingResult {
            state.unlock()
            observer(pending)
            return
        }
        if _closed {
            // Closed without a buffered success (e.g. cancel already
            // drained). Surface the same RecvFailed the waiter would see.
            state.unlock()
            observer(.failure(acpChannelFailureError(
                "unable to receive response, channel closed",
                .recvFailed
            )))
            return
        }
        firstDeliveryObserver = observer
        state.unlock()
    }

    /// Await the response. Suspends until `resume(with:)` or
    /// `cancel()` is called, or the channel is deinitialized.
    public func awaitResponse() async -> AcpResult<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<AcpResult<T>, Never>) in
            state.lock()
            defer { state.unlock() }
            if let pending = pendingResult {
                // Result already delivered before the waiter registered.
                continuation.resume(returning: pending)
                return
            }
            if _closed {
                // Closed without a buffered result (e.g. double-await
                // after a delivered cancel). Surface RecvFailed so the
                // awaiter never hangs.
                continuation.resume(returning: .failure(acpChannelFailureError(
                    "unable to receive response, channel closed",
                    .recvFailed
                )))
                return
            }
            self.continuation = continuation
        }
    }

    /// Deliver the result. Returns `true` if this was the first
    /// delivery (channel was open), `false` if the channel was already
    /// closed (duplicate or cancelled).
    @discardableResult
    public func resume(with result: AcpResult<T>) -> Bool {
        state.lock()
        if _closed {
            state.unlock()
            return false
        }
        _closed = true
        let observer = firstDeliveryObserver
        firstDeliveryObserver = nil
        if let cont = continuation {
            continuation = nil
            state.unlock()
            observer?(result)
            cont.resume(returning: result)
        } else {
            // Buffer until the waiter registers (oneshot race parity).
            pendingResult = result
            state.unlock()
            observer?(result)
        }
        return true
    }

    /// Cancel the pending continuation with a `RecvFailed` channel
    /// failure error. Returns `true` if this was the first close.
    @discardableResult
    public func cancel() -> Bool {
        resume(with: .failure(acpChannelFailureError(
            "unable to receive response, channel cancelled",
            .recvFailed
        )))
    }
}

/// Bridge a typed oneshot response into a type-erased JSON-RPC
/// `ResponseChannel<JSONValue>` exactly once.
///
/// Transport layers pass the erased channel into
/// `decodeAcpAgentMessage` / `decodeAcpClientMessage`; handlers complete
/// the typed `AcpArgs` channel. This wire bridges success (encoded) and
/// `AcpError` failure/cancel races into the transport channel.
public func bridgeTypedResponseChannel<T: Sendable & Encodable>(
    from typed: ResponseChannel<T>,
    into erased: ResponseChannel<JSONValue>
) {
    typed.onFirstDelivery { result in
        switch result {
        case .success(let value):
            do {
                let encoded = try JSONValue.encode(value)
                _ = erased.resume(with: .success(encoded))
            } catch {
                _ = erased.resume(with: .failure(
                    AcpError.internalError("failed to encode ACP response: \(error)")
                ))
            }
        case .failure(let error):
            _ = erased.resume(with: .failure(error))
        }
    }
}

// MARK: - AcpChannelFailure

/// The two distinct ways an `acpSend` round-trip can fail when the
/// underlying channel is closed. Both surface as a JSON-RPC
/// `INTERNAL_ERROR` (so existing callers and the wire format are
/// unaffected); this typed discriminant — carried in the error's
/// `data` — lets callers tell them apart WITHOUT substring-matching
/// the human-readable `message`.
///
/// Swift port of `xai_acp_lib::common::AcpChannelFailure`.
public enum AcpChannelFailure: Hashable, Sendable {
    /// The request could not be ENQUEUED: the receiver half (the
    /// peer's connection task) is already gone, so no peer is
    /// listening — e.g. a headless run with no client wired.
    case sendFailed
    /// The request was enqueued but the RESPONSE channel was dropped
    /// before a reply arrived: a peer received the request, then went
    /// away (disconnect / process exit) without answering.
    case recvFailed

    /// `data` object key under which `acpSend` records the kind.
    /// Namespaced so it can never collide with other `data` payloads.
    public static let dataKey = "xaiAcpChannelFailure"

    /// The wire tag string stored under `dataKey`.
    public var tag: String {
        switch self {
        case .sendFailed: return "send_failed"
        case .recvFailed: return "recv_failed"
        }
    }

    /// Recover the case from a wire tag.
    public static func from(tag: String) -> AcpChannelFailure? {
        switch tag {
        case "send_failed": return .sendFailed
        case "recv_failed": return .recvFailed
        default: return nil
        }
    }
}

/// Recover the `AcpChannelFailure` kind from an error, or `nil` if the
/// error did not originate from `acpSend`'s channel-closed paths (or
/// predates the tag). Consumers use this instead of inspecting
/// `message`. Mirrors `xai_acp_lib::common::acp_channel_failure`.
public func acpChannelFailure(_ error: AcpError) -> AcpChannelFailure? {
    guard case .object(let dict) = error.data,
          case .string(let tag) = dict[AcpChannelFailure.dataKey] else {
        return nil
    }
    return AcpChannelFailure.from(tag: tag)
}

/// Build the channel-closed error for `acpSend`, tagging it with a
/// typed `AcpChannelFailure` discriminant in `data`. The error `code`
/// stays `INTERNAL_ERROR`, so this is purely additive for callers that
/// just propagate the error. Mirrors `acp_channel_failure_error`.
public func acpChannelFailureError(
    _ message: String,
    _ kind: AcpChannelFailure
) -> AcpError {
    AcpError.internalError(message).withData(
        .object([AcpChannelFailure.dataKey: .string(kind.tag)])
    )
}

// MARK: - Type-erased response reference
//
// Typed messages live in AcpMessages.swift as sum types over AcpArgs.
// Transport layers that need a type-erased response delivery path use
// AcpResponseReference.

/// A type-erased reference to a `ResponseChannel` carrying an
/// `AcpResponseEnvelope`. Gateway/transport layers can deliver
/// responses without knowing the concrete request type.
public final class AcpResponseReference: @unchecked Sendable {
    private let respond: (AcpResult<AcpResponseEnvelope>) -> Bool

    public init(_ respond: @escaping (AcpResult<AcpResponseEnvelope>) -> Bool) {
        self.respond = respond
    }

    /// Convenience: wrap a `ResponseChannel<AcpResponseEnvelope>`.
    public init(_ channel: ResponseChannel<AcpResponseEnvelope>) {
        self.respond = { [weak channel] result in
            channel?.resume(with: result) ?? false
        }
    }

    @discardableResult
    public func respond(_ result: AcpResult<AcpResponseEnvelope>) -> Bool {
        respond(result)
    }
}

// MARK: - Channels

/// A linked pair of unbounded queues forming a bidirectional ACP
/// channel. The client side receives client messages and sends agent
/// messages; the agent side receives agent messages and sends client
/// messages. Mirrors `xai_acp_lib::channel::AcpChannel`.
///
/// In Rust this uses `tokio::sync::mpsc::UnboundedSender/
/// UnboundedReceiver`. The Swift port uses `AsyncStream`-backed
/// unbounded queues with `Sendable` box cells. Cancellation closes
/// pending continuations exactly once via the `ResponseChannel`
/// guarantee.
public final class AcpChannel<I: Sendable, O: Sendable>: @unchecked Sendable {
    /// The receive side: an `AsyncStream` of inbound messages.
    private let inbound: AsyncStream<I>
    /// The send side: an enqueue closure that pushes onto the peer's
    /// inbound stream. Returns `false` when the peer is gone.
    private let enqueue: (O) -> Bool
    /// Cancellation of the inbound stream.
    private let inboundContinuation: AsyncStream<I>.Continuation

    public init(inbound: AsyncStream<I>, inboundContinuation: AsyncStream<I>.Continuation, enqueue: @escaping (O) -> Bool) {
        self.inbound = inbound
        self.inboundContinuation = inboundContinuation
        self.enqueue = enqueue
    }

    /// Async sequence of inbound messages. Iteration ends when the
    /// peer closes their send side (or the channel is cancelled).
    public var messages: AsyncStream<I> { inbound }

    /// Enqueue an outbound message. Returns `true` if the peer is
    /// still listening, `false` if the peer's receive side is gone.
    @discardableResult
    public func send(_ message: O) -> Bool {
        enqueue(message)
    }

    /// Close the receive side. Subsequent attempts to enqueue from the
    /// peer's `send` will return `false`.
    public func close() {
        inboundContinuation.finish()
    }
}

/// Client channel: receive client messages from agent, send agent
/// messages to agent.
public typealias AcpClientChannel = AcpChannel<AcpClientMessage, AcpAgentMessage>
/// Agent channel: receive agent messages from client, send client
/// messages to client.
public typealias AcpAgentChannel = AcpChannel<AcpAgentMessage, AcpClientMessage>

/// Create a linked pair of client/agent channels. Mirrors
/// `xai_acp_lib::channel::acp_channels`.
///
/// Closing either side marks the peer's enqueue path as failed so
/// subsequent `send` calls return `false` (sendFailed).
public func acpChannels() -> (AcpClientChannel, AcpAgentChannel) {
    // Client channel: receives AcpClientMessage, sends AcpAgentMessage.
    // Agent channel: receives AcpAgentMessage, sends AcpClientMessage.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        func close() {
            lock.lock()
            open = false
            lock.unlock()
        }
        func isOpen() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }
    }

    let clientOpen = Gate()
    let agentOpen = Gate()

    var clientContinuation: AsyncStream<AcpClientMessage>.Continuation!
    var agentContinuation: AsyncStream<AcpAgentMessage>.Continuation!

    let clientInbound = AsyncStream<AcpClientMessage> { cont in
        clientContinuation = cont
        cont.onTermination = { _ in clientOpen.close() }
    }
    let agentInbound = AsyncStream<AcpAgentMessage> { cont in
        agentContinuation = cont
        cont.onTermination = { _ in agentOpen.close() }
    }

    let clientChannel = AcpChannel<AcpClientMessage, AcpAgentMessage>(
        inbound: clientInbound,
        inboundContinuation: clientContinuation,
        enqueue: { agentMessage in
            guard agentOpen.isOpen() else { return false }
            if case .terminated = agentContinuation.yield(agentMessage) {
                agentOpen.close()
                return false
            }
            return true
        }
    )
    let agentChannel = AcpChannel<AcpAgentMessage, AcpClientMessage>(
        inbound: agentInbound,
        inboundContinuation: agentContinuation,
        enqueue: { clientMessage in
            guard clientOpen.isOpen() else { return false }
            if case .terminated = clientContinuation.yield(clientMessage) {
                clientOpen.close()
                return false
            }
            return true
        }
    )
    return (clientChannel, agentChannel)
}

/// Send a typed agent request through the client channel and await the
/// response. Mirrors `xai_acp_lib::channel::acp_send`.
///
/// Failures are classified into `AcpChannelFailure.sendFailed`
/// (enqueue failed — peer gone) or `AcpChannelFailure.recvFailed`
/// (response channel dropped before reply). Both surface as
/// `INTERNAL_ERROR` with the kind tagged in `data`.
public func acpSend(
    _ message: AcpAgentMessage,
    on channel: AcpClientChannel
) async -> AcpResult<JSONValue> {
    // For the typed enum path, callers typically hold the AcpArgs and
    // await its response channel directly. This helper supports the
    // type-erased envelope path used by tests and gateways.
    switch message {
    case .extMethod(let args):
        let accepted = channel.send(message)
        if !accepted {
            return .failure(acpChannelFailureError(
                "unable to send '\(args.methodName)' request, channel closed",
                .sendFailed
            ))
        }
        switch await args.response.awaitResponse() {
        case .success(let response):
            return .success(response.value)
        case .failure(let error):
            return .failure(error)
        }
    default:
        let accepted = channel.send(message)
        if !accepted {
            return .failure(acpChannelFailureError(
                "unable to send '\(message.methodName)' request, channel closed",
                .sendFailed
            ))
        }
        // Typed cases should await their own AcpArgs.response. Returning
        // success with null here indicates the message was enqueued; the
        // concrete response is delivered on the typed channel.
        return .success(.null)
    }
}

/// Send a typed request by wrapping it into an agent message.
public func acpSendInitialize(
    _ request: InitializeRequest,
    on channel: AcpClientChannel
) async -> AcpResult<InitializeResponse> {
    let args = AcpArgs(request: request)
    let accepted = channel.send(.initialize(args))
    if !accepted {
        return .failure(acpChannelFailureError(
            "unable to send '\(request.methodName)' request, channel closed",
            .sendFailed
        ))
    }
    return await args.response.awaitResponse()
}

/// Send a typed prompt request and await the response.
public func acpSendPrompt(
    _ request: PromptRequest,
    on channel: AcpClientChannel
) async -> AcpResult<PromptResponse> {
    let args = AcpArgs(request: request)
    let accepted = channel.send(.prompt(args))
    if !accepted {
        return .failure(acpChannelFailureError(
            "unable to send '\(request.methodName)' request, channel closed",
            .sendFailed
        ))
    }
    return await args.response.awaitResponse()
}
