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

    private var client: (any ACPPermissionReverseClient)?
    private var sessionId: AcpSessionId?
    private let timeoutSeconds: TimeInterval
    private var allowsEditsForSession = false
    private var bashAlwaysAllowed = false
    private var otherAlwaysAllowed: Set<String> = []

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

    /// Bind the ACP wire session id the next prompt will advertise.
    public func bindSession(_ sessionId: AcpSessionId?) {
        self.sessionId = sessionId
    }

    public func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        if isSessionPreapproved(access) {
            return .allow
        }

        // No reverse channel means *cannot authorize* — fail closed, same
        // posture as `LiveWriteDenialPrompter` when nothing can paint a modal.
        guard let client else {
            return .reject(Self.unavailableMessage(toolName: toolName, access: access))
        }
        guard let sessionId else {
            return .reject(Self.unavailableMessage(toolName: toolName, access: access))
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
        } catch {
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
            toolName: toolName
        )
    }

    // MARK: Outcome → decision

    /// Mirrors `map_selected_outcome` + cancelled/error arms at
    /// `prompter.rs:783-797` and `:873-1050` (generic-client subset).
    private func mapOutcome(
        _ outcome: RequestPermissionOutcome,
        optionById: [String: PermissionOption],
        access: AccessKind,
        toolName: String
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
                grantSession(access: access, optionId: selected.optionId.rawValue)
                return .allow
            case .rejectOnce, .rejectAlways:
                return .reject("'\(toolName)' was denied.")
            }
        }
    }

    private func grantSession(access: AccessKind, optionId: String) {
        switch access {
        case .edit:
            // `allow-edits-session` and generic `always-allow` for edits are
            // session-scoped in-memory only (`prompter.rs:967-969`).
            if optionId == Self.allowEditsSessionOptionId || optionId == Self.alwaysAllowOptionId {
                allowsEditsForSession = true
            }
        case .bash:
            if optionId == Self.alwaysAllowOptionId {
                bashAlwaysAllowed = true
            }
        case .webFetch(let url):
            otherAlwaysAllowed.insert(url)
        case .mcpTool(let name, _):
            otherAlwaysAllowed.insert(name)
        case .read, .grep, .webSearch:
            break
        }
    }

    private func isSessionPreapproved(_ access: AccessKind) -> Bool {
        switch access {
        case .edit:
            return allowsEditsForSession
        case .bash:
            return bashAlwaysAllowed
        case .webFetch(let url):
            return otherAlwaysAllowed.contains(url)
        case .mcpTool(let name, _):
            return otherAlwaysAllowed.contains(name)
        case .read, .grep, .webSearch:
            return true
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
