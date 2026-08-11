// LiveACPPermissionPrompter.swift
//
// Routes a permission ask during an ACP session to the client via the
// `session/request_permission` reverse request, instead of failing closed with
// "no approval prompt".
//
// Rust reference at pin `650c1db7`:
//   * `AcpPrompter::request` — `permission/prompter.rs:775-797`
//     (cancelled / selected / unknown outcome / RPC error)
//   * Wired in `permission/manager.rs:1373`
//   * Option ids/kinds for generic ACP clients — `prompter.rs:370-488`
//   * `map_selected_outcome` — `prompter.rs:873-1050`
//
// Fail-closed: no reverse client, no session id, transport error, decode
// failure, unrecognized option id, unknown outcome, or timeout → deny /
// cancelled. Never allow on those paths.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokConfig
import OpenGrokShared
import OpenGrokWorkspace

// MARK: - Reverse client seam

/// Narrow seam over `ACPAgentRuntime.requestClient` so tests can drive the
/// reverse permission round-trip without a socket.
public protocol ACPPermissionReverseClient: Sendable {
    func requestClient(method: String, params: JSONValue) async throws -> JSONValue
}

/// Adapts the live ACP runtime actor to `ACPPermissionReverseClient`.
public struct ACPRuntimePermissionClient: ACPPermissionReverseClient {
    private let runtime: ACPAgentRuntime

    public init(_ runtime: ACPAgentRuntime) {
        self.runtime = runtime
    }

    public func requestClient(method: String, params: JSONValue) async throws -> JSONValue {
        try await runtime.requestClient(method: method, params: params)
    }
}

// MARK: - Prompter

