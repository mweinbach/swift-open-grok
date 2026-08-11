// LiveACPNotificationGateway.swift
//
// The live composition's half of the ACP notification gateway — Wave 15
// item 5. Two directions:
//
//   * Inbound ext notifications, dispatched by the runtime's
//     `ACPExtensionNotificationRouter` (upstream `ext_notification`,
//     `acp_agent.rs:4481-4720`):
//       - `x.ai/yolo_mode_changed`  (:4486-4553) → the LIVE permission-mode
//         handle (`LiveSessionPermissionMode` → `PermissionHandle`), never a
//         parallel flag.
//       - `x.ai/swarm_mode_changed` (:4555-4570) → the E8 `LiveSwarmModeState`
//         tracker, with upstream's `SwarmModeChanged` broadcast on both the
//         enter arm (reminders.rs:563-577) and the exited-disable arm
//         (run_loop.rs:1120-1138).
//       - `x.ai/permissions/reset`  (:4571-4586) → `PermissionHandle
//         .resetState()`, the port of `SessionCommand::ResetPermissionState`
//         (run_loop.rs:1139-1145 → permission/manager.rs:1456-1463).
//
//   * Outbound xAI session updates over `x.ai/session_notification`:
//       - `x.ai/recap` (extensions/recap.rs:21-58) acks `{ok:true}` and later
//         delivers `SessionUpdate::SessionRecap` / `SessionRecapUnavailable`
//         (recap.rs:497-506, :603-608) — the route E10 refused while no
//         notification path existed.
//       - `SubagentMessage` from the mailbox's accepted-send observer
//         (`ChildRunner::on_agent_message`, subagent_coordinator.rs:154-193)
//         — the E9 divergence 3, closed.
//
// Recorded divergences (each also noted at its arm):
//   1. yolo/permissions arms apply to THIS composition's single live stack;
//      upstream fans out over a session map filtered by
//      `origin_client.product` (upload/turn.rs:368-390). This port's ACP
//      carrier serves one stack per process, so `clientIdentifier` matching
//      is vacuous. Cost: a multi-product leader would over-apply.
//   2. The auto-mode arm sets `PermissionHandle.autoMode` (read by the
//      permission engine's classifier step) but wires no LLM classifier and
//      reads no `auto_permission_mode_enabled_from_disk` gate
//      (run_loop.rs:1106-1118); with no classifier installed the flag is
//      tracked and audited but non-fast-path tools still ask. Cost: a client
//      enabling auto sees ask-behavior until a classifier seam lands.
//   3. Outbound xAI updates are broadcast only, not persisted — upstream also
//      appends them to the session's `updates.jsonl`
//      (updates.rs:733-738, subagent mod.rs:2515-2519); this composition has
//      no per-session update journal. Cost: a reconnecting client cannot
//      replay them.
//   4. The recap arm has no watermark/idle gate and no new-prompt epoch
//      cancel (session_recap.rs:204-241, recap.rs:430-455): the port carries
//      neither the recap watermark file nor a prompt-epoch seam at the ACP
//      layer. Cost: `auto:true` requests recap unconditionally, and a recap
//      racing a new prompt still delivers.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokToolTypes
import OpenGrokWorkspace

// MARK: - Inbound router assembly

enum LiveACPInboundNotifications {
    /// The router the live ACP/serve compositions hand the runtime. The
    /// registered names are exactly the three Wave 15 item 5 arms; everything
    /// else upstream's `ext_notification` matches (`x.ai/toggle_plan_mode`,
    /// the `x.ai/queue/*` family, `x.ai/terminal/pty/input`,
    /// `_x.ai/session/update`, the leader-internal names) has no port surface
    /// at this seam and is ignored silently, upstream's own fall-through.
    static func build(
        permissionMode: LiveSessionPermissionMode?,
        permissions: PermissionHandle?,
        swarmMode: LiveSwarmModeState,
        gateway: ACPNotificationGateway,
        permissionPrompter: LiveACPPermissionPrompter? = nil
    ) -> ACPExtensionNotificationRouter {
        ACPExtensionNotificationRouter()
            .register(
                exact: LiveACPYoloModeHandler.method,
                handler: LiveACPYoloModeHandler(
                    permissionMode: permissionMode,
                    permissions: permissions
                )
            )
            .register(
                exact: LiveACPSwarmModeHandler.method,
                handler: LiveACPSwarmModeHandler(swarmMode: swarmMode, gateway: gateway)
            )
            .register(
                exact: LiveACPPermissionsResetHandler.method,
                handler: LiveACPPermissionsResetHandler(
                    permissions: permissions,
                    prompter: permissionPrompter
                )
            )
    }
}

