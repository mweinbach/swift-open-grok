// HookPermissionGate.swift
//
// Connects the hook dispatcher to the permission pipeline's `PreToolUse` seam.
//
// The pipeline exposes `PreToolUseHookRunner` and ships only `Noop` and
// `FailOpen` conformers, so hooks were discovered and parsed but never
// consulted. This type is the real conformer.
//
// Gate order is fixed by PORT_PLAN.md: plan edit gate, then PreToolUse hooks
// (operational failures fail open but are recorded), then plan-file
// auto-approval, then permission evaluation. Hooks therefore run BEFORE
// permission evaluation and a hook `allow` does not skip it — only `deny`
// short-circuits, and it does so as a rejection the model sees.

import Foundation
import OpenGrokConfig
import OpenGrokHooksPluginTypes
import OpenGrokShared
import OpenGrokWorkspace

/// Session facts every hook invocation carries in its envelope.
public struct HookSessionContext: Sendable {
    public var sessionId: String
    public var workspaceRoot: URL
    public var cwd: String
    public var environment: [String: String]
    public var transcriptPath: String?
    public var clientIdentifier: String?

    public init(
        sessionId: String,
        workspaceRoot: URL,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transcriptPath: String? = nil,
        clientIdentifier: String? = nil
    ) {
        self.sessionId = sessionId
        self.workspaceRoot = workspaceRoot
        self.cwd = cwd ?? workspaceRoot.path
        self.environment = environment
        self.transcriptPath = transcriptPath
        self.clientIdentifier = clientIdentifier
    }

    var runContext: HookRunContext {
        HookRunContext(sessionId: sessionId, workspaceRoot: workspaceRoot, environment: environment)
    }
}

/// Dispatcher-backed `PreToolUse` gate, plus the `Stop` turn-end dispatch.
///
/// Records from every dispatch accumulate so the session can surface which
/// hooks ran, which were skipped, and which failed open.
public final class HookPermissionGate: PreToolUseHookRunner, @unchecked Sendable {
    public let dispatcher: HookDispatcher
    public let context: HookSessionContext

    private let lock = NSLock()
    private var records: [HookRunRecord] = []

    public init(dispatcher: HookDispatcher, context: HookSessionContext) {
        self.dispatcher = dispatcher
        self.context = context
    }

    /// Whether any enabled `PreToolUse` hook exists. When false the pipeline
    /// still calls through, but no subprocess is ever spawned.
    public var hasPreToolUseHooks: Bool {
        dispatcher.registry.hasEnabledHooks(
            for: .preToolUse,
            disabledNames: dispatcher.disabledNames
        )
    }

    public var hasStopHooks: Bool {
        dispatcher.registry.hasEnabledHooks(for: .stop, disabledNames: dispatcher.disabledNames)
    }

    // MARK: PreToolUseHookRunner

    public func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        guard hasPreToolUseHooks else { return .allow }

        let envelope = HookEventEnvelope(
            hookEventName: .preToolUse,
            sessionId: context.sessionId,
            cwd: context.cwd,
            workspaceRoot: context.workspaceRoot.path,
            transcriptPath: context.transcriptPath,
            clientIdentifier: context.clientIdentifier,
            permissionMode: permissionMode,
            payload: preToolUsePayload(
                toolName: toolName,
                toolCallId: toolCallId,
                access: access
            )
        )

        let result = await dispatcher.dispatchPreToolUse(
            envelope: envelope,
            context: context.runContext
        )
        append(result.results)

        // Anything other than an explicit deny proceeds. A hook that timed out,
        // crashed, or emitted garbage is recorded as `.failed` by the
        // dispatcher and does not authorize or block on its own.
        switch result.decision {
        case .allow:
            return .allow
        case .deny(let reason, let hookName):
            return .deny(reason: reason, hookName: hookName)
        }
    }

    // MARK: Stop

    /// Turn-end `Stop` dispatch. Returns the blocks and additional context the
    /// session should feed back before ending the turn.
    public func runStop(event: HookEvent = .stop, promptId: String? = nil) async -> StopDispatchResult {
        guard dispatcher.registry.hasEnabledHooks(
            for: event,
            disabledNames: dispatcher.disabledNames
        ) else {
            return StopDispatchResult()
        }
        let envelope = HookEventEnvelope(
            hookEventName: event,
            sessionId: context.sessionId,
            cwd: context.cwd,
            workspaceRoot: context.workspaceRoot.path,
            transcriptPath: context.transcriptPath,
            clientIdentifier: context.clientIdentifier,
            promptId: promptId
        )
        let result = await dispatcher.dispatchStop(
            event: event,
            envelope: envelope,
            context: context.runContext
        )
        append(result.results)
        return result
    }

    // MARK: Records

    /// Every record accumulated so far, oldest first.
    public func recordedRuns() -> [HookRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    /// Records accumulated so far, clearing the buffer.
    public func drainRecords() -> [HookRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        let drained = records
        records.removeAll(keepingCapacity: true)
        return drained
    }

    private func append(_ new: [HookRunRecord]) {
        guard !new.isEmpty else { return }
        lock.lock()
        records.append(contentsOf: new)
        lock.unlock()
    }

    private func preToolUsePayload(
        toolName: String,
        toolCallId: String,
        access: AccessKind
    ) -> [String: HookJSONValue] {
        // `toolName` must come first: it is what `HookEventEnvelope.matchValue`
        // feeds to a hook's matcher.
        var payload: [String: HookJSONValue] = [
            "toolName": .string(toolName),
            "toolCallId": .string(toolCallId),
            "accessKind": .string(access.label),
        ]
        if let detail = access.detail {
            payload["accessDetail"] = .string(detail)
        }
        if case .mcpTool(_, let input) = access {
            payload["toolInput"] = hookJSON(from: input)
        }
        return payload
    }
}

/// Bridge `JSONValue` (tool/permission layer) into the hook envelope's own
/// JSON representation.
func hookJSON(from value: JSONValue) -> HookJSONValue {
    switch value {
    case .null:
        return .null
    case .bool(let flag):
        return .boolean(flag)
    case .string(let text):
        return .string(text)
    case .number(let number):
        if let exact = number.int64Value { return .integer(exact) }
        return .number(number.doubleValue)
    case .array(let items):
        return .array(items.map(hookJSON(from:)))
    case .object(let object):
        return .object(object.mapValues(hookJSON(from:)))
    }
}