/// ACP `PermissionPrompter`: builds `RequestPermissionRequest`, issues
/// `session/request_permission`, maps the client's outcome to a decision.
public actor LiveACPPermissionPrompter: PermissionPrompter {
    /// Human approval can take minutes; the broker itself never times out
    /// (`ACPReverseRequestBroker.request`, ACPRuntimeSupport.swift:267+).
    /// Cost of this bound: a hung/absent client blocks the tool call for up to
    /// ten minutes before we deny — shorter would false-deny slow humans;
    /// longer leaves a wedged turn harder to recover from. Tests inject a
    /// short timeout. `TimeInterval` (not `Duration`) keeps macOS 12 package
    /// deployment target compiling.
    public static let defaultTimeoutSeconds: TimeInterval = 600

    /// The session whose turn is running on this task tree.
    ///
    /// Structured concurrency carries this into the tool call, so a prompt
    /// raised mid-turn knows its own session even while another session's turn
    /// runs concurrently. `bindSession` cannot: it is one actor slot, and the
    /// later bind wins for both turns (`prompter.rs` threads the session
    /// through the request instead).
    @TaskLocal static var activeSession: AcpSessionId?

    private var client: (any ACPPermissionReverseClient)?
    private var sessionId: AcpSessionId?
    private let timeoutSeconds: TimeInterval
    /// Per-session grants. A grant made by one ACP session must not authorize
    /// another session's tool call, and `x.ai/permissions/reset` for one
    /// session must not clear another's.
    private var grants: [AcpSessionId: SessionGrants] = [:]
    /// Sessions with a `session/prompt` turn in flight, refcounted because a
    /// client may legitimately re-enter. Used only when the task-local is
    /// unavailable — see `resolveSession`.
    private var activeTurns: [AcpSessionId: Int] = [:]

    /// What one ACP session has been granted for its lifetime.
    private struct SessionGrants {
        var allowsEdits = false
        var bashAllowed = false
        /// `reject-always` for bash. Denial outranks any later allow-always so
        /// that "No, and don't run bash commands" is actually permanent.
        var bashDenied = false
        var alwaysAllowed: Set<String> = []
    }

    public init(
        client: (any ACPPermissionReverseClient)? = nil,
        sessionId: AcpSessionId? = nil,
        timeoutSeconds: TimeInterval = LiveACPPermissionPrompter.defaultTimeoutSeconds
    ) {
        self.client = client
        self.sessionId = sessionId
        self.timeoutSeconds = timeoutSeconds
    }

    /// Install (or clear) the reverse client. Cleared client → deny.
    public func attach(client: (any ACPPermissionReverseClient)?) {
        self.client = client
    }

    /// Bind the ACP wire session id used when no turn is in flight and no
    /// task-local is set (single-session hosts and tests).
    public func bindSession(_ sessionId: AcpSessionId?) {
        self.sessionId = sessionId
    }

    /// Mark a `session/prompt` turn as started for `sessionId`.
    public func beginTurn(_ sessionId: AcpSessionId) {
        activeTurns[sessionId, default: 0] += 1
    }

    /// Mark a `session/prompt` turn as finished for `sessionId`.
    public func endTurn(_ sessionId: AcpSessionId) {
        guard let count = activeTurns[sessionId] else { return }
        if count <= 1 {
            activeTurns.removeValue(forKey: sessionId)
        } else {
            activeTurns[sessionId] = count - 1
        }
    }

    /// Drop every grant this prompter is holding for `sessionId`.
    ///
    /// `x.ai/permissions/reset` resets `PermissionHandle`, but the allow-always
    /// answers a client gave over the reverse channel live here, not there. A
    /// reset that clears only the handle leaves `isSessionPreapproved`
    /// returning allow, so the advertised reset does not revoke the
    /// permissions the client just granted.
    public func resetGrants(for sessionId: AcpSessionId?) {
        if let sessionId {
            grants.removeValue(forKey: sessionId)
        } else {
            grants.removeAll()
        }
    }

    /// How the session behind this prompt was determined.
    private enum SessionResolution {
        case resolved(AcpSessionId)
        /// Nothing to attribute the prompt to.
        case unknown
        /// Turns are in flight for more than one session and no task-local
        /// says which is ours. Attributing the request to a guess would show
        /// session B's user a prompt that authorizes session A's tool call.
        case ambiguous
    }

    private func resolveSession() -> SessionResolution {
        if let active = Self.activeSession {
            return .resolved(active)
        }
        if activeTurns.count == 1, let only = activeTurns.keys.first {
            return .resolved(only)
        }
        if activeTurns.count > 1 {
            return .ambiguous
        }
        if let sessionId {
            return .resolved(sessionId)
        }
        return .unknown
    }

    public func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        // No reverse channel means *cannot authorize* — fail closed, same
        // posture as `LiveWriteDenialPrompter` when nothing can paint a modal.
        guard let client else {
            return .reject(Self.unavailableMessage(toolName: toolName, access: access))
        }
        let sessionId: AcpSessionId
        switch resolveSession() {
        case .resolved(let resolved):
            sessionId = resolved
        case .unknown:
            return .reject(Self.unavailableMessage(toolName: toolName, access: access))
        case .ambiguous:
            return .reject(Self.failureMessage(
                toolName: toolName,
                detail: "the ACP session this request belongs to is ambiguous"
            ))
        }

        // Preapproval is checked AFTER the session resolves: a grant is a
        // property of one session, so an unattributable request has no grant
        // to consult and must reach the client (or fail closed above).
        if let decision = preapproved(access, session: sessionId) {
            return decision
        }

        let options = Self.buildOptions(for: access)
        let optionById = Dictionary(uniqueKeysWithValues: options.map { ($0.optionId.rawValue, $0) })
        let request = RequestPermissionRequest(
            sessionId: sessionId,
            toolCall: Self.toolCallUpdate(
                access: access,
                toolName: toolName,
                toolCallId: toolCallId
            ),
            options: options
        )

        let params: JSONValue
        do {
            params = try JSONValue.encode(request)
        } catch {
            return .reject(Self.failureMessage(toolName: toolName, detail: "encode failed"))
        }

        let responseJSON: JSONValue
        do {
            responseJSON = try await Self.requestWithTimeout(
                timeoutSeconds: timeoutSeconds,
                operation: {
                    try await client.requestClient(
                        method: ClientMethodNames.sessionRequestPermission,
                        params: params
                    )
                }
            )
        } catch is PermissionPromptTimeoutError {
            return .reject(Self.failureMessage(toolName: toolName, detail: "permission request timed out"))
        } catch is CancellationError {
            // `session/cancel` while the request is outstanding is a cancel,
            // not a denial. Rejecting here made the pipeline record a
            // PermissionDenied audit event and fire the deny hooks for an
            // operation the user merely cancelled. Cancelled is still not
            // allow, so this does not widen anything.
            return .cancelled
        } catch {
            if Task.isCancelled { return .cancelled }
            // Includes `ACPRuntimeError.transport("no ACP client is connected")`
            // when `setReverseSender` was never installed — still cannot authorize.
            return .reject(Self.failureMessage(toolName: toolName, detail: "failed to request permission"))
        }

        let response: RequestPermissionResponse
        do {
            response = try responseJSON.decode(RequestPermissionResponse.self)
        } catch {
            return .reject(Self.failureMessage(toolName: toolName, detail: "invalid permission response"))
        }

        return mapOutcome(
            response.outcome,
            optionById: optionById,
            access: access,
            toolName: toolName,
            session: sessionId
        )
    }

    // MARK: Outcome → decision

    /// Mirrors `map_selected_outcome` + cancelled/error arms at
    /// `prompter.rs:783-797` and `:873-1050` (generic-client subset).
    private func mapOutcome(
        _ outcome: RequestPermissionOutcome,
        optionById: [String: PermissionOption],
        access: AccessKind,
        toolName: String,
        session: AcpSessionId
    ) -> PermissionDecision {
        switch outcome {
        case .cancelled:
            // Cancelled is not allow — encode the distinction for readers.
            return .cancelled
        case .selected(let selected):
            guard let option = optionById[selected.optionId.rawValue] else {
                return .reject(Self.failureMessage(
                    toolName: toolName,
                    detail: "unknown permission option"
                ))
            }
            switch option.kind {
            case .allowOnce:
                return .allow
            case .allowAlways:
                grantSession(access: access, optionId: selected.optionId.rawValue, session: session)
                return .allow
            case .rejectOnce:
                return .reject("'\(toolName)' was denied.")
            case .rejectAlways:
                denySession(access: access, optionId: selected.optionId.rawValue, session: session)
                return .reject("'\(toolName)' was denied.")
            }
        }
    }

    private func grantSession(access: AccessKind, optionId: String, session: AcpSessionId) {
        var record = grants[session] ?? SessionGrants()
        switch access {
        case .edit:
            // `allow-edits-session` and generic `always-allow` for edits are
            // session-scoped in-memory only (`prompter.rs:967-969`).
            if optionId == Self.allowEditsSessionOptionId || optionId == Self.alwaysAllowOptionId {
                record.allowsEdits = true
            }
        case .bash:
            if optionId == Self.alwaysAllowOptionId {
                record.bashAllowed = true
            }
        case .webFetch(let url):
            record.alwaysAllowed.insert(url)
        case .mcpTool(let name, _):
            record.alwaysAllowed.insert(name)
        case .read, .grep, .webSearch:
            break
        }
        grants[session] = record
    }

    /// Record a `reject-always` answer. Only bash offers the option today; the
    /// switch is exhaustive so adding one elsewhere has to be handled here
    /// rather than silently degrading to reject-once.
    private func denySession(access: AccessKind, optionId: String, session: AcpSessionId) {
        guard optionId == Self.rejectAlwaysOptionId else { return }
        var record = grants[session] ?? SessionGrants()
        switch access {
        case .bash:
            record.bashDenied = true
        case .edit, .read, .grep, .webSearch, .webFetch, .mcpTool:
            return
        }
        grants[session] = record
    }

    /// A stored answer for `access`, or `nil` when the client must be asked.
    ///
    /// Returns a *decision*, not a Bool, because `reject-always` has to be
    /// answerable here too — a stored denial that only suppressed the allow
    /// path would still re-prompt and could then be approved.
    private func preapproved(_ access: AccessKind, session: AcpSessionId) -> PermissionDecision? {
        let record = grants[session] ?? SessionGrants()
        switch access {
        case .edit(let path):
            // `PermissionHandle` refuses to let a session grant authorize a
            // protected target (PermissionManager.swift:337-352, :365) — hooks
            // and config under `.opengrok`, SSH keys, shell startup files,
            // `/etc`. Those requests are routed here precisely because the
            // handle declined to answer them, so honoring our own session
            // grant would reinstate exactly what it withheld.
            if protectedEditPath(path, userGrokHome: userGrokHome()?.path) {
                return nil
            }
            return record.allowsEdits ? .allow : nil
        case .bash:
            if record.bashDenied { return .reject("bash commands were denied for this session.") }
            return record.bashAllowed ? .allow : nil
        case .webFetch(let url):
            return record.alwaysAllowed.contains(url) ? .allow : nil
        case .mcpTool(let name, _):
            return record.alwaysAllowed.contains(name) ? .allow : nil
        case .read, .grep, .webSearch:
            // NOT auto-allowed. `PermissionHandle` already allows safe access
            // on its own (PermissionManager.swift:355-363); a request that
            // reaches this prompter is one where it deliberately did not —
            // an explicit policy forced the ask, or `requestExitPlanApproval`
            // is asking for plan exit under a `.read(nil)` access. Answering
            // allow here silently defeated both.
            return nil
        }
    }

    // MARK: Options (generic ACP client)

    /// Stable ids from `prompter.rs:17-27, 370-488`.
    public static let allowOnceOptionId = "allow-once"
    public static let rejectOnceOptionId = "reject-once"
    public static let alwaysAllowOptionId = "always-allow"
    public static let rejectAlwaysOptionId = "reject-always"
    public static let allowEditsSessionOptionId = "allow-edits-session"

    private static let rejectOnceLabel = "No, and tell Grok what to do differently"

    static func buildOptions(for access: AccessKind) -> [PermissionOption] {
        switch access {
        case .edit:
            return [
                PermissionOption(
                    optionId: PermissionOptionId(allowEditsSessionOptionId),
                    name: "Yes, allow all edits during this session",
                    kind: .allowAlways
                ),
                PermissionOption(
                    optionId: PermissionOptionId(allowOnceOptionId),
                    name: "Yes",
                    kind: .allowOnce
                ),
                PermissionOption(
                    optionId: PermissionOptionId(rejectOnceOptionId),
                    name: rejectOnceLabel,
                    kind: .rejectOnce
                ),
            ]
        case .bash:
            // Generic (non-TUI) bash options — `prompter.rs:428-460`.
            return [
                PermissionOption(
                    optionId: PermissionOptionId(alwaysAllowOptionId),
                    name: "Yes, and don't ask again for bash commands",
                    kind: .allowAlways
                ),
                PermissionOption(
                    optionId: PermissionOptionId(allowOnceOptionId),
                    name: "Yes, proceed",
                    kind: .allowOnce
                ),
                PermissionOption(
                    optionId: PermissionOptionId(rejectOnceOptionId),
                    name: rejectOnceLabel,
                    kind: .rejectOnce
                ),
                PermissionOption(
                    optionId: PermissionOptionId(rejectAlwaysOptionId),
                    name: "No, and don't run bash commands",
                    kind: .rejectAlways
                ),
            ]
        default:
            return [
                PermissionOption(
                    optionId: PermissionOptionId(alwaysAllowOptionId),
                    name: "always allow",
                    kind: .allowAlways
                ),
                PermissionOption(
                    optionId: PermissionOptionId(allowOnceOptionId),
                    name: "allow once",
                    kind: .allowOnce
                ),
                PermissionOption(
                    optionId: PermissionOptionId(rejectOnceOptionId),
                    name: "reject once",
                    kind: .rejectOnce
                ),
            ]
        }
    }

    static func toolCallUpdate(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) -> ToolCallUpdate {
        let kind: ToolKind
        switch access {
        case .edit: kind = .edit
        case .bash: kind = .execute
        case .read: kind = .read
        case .grep: kind = .search
        case .webFetch, .webSearch: kind = .fetch
        case .mcpTool: kind = .other
        }
        let title: String
        if let detail = access.detail, !detail.isEmpty {
            title = "\(toolName): \(detail)"
        } else {
            title = toolName
        }
        return ToolCallUpdate(
            toolCallId: ToolCallId(toolCallId.isEmpty ? UUID().uuidString : toolCallId),
            kind: kind,
            status: .pending,
            title: title
        )
    }

    // MARK: Timeout + messages

    private static func requestWithTimeout(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> JSONValue
    ) async throws -> JSONValue {
        let nanos = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw PermissionPromptTimeoutError()
            }
            guard let value = try await group.next() else {
                throw PermissionPromptTimeoutError()
            }
            group.cancelAll()
            return value
        }
    }

    static func unavailableMessage(toolName: String, access: AccessKind) -> String {
        // Match the existing fail-closed copy so ACP without a reverse channel
        // is at least as strict as `LiveWriteDenialPrompter`.
        LiveWriteDenialPrompter.denialMessage(toolName: toolName, access: access)
    }

    static func failureMessage(toolName: String, detail: String) -> String {
        "'\(toolName)' needs approval, and \(detail)."
    }
}

private struct PermissionPromptTimeoutError: Error {}