// MARK: - x.ai/yolo_mode_changed

/// Inbound always-approve / auto-mode control (acp_agent.rs:4486-4553).
///
/// The yolo arm lands on `LiveSessionPermissionMode`, the SAME handle the
/// pager's Ctrl+O toggle mutates, so the display mode and the pipeline's
/// `PermissionHandle` move together and the managed YOLO pin keeps its veto
/// (upstream's manager clamps a pinned enable the same way,
/// run_loop.rs:1093-1105). The auto arm mirrors upstream's want/clear
/// derivation byte-for-logic (:4514-4525) onto `PermissionHandle.setAutoMode`.
struct LiveACPYoloModeHandler: ACPAgentExtensionNotificationHandler {
    static let method = "x.ai/yolo_mode_changed"

    let permissionMode: LiveSessionPermissionMode?
    let permissions: PermissionHandle?

    func handle(method: String, params: JSONValue) async {
        // `clientIdentifier` sender matching is vacuous here — one live
        // stack per process (divergence 1 in the file header).
        let yoloSignal = params["yolo_mode"]?.boolValue
        if let yolo = yoloSignal {
            await permissionMode?.applyInboundAlwaysApprove(yolo)
        }

        let modeString = params["permission_mode"]?.stringValue ?? ""
        let autoExplicit = params["auto_mode"]?.boolValue
        let wantAuto = autoExplicit == true || modeString == "auto"
        let clearAuto = autoExplicit == false
            || (["always-approve", "ask", "default"].contains(modeString) && !wantAuto)
        let enableAuto = wantAuto && yoloSignal != true
        if enableAuto {
            // Install the LLM classifier through the same display-mode handle
            // Shift+Tab / settings use — bare `setAutoMode` would leave the
            // composer flag and the heuristic default in place.
            _ = await permissionMode?.applyPermissionMode(.auto)
            if permissionMode == nil {
                await permissions?.setAutoMode(true)
            }
        } else if clearAuto {
            // Do not clobber an always-approve the yolo arm just applied.
            let leavingForYolo = yoloSignal == true || modeString == "always-approve"
            if !leavingForYolo {
                if let permissionMode {
                    let label = await permissionMode.permissionModeLabel()
                    if label == LiveSessionPermissionMode.DisplayMode.auto.rawValue {
                        _ = await permissionMode.applyPermissionMode(.ask)
                    }
                } else {
                    await permissions?.setAutoMode(false)
                }
            }
        }
    }
}

// MARK: - x.ai/swarm_mode_changed

/// Inbound swarm-mode control (acp_agent.rs:4555-4570), applied to the E8
/// tracker the `/swarm` slash path and the `agent_swarm` tool trigger share —
/// one tracker, so an inbound toggle and the turn loop's reminder injection
/// can never disagree.
struct LiveACPSwarmModeHandler: ACPAgentExtensionNotificationHandler {
    static let method = "x.ai/swarm_mode_changed"

    let swarmMode: LiveSwarmModeState
    let gateway: ACPNotificationGateway

    func handle(method: String, params: JSONValue) async {
        // All three fields are required and the trigger grammar is
        // manual|task only — anything else drops the whole notification
        // (upstream's `if let (Some, Some, Some)` gate, :4560-4568).
        guard let sessionID = params["sessionId"]?.stringValue,
              let enabled = params["enabled"]?.boolValue,
              let triggerRaw = params["trigger"]?.stringValue,
              let trigger = Self.trigger(from: triggerRaw)
        else { return }
        // Upstream applies only to a session the agent holds (:4564-4566).
        guard await gateway.sessionExists(AcpSessionId(sessionID)) else { return }

        if enabled {
            // `enter_swarm_mode` (reminders.rs:563-577): enter — a weaker
            // trigger never downgrades manual — then broadcast the EFFECTIVE
            // trigger, not the requested one.
            let effective = await swarmMode.enter(trigger)
            await gateway.sendXaiSessionUpdate(
                sessionID: sessionID,
                update: LiveXaiSessionUpdates.swarmModeChanged(
                    enabled: true,
                    trigger: effective.rawValue
                )
            )
        } else {
            // The disable arm (run_loop.rs:1122-1136): a task disable only
            // exits a task entry; anything else exits unconditionally. The
            // broadcast fires only when the mode was actually on.
            let exited: Bool
            if trigger == .task {
                exited = await swarmMode.exitIfTrigger(.task)
            } else {
                exited = await swarmMode.exitReportingChange()
            }
            if exited {
                await gateway.sendXaiSessionUpdate(
                    sessionID: sessionID,
                    update: LiveXaiSessionUpdates.swarmModeChanged(enabled: false, trigger: nil)
                )
            }
        }
    }

    static func trigger(from raw: String) -> SwarmModeTrigger? {
        switch raw {
        case "manual": return .manual
        case "task": return .task
        default: return nil
        }
    }
}

// MARK: - x.ai/permissions/reset

/// Inbound per-tool permission state reset (acp_agent.rs:4571-4586):
/// `SessionCommand::ResetPermissionState` → `permissions.reset_state()` →
/// state back to defaults including the session edit allow
/// (manager.rs:1456-1463). The port's `PermissionHandle.resetState()` drops
/// session grants, bash prefix grants and `allowEditsForSession`, keeping
/// disallows / pin / config — the same partition. Upstream also persists the
/// cleared state to disk; this handle is in-memory only (divergence 3's
/// sibling, recorded in the file header).
///
/// The ACP reverse prompter keeps its own allow-always answers (an ACP client
/// grants over `session/request_permission`, not through the handle), so the
/// reset has to clear BOTH. Resetting only the handle left
/// `isSessionPreapproved` returning allow for edits, bash, web fetch and MCP
/// tools the client had already granted — the advertised reset would not have
/// revoked the permissions it just granted.
struct LiveACPPermissionsResetHandler: ACPAgentExtensionNotificationHandler {
    static let method = "x.ai/permissions/reset"

    let permissions: PermissionHandle?
    let prompter: LiveACPPermissionPrompter?

    func handle(method: String, params: JSONValue) async {
        await permissions?.resetState()
        // A notification that names no session resets every session's grants:
        // for a reset, over-clearing costs an extra prompt while
        // under-clearing leaves an authorization standing.
        let sessionId = params["sessionId"]?.stringValue
            ?? params["session_id"]?.stringValue
        await prompter?.resetGrants(for: sessionId.map { AcpSessionId($0) })
    }
}

// MARK: - Outbound xAI session-update payloads

/// Wire payloads for the `update` field of `x.ai/session_notification`,
/// each mirroring one `SessionUpdate` variant's serde shape
/// (`#[serde(rename_all = "snake_case", tag = "sessionUpdate")]`,
/// extensions/notification.rs:440-442; variant fields keep their Rust
/// snake_case spellings).
enum LiveXaiSessionUpdates {
    /// `SessionUpdate::SessionRecap { summary, auto }`
    /// (notification.rs:591-601).
    static func sessionRecap(summary: String, auto: Bool) -> JSONValue {
        .object([
            "sessionUpdate": .string("session_recap"),
            "summary": .string(summary),
            "auto": .bool(auto),
        ])
    }

    /// `SessionUpdate::SessionRecapUnavailable` (notification.rs:605) — the
    /// signal that clears a manual `/recap` spinner; never sent for auto.
    static func sessionRecapUnavailable() -> JSONValue {
        .object(["sessionUpdate": .string("session_recap_unavailable")])
    }

    /// `SessionUpdate::SwarmModeChanged { enabled, trigger }`
    /// (notification.rs:443-448). `trigger` has no skip attribute upstream,
    /// so the disabled arm serializes an explicit null.
    static func swarmModeChanged(enabled: Bool, trigger: String?) -> JSONValue {
        .object([
            "sessionUpdate": .string("swarm_mode_changed"),
            "enabled": .bool(enabled),
            "trigger": trigger.map(JSONValue.string) ?? .null,
        ])
    }

    /// `SessionUpdate::SubagentMessage { ... }` (notification.rs:749-760),
    /// with the kind/status spellings `on_agent_message` maps
    /// (subagent_coordinator.rs:163-186): kind `message`/`followup_task`,
    /// status `queued`/`delivered` — this port's raw values verbatim.
    static func subagentMessage(
        _ message: AgentMailboxMessage,
        status: AgentMessageDeliveryStatus
    ) -> JSONValue {
        .object([
            "sessionUpdate": .string("subagent_message"),
            "message_id": .string(message.messageID),
            "team_scope_id": .string(message.teamScopeID),
            "from_agent_id": .string(message.fromAgentID),
            "to_agent_id": .string(message.toAgentID),
            "kind": .string(message.kind.rawValue),
            "body": .string(message.body),
            "status": .string(status.rawValue),
            "created_at_ms": .number(.uint64(message.createdAtMS)),
        ])
    }
}

// MARK: - x.ai/recap

/// The `x.ai/recap` extension method (extensions/recap.rs:21-58): parse
/// `{sessionId, auto?}`, gate on the session-recap feature, ack `{ok:true}`
/// inside the `ExtMethodResult` envelope, and generate the recap
/// fire-and-forget — delivered later as a `SessionRecap` session update, or
/// `SessionRecapUnavailable` on the manual path's empty/failed arms
/// (recap.rs:282-302, 396-428, 497-506).
///
/// The generation half reuses the E4 seams the pager's `/recap` uses:
/// `LiveRecap` pure helpers for the snapshot/instruction/tidy pass and
/// `LiveModelSwitchCoordinator.auxiliaryRecapRoute` for the model choice —
/// but reads the ACP-served stack's LIVE conversation history, which is the
/// same spine the turn driver appends to and compaction snapshots.
struct LiveRecapACPHandler: ACPAgentExtensionHandler, Sendable {
    static let method = "x.ai/recap"

    let gateway: ACPNotificationGateway
    /// A read of the live conversation spine (`LiveConversationHistory.items`
    /// in the composition; injectable so the carrier tests can pin payloads
    /// against a known conversation).
    let conversation: @Sendable () async -> [ConversationItem]
    /// `auxiliaryRecapRoute(explicitModelID:)` on the RUNNING session's
    /// coordinator — never nil, falls back to the active route.
    let recapRoute: @Sendable (String?) async -> (
        configuration: OpenGrokLiveSamplingConfiguration,
        sampler: OpenGrokLiveSampler
    )
    let workingDirectory: URL
    let openGrokHome: URL
    let environment: [String: String]
    /// Single-flight claim, upstream's `recap_in_flight` cell
    /// (recap.rs:292-306).
    private let flight = LiveRecapSingleFlight()

    init(
        gateway: ACPNotificationGateway,
        conversation: @escaping @Sendable () async -> [ConversationItem],
        recapRoute: @escaping @Sendable (String?) async -> (
            configuration: OpenGrokLiveSamplingConfiguration,
            sampler: OpenGrokLiveSampler
        ),
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) {
        self.gateway = gateway
        self.conversation = conversation
        self.recapRoute = recapRoute
        self.workingDirectory = workingDirectory
        self.openGrokHome = openGrokHome
        self.environment = environment
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        // Upstream deserializes `RecapRequest { session_id, auto }` in
        // camelCase and surfaces a parse failure through
        // `invalid_params().data("invalid params: …")` (recap.rs:22-30,
        // extensions/mod.rs:53-56). The prose after the prefix is
        // serde-generated there and hand-written here — recorded.
        guard let sessionID = params["sessionId"]?.stringValue else {
            throw AcpError(
                code: .invalidParams,
                message: AcpErrorCode.invalidParams.displayName,
                data: .string("invalid params: missing field `sessionId`")
            )
        }
        let auto = params["auto"]?.boolValue ?? false

        // Feature gate before the session lookup (recap.rs:36-39): default
        // ON, disabled via `GROK_SESSION_RECAP` / `[features] session_recap`.
        guard LiveRecap.enabled(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) else {
            return .object(["result": .object([
                "ok": .bool(true),
                "disabled": .bool(true),
            ])])
        }

        // Session lookup (recap.rs:45-49). The load-race wait upstream
        // performs is not needed here: this runtime's store is answered by
        // the same actor that serves `session/load`.
        guard await gateway.sessionExists(AcpSessionId(sessionID)) else {
            throw AcpError(
                code: .invalidParams,
                message: AcpErrorCode.invalidParams.displayName,
                data: .string("session not found: \(sessionID)")
            )
        }

        // Fire-and-forget (recap.rs:51-57): only the acceptance is acked; the
        // recap arrives later as a SessionRecap notification.
        let handler = self
        Task {
            await handler.generate(sessionID: sessionID, auto: auto)
        }
        return .object(["result": .object(["ok": .bool(true)])])
    }

    private func generate(sessionID: String, auto: Bool) async {
        guard await flight.begin() else {
            // Another recap is in flight; the manual path answers through
            // the unavailable notification so the client's spinner clears
            // (recap.rs:296-302).
            if !auto { await emitUnavailable(sessionID: sessionID) }
            return
        }
        // The claimed body never throws and every arm falls through to here,
        // so the release is deterministic — a `defer`-spawned Task would
        // release on an unordered hop and let a racing second recap slip
        // past the claim.
        await generateClaimed(sessionID: sessionID, auto: auto)
        await flight.end()
    }

    private func generateClaimed(sessionID: String, auto: Bool) async {
        let conversation = await conversation()
        // `recap_gate`'s nothing-to-recap arm (session_recap.rs:232-241):
        // no real user turns means no request leaves the machine.
        guard LiveRecap.mainTurnCount(conversation) > 0 else {
            if !auto { await emitUnavailable(sessionID: sessionID) }
            return
        }

        let configured = LiveRecap.configuredModel(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        )
        let route = await recapRoute(configured)
        // Reasoning strips only where the backend rejects replayed thinking
        // blocks (session_recap.rs:62-74).
        let items = LiveRecap.buildItems(
            conversation: conversation,
            tag: "system-reminder",
            stripReasoning: route.configuration.apiBackend == .messages
        )
        do {
            // Tool-free side-call, the same divergence the pager arm records
            // (upstream ships the main turn's tool specs for prefix-cache
            // parity, recap.rs:354-358; this seam has no reach into the live
            // tool surface). Deltas never stream anywhere — display-only.
            let response = try await route.sampler.sample(
                OpenGrokLiveSamplingRequest(
                    sessionID: sessionID,
                    turnID: "xai-recap-\(UUID().uuidString)",
                    model: route.configuration.model,
                    prompt: LiveRecap.instruction(tag: "system-reminder"),
                    items: items,
                    tools: []
                )
            ) { _ in }
            let summary = LiveRecap.cleanText(response.output)
            if summary.isEmpty {
                // Empty after the tidy pass reads as no recap
                // (recap.rs:405-428).
                if !auto { await emitUnavailable(sessionID: sessionID) }
            } else {
                // The delivery (recap.rs:497-506).
                await gateway.sendXaiSessionUpdate(
                    sessionID: sessionID,
                    update: LiveXaiSessionUpdates.sessionRecap(summary: summary, auto: auto)
                )
            }
        } catch {
            // A failed side-call never breaks the session; the error detail
            // goes nowhere but tracing upstream (recap.rs:378-401).
            if !auto { await emitUnavailable(sessionID: sessionID) }
        }
    }

    private func emitUnavailable(sessionID: String) async {
        await gateway.sendXaiSessionUpdate(
            sessionID: sessionID,
            update: LiveXaiSessionUpdates.sessionRecapUnavailable()
        )
    }
}

/// The `recap_in_flight` cell (recap.rs:292-306): claim after the gates with
/// no await between check and set — actor isolation makes the pair atomic.
actor LiveRecapSingleFlight {
    private var inFlight = false

    func begin() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    func end() {
        inFlight = false
    }
}
