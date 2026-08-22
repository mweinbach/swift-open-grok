// LiveSubagentHost.swift
//
// The live half of the subagent stack: one `OpenGrokAgentCoordinator` per root
// session, plus the shell-child runner that turns a `spawn_subagent` tool call
// into a real headless child session.
//
// Parity anchors (pin 70002584):
//   * spawn validation order and error copy — `xai-grok-tools/.../task/mod.rs`
//     (`TaskTool::run` steps 1-6).
//   * child construction — `xai-grok-shell/.../subagent/handle_request.rs`
//     (`run_shell_child`): the child gets its own conversation and session
//     persistence, the parent's credentials (the same sampler), a tool policy
//     with the nested-spawn and plan surfaces stripped, capability clamping
//     against the parent ceiling, and cancellation owned by the coordinator.
//   * the `get_task_output` / `wait_tasks` / `kill_task` unification —
//     `xai-grok-tools/.../task_output/mod.rs` and `kill_task/mod.rs`: shell
//     task ids and subagent ids share one namespace; a miss on the shell side
//     falls through to the coordinator.
//
// `agent_swarm` lives in `LiveSubagentSwarm.swift` as an extension on this
// actor: the swarm scheduler drives the same coordinator and the same
// `runChild` runner, so a swarm member is a real child in every observable
// way (`/tasks`, `get_task_output`, `kill_task`, `resume_from`).
//
// The collaboration quartet (`list_agents` / `send_message` / `followup_task`
// / `wait_agent`) rides this host too: the coordinator owns the mailboxes,
// `installCollaborationRouting` wires the live follow-up delivery (root
// interjection seam + per-child round-boundary buffers below), and `runChild`
// hands each child a `LiveAgentCollaboration` with its team identity.
//
// Deliberately absent here (recorded in the slice report): worktree
// isolation, the foreground await budget with auto-backgrounding, and durable
// cross-process resume metadata. Antigravity CLI runners live in
// `LiveAntigravity.swift` / `LiveAntigravityRunner.swift` and branch from
// `spawn` when the resolved model carries the `antigravity:` prefix. Ordinary
// children resume from the conversation store; Antigravity children resume
// within the process from their retained `--conversation` id.

import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokFileTools
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokInterjection
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokSubagentResolution
import OpenGrokToolTypes
import OpenGrokWorkspace

/// Outcome of a `kill_task` aimed at a subagent id. Mirrors Rust
/// `SubagentCancelOutcome` (task/types.rs).
enum LiveSubagentCancelOutcome: Sendable, Equatable {
    case cancelled
    case alreadyFinished(status: String)
    case notFound
}

/// A render-ready view of one child for the background-task family.
///
/// The coordinator owns lifecycle truth; this carries what
/// `LiveBackgroundTaskTools` needs to render the upstream
/// `format_subagent_snapshot` shapes (task_output/mod.rs:624+) without
/// knowing about the coordinator at all.
struct LiveSubagentSnapshot: Sendable, Equatable {
    var subagentID: String
    var subagentType: String
    var description: String
    /// `running`, `completed`, `failed`, or `cancelled` — the terminal
    /// vocabulary `TaskOutputResult.isTerminal` already recognizes.
    var status: String
    var output: String
    var startedAt: Date
    var durationMS: UInt64
    var exitCode: Int32?
    var turnCount: UInt32 = 0
    var toolCallCount: UInt32 = 0

    var completed: Bool { status != "running" }
}

/// The seam `LiveBackgroundTaskTools` consumes. One conformer: the session's
/// `LiveSubagentHost`. The protocol exists so the background-task tools stay
/// testable without standing up a sampler.
protocol LiveSubagentQuerying: Sendable {
    func subagentSnapshot(id: String) async -> LiveSubagentSnapshot?
    func awaitSubagent(id: String, timeoutMS: UInt64) async -> LiveSubagentSnapshot?
    func cancelSubagent(id: String) async -> LiveSubagentCancelOutcome
    func knownSubagentIDs() async -> [String]
}

/// Whether a subagent child id is safe to use as a single path component.
///
/// Same alphabet as `LiveConversationStore.validateSessionID` — the ids share a
/// directory tree, so a value one accepts and the other rejects would be a
/// silent inconsistency. `.` and `..` are rejected outright; every other
/// traversal form is already excluded because `/`, `\` and `:` are not in the
/// allowed set.
func isSafeSubagentChildID(_ id: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return !id.isEmpty
        && id.count <= 128
        && id != "."
        && id != ".."
        && id.allSatisfy(allowed.contains)
}

func resolveSubagentModelProvider(_ model: String) -> ModelProvider? {
    let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch lower {
    case "xai", "grok": return .xai
    case "codex", "openai", "openai_codex": return .codex
    case "kimi", "moonshot", "moonshot_ai": return .kimi
    case "fireworks", "fireworks_ai": return .fireworks
    case "deepseek", "deep_seek", "deepseek_api", "deepseek-api": return .deepseek
    case "meta", "meta_ai", "meta-ai", "meta_api", "meta-api": return .meta
    case "opencode_go", "opencode-go", "opencode", "go": return .openCodeGo
    case "wafer", "wafer_ai", "wafer-ai": return .wafer
    case "zai", "z_ai", "z-ai", "zai_api", "zai-api", "glm": return .zai
    default:
        if lower.hasPrefix("grok") { return .xai }
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("codex") { return .codex }
        if lower.hasPrefix("kimi") || lower.hasPrefix("moonshot") { return .kimi }
        if lower.hasPrefix("fireworks") { return .fireworks }
        if lower.hasPrefix("deepseek") { return .deepseek }
        if lower.hasPrefix("claude") { return .openCodeGo }
        if lower.hasPrefix("wafer") { return .wafer }
        if lower.hasPrefix("glm") || lower.hasPrefix("zai") { return .zai }
        return nil
    }
}

/// The root turn's prompt scope follows its tool batch across actor hops and
/// task-group children without leaking into the session's next turn.
enum LiveSubagentParentPromptContext {
    @TaskLocal static var promptID: String?
}

actor LiveSubagentHost: LiveSubagentQuerying {
    /// A child provider must bring its own endpoint, credentials, and adapter;
    /// changing only the model on the parent's sampler is not provider routing.
    struct ChildSamplerRoute: Sendable {
        var sampler: OpenGrokLiveSampler
        var provider: ModelProvider
        var codexPermissions: CodexPermissions?

        init(
            sampler: OpenGrokLiveSampler,
            provider: ModelProvider,
            codexPermissions: CodexPermissions? = nil
        ) {
            self.sampler = sampler
            self.provider = provider
            self.codexPermissions = provider == .codex ? codexPermissions : nil
        }
    }

    /// Everything a child inherits from the root session, gathered once so
    /// `spawn` does not grow a dozen loose parameters. The sampler carries the
    /// parent's resolved credentials; the security context and sandbox
    /// decision are the parent's own, so a child runs under exactly the
    /// session's policy rather than a re-resolved one that could drift.
    struct Context: Sendable {
        var sampler: OpenGrokLiveSampler
        var parentModel: String
        var workingDirectory: URL
        /// The root session id. Children are scoped to it: cancellation of
        /// the session tears them down, and their ids share the background
        /// task namespace only within this session.
        var sessionID: String
        var openGrokHome: URL
        var conversationStore: LiveConversationStore
        var processBackend: any ShellProcessBackend
        var securityContext: LiveSecurityContext
        var sandboxDecision: LiveSandboxDecision
        var permissionOptions: CLIPermissionOptions
        var fileAccessPolicy: FileToolAccessPolicy
        var telemetryBootstrapContext: LiveTelemetryBootstrapContext
        var imageToolContext: LiveImageToolContext?
        var webToolContext: LiveWebToolContext?
        var environment: [String: String]
        /// The parent session's capability ceiling. `nil` (no agent profile)
        /// means no clamp, matching upstream's `Option<SubagentCapabilityMode>`.
        var parentCapabilityCeiling: OpenGrokSubagentResolution.SubagentCapabilityMode?
        var definitionContext: DefinitionResolutionContext
        /// Public catalog slugs the `model` parameter may name.
        var modelSlugs: [String]
        /// Whether the advertised `model` contract should also name the
        /// `antigravity:<model>` form. Both halves of the gate are the cheap
        /// synchronous checks the settings rows already use — the config
        /// toggle and the CLI being installed — never an `agy models` probe.
        var antigravitySelectable: Bool = false
        /// Trust-independent personas — inline `[subagents.personas]` plus
        /// the user and bundled persona directories — loaded once at session
        /// build (upstream `resolve_subagents`, agent/config.rs:2255-2263).
        /// The trusted project overlay is recomputed per spawn in
        /// `effectiveSpawnPersonas()`, never cached here.
        var basePersonas: [String: SubagentPersona] = [:]
        /// Matches the root turn loop's ceiling (`LiveComposition.swift`
        /// `runTurn`): a child that has not converged in this many tool
        /// rounds is looping.
        var maxToolRounds: Int = 16
        /// Injectable Antigravity CLI seam. Defaults to production so
        /// `makeSubagentHost` needs no LiveComposition edit; tests swap a
        /// fake that returns canned stdout/exit codes.
        var antigravityServices: LiveAntigravityServices = .production
        /// The parent session's export boundary, monotonically closed if a child runs on a non-xAI provider.
        var parentExportBoundary: ExportBoundary? = nil
        /// Persisted boundary sync callback to update parent session summary.
        var providerBoundarySync: (@Sendable (Bool) async throws -> Void)? = nil
        /// Forks retain their source's prompt-cache route across child turns.
        var parentCacheAffinityID: String? = nil
        /// Authoritative parent provider from resolved model metadata.
        var parentProvider: ModelProvider? = nil
        /// The parent's applied execution policy, disclosed only to Codex.
        var parentCodexPermissions: CodexPermissions? = nil
        /// Resolves another model into its own provider transport and scoped
        /// credentials. Cross-provider children fail closed when unavailable.
        var childSamplerFactory: (
            @Sendable (String, CodexPermissions?) async throws -> ChildSamplerRoute
        )? = nil
    }

    /// The one coordinator per root session (scope item 1). Exposed
    /// `nonisolated let` so the session can also tear it down directly.
    nonisolated let coordinator: OpenGrokAgentCoordinator
    /// The spec the live tool list advertises. Built once: the roster and the
    /// model catalog are launch-time facts here, exactly as upstream builds
    /// the description in `AgentBuilder::build`.
    nonisolated let toolSpec: ToolSpec
    /// What the running turn is parked on. `agent_swarm` raises the
    /// orchestration depth for the duration of its cohort; the interactive
    /// controller reads it on the send-now path so an arriving prompt
    /// promotes instead of cancelling (the port of `BlockingWaitState`,
    /// shell tools/tool_context.rs:76-117).
    nonisolated let foregroundWait = LiveForegroundWaitState()
    nonisolated let swarmRegistry = SwarmRegistry()

    let context: Context

    /// Bookkeeping the coordinator deliberately does not carry (its request
    /// type is a wire-frozen Codable): spawn wall-clock, the model-facing
    /// type/description, live progress, terminal stats, and the in-session
    /// resume index.
    ///
    /// `childCWD` / `worktreePath` are the same-process half of upstream's
    /// `SubagentMeta.child_cwd` / `worktree_path` (handle_request.rs:830-832):
    /// a resume reads them here before selecting the new child's cwd. They are
    /// not durable across process restarts — that needs the meta.json path
    /// upstream writes under the parent session's `subagents/<id>/`.
    struct Bookkeeping {
        var startedAt: Date
        var subagentType: String
        var description: String
        var model: String
        /// The persona the child resolved with, kept so a resume re-applies
        /// it (upstream inherits the source's persona before resolution,
        /// handle_request.rs:255-258, and records it per child,
        /// task/coordinator_state.rs:639).
        var persona: String? = nil
        /// Effective working directory the child actually ran with (after
        /// worktree / override / parent precedence). Resume inherits this
        /// when the source was not worktree-backed (`resume_inherited_cwd`,
        /// subagent/mod.rs:1605-1620). `nil` means "not recorded" (older
        /// in-session entries / swarm path that has not yet adopted the
        /// field) — resume then falls back to the parent workspace.
        var childCWD: URL? = nil
        /// Isolated worktree path when one was recorded for the child.
        /// Resume reuses it when still on disk; recorded *presence*
        /// (`is_some`) also suppresses `childCWD` inheritance when the
        /// directory is gone — Shared/parent, not a stale sibling cwd
        /// (`resume_inherited_cwd`, subagent/mod.rs:1619-1622;
        /// `ResumeWorktreeAction::Shared`, handle_request.rs:462-468).
        /// Worktree *creation* is still absent from this host; the field
        /// only preserves a path already represented in bookkeeping.
        var worktreePath: URL? = nil
        var turns: UInt32 = 0
        var toolCalls: UInt32 = 0
        var toolsUsed: [String] = []
        var errors: UInt32 = 0
        var terminalToolCalls: UInt32?
        var terminalTurns: UInt32?
        var liveItems: [ConversationItem] = []
        var antigravityConversationID: String? = nil
        var antigravityPhase: String? = nil
    }
    var bookkeeping: [String: Bookkeeping] = [:]
    private var childExecutors: [String: LiveToolExecutor] = [:]
    private var parentPermissionHandle: PermissionHandle?
    private var parentUsageHistory: LiveConversationHistory?

    /// Children whose `runChild` loop is live right now — the set the
    /// follow-up router consults before buffering. Upstream's analog is the
    /// child's session command channel staying open (`deliver_followup`,
    /// subagent/mod.rs:468-478).
    private var liveChildLoopIDs: Set<String> = []
    /// Follow-ups awaiting a child's next sampler round. The port of the
    /// child session's `pending_interjections` arm for
    /// `SessionCommand::AgentMessage` (run_loop.rs:2006-2020): a running
    /// recipient takes the message at the round boundary, never mid-round.
    private var pendingChildFollowups: [String: [AgentMailboxMessage]] = [:]

    /// Optional status-chip sink. Composition installs a weak renderer hop;
    /// tests install a recorder. Cleared with `nil`.
    private var activeBackgroundWorkSink: LiveActiveBackgroundWorkSink?
    /// Child ids we have upserted and not yet removed. Membership is the
    /// single-remove latch: cancel cleanup and `shutdown` race without
    /// double-emitting.
    private var countedActiveBackgroundWorkIDs: Set<String> = []

    init(context: Context) {
        self.context = context
        self.coordinator = OpenGrokAgentCoordinator()
        self.toolSpec = Self.makeToolSpec(context: context)
    }

    /// Children share the root's mutable approvals while retaining their own
    /// fresh plan tracker and hooks; toggling the parent updates live children.
    func installParentPermissionHandle(_ handle: PermissionHandle) {
        parentPermissionHandle = handle
    }

    /// The root owns the only parent billing ledger; children must await its
    /// acknowledged fold before becoming visible as completed.
    func installParentUsageHistory(_ history: LiveConversationHistory) {
        parentUsageHistory = history
    }

    // MARK: - Active background work (status-chip push)

    /// Install or replace the optional active-background-work sink.
    ///
    /// Passing `nil` clears the sink without emitting removes — still-running
    /// children remove through structured cleanup / `shutdown` if a sink is
    /// reinstalled later (late remove is idempotent on the cache side).
    func setActiveBackgroundWorkSink(_ sink: LiveActiveBackgroundWorkSink?) {
        activeBackgroundWorkSink = sink
    }

    /// Whether a registered child contributes to Rust
    /// `TasksPane::running_count` subagent half (`tasks_pane.rs:1143-1146`):
    /// running and `workflow_run_id.is_none()`.
    ///
    /// Port markers on `OpenGrokChildRequest`: non-nil `workflowRunID`, or
    /// `owner == .workflow`. `LiveSubagentHost.spawn` and the swarm path
    /// never set either today — workflow children are not registered through
    /// this host — so the filter is latent. Do not invent a separate
    /// bookkeeping flag; if a future workflow registration omits the marker,
    /// it would incorrectly count (recorded port limitation).
    static func countsTowardActiveBackgroundWork(
        _ request: OpenGrokChildRequest
    ) -> Bool {
        if request.workflowRunID != nil { return false }
        if request.owner == .workflow { return false }
        return true
    }

    /// Upsert after coordinator registration, then await exactly one remove
    /// when `body` returns — success, failure, or cancel. Not
    /// `defer { Task { … } }`: that is fire-and-forget and can lose the
    /// remove under teardown.
    func withActiveBackgroundWorkCounting(
        for request: OpenGrokChildRequest,
        body: () async -> OpenGrokChildResult
    ) async -> OpenGrokChildResult {
        let counts = Self.countsTowardActiveBackgroundWork(request)
        if counts {
            await emitActiveBackgroundWorkUpsert(id: request.id)
        }
        let result = await body()
        if counts {
            await emitActiveBackgroundWorkRemove(id: request.id)
        }
        return result
    }

    /// Internal so the swarm extension (separate file) can roll back on
    /// failed registration. Latch makes a no-op when upsert never ran.
    func emitActiveBackgroundWorkUpsert(id: String) async {
        guard countedActiveBackgroundWorkIDs.insert(id).inserted else { return }
        guard let event = LiveActiveBackgroundWorkEvent.upsert(
            kind: .subagent,
            id: id
        ) else {
            countedActiveBackgroundWorkIDs.remove(id)
            return
        }
        await activeBackgroundWorkSink?(event)
    }

    /// Internal so the swarm extension can share the single-remove latch.
    func emitActiveBackgroundWorkRemove(id: String) async {
        guard countedActiveBackgroundWorkIDs.remove(id) != nil else { return }
        guard let event = LiveActiveBackgroundWorkEvent.remove(
            kind: .subagent,
            id: id
        ) else { return }
        await activeBackgroundWorkSink?(event)
    }

    // MARK: - Collaboration routing (the followup_task live-delivery seam)

    /// Wire the coordinator's follow-up delivery to this host: root messages
    /// go to the session's mid-turn interjection seam, child messages to the
    /// per-child round-boundary buffers. Called from `makeAgentStack` once
    /// the interjection actor exists; until then the coordinator queues every
    /// follow-up, which is also its behavior for hosts with no live seam.
    ///
    /// Root divergence (recorded): upstream's idle root starts a synthetic
    /// `agent-message-{id}` prompt turn (run_loop.rs:2012-2050); this port
    /// has no session-owned prompt queue to start one, so an idle root's
    /// follow-up queues in its mailbox (status "queued") and surfaces on the
    /// root's next `wait_agent` instead of waking it.
    func installCollaborationRouting(rootInterjections: LiveSessionInterjections) async {
        let rootSessionID = context.sessionID
        await coordinator.installMailboxHooks(deliverFollowup: { [weak self] target, message in
            if target == rootSessionID {
                return await rootInterjections.interject(agentMessageEnvelope(message))
            }
            guard let self else { return false }
            return await self.deliverChildFollowup(target: target, message: message)
        })
    }

    /// Subscribe an observer to every accepted mailbox send — the port of
    /// `ChildRunner::on_agent_message` (subagent_coordinator.rs:154-193). The
    /// ACP composition points this at the notification gateway so each send
    /// becomes a client-facing `SubagentMessage` session update on the root
    /// session's channel.
    func installAgentMessageObserver(
        _ observer: @escaping @Sendable (AgentMailboxMessage, AgentMessageDeliveryStatus) -> Void
    ) async {
        await coordinator.installAgentMessageObserver(observer)
    }

    /// Buffer a follow-up for a child whose loop is live. `false` sends the
    /// coordinator down its queue/error arms, exactly like upstream's failed
    /// command-channel send.
    private func deliverChildFollowup(target: String, message: AgentMailboxMessage) -> Bool {
        guard liveChildLoopIDs.contains(target) else { return false }
        pendingChildFollowups[target, default: []].append(message)
        return true
    }

    /// Drain a child's buffered follow-ups into round-boundary items: the
    /// same `formatInterjection` wrap the root drain applies, because
    /// upstream routes a running recipient's agent message through the same
    /// `pending_interjections` machinery as a user interjection
    /// (run_loop.rs:2006-2020 → interjection.rs:290-338).
    private func takeChildFollowups(_ childID: String) -> [ConversationItem] {
        guard let pending = pendingChildFollowups.removeValue(forKey: childID),
              !pending.isEmpty
        else { return [] }
        return pending.map { .interjection(formatInterjection(agentMessageEnvelope($0))) }
    }

    // MARK: - Tool spec (advertised as `spawn_subagent`)

    /// The production name upstream's grok-build preset renames `task` to
    /// (`xai-grok-agent/src/config.rs:152-156`), with `run_in_background`
    /// renamed to `background`. The canonical `task` spelling stays accepted
    /// at dispatch, the inverse of how the background-task family advertises
    /// canonical names and accepts the production ones.
    nonisolated static let advertisedToolName = "spawn_subagent"
    nonisolated static let dispatchNames: Set<String> = ["spawn_subagent", "task"]

    /// The production tool names substituted into `${{ tools.by_kind.* }}`
    /// placeholders. Shared with the agents modal's prompt-extension
    /// preview (`LiveAgentsComposition`) so the modal renders the SAME
    /// names the live `spawn_subagent` descriptors carry — one naming, no
    /// drift.
    nonisolated static let fragmentToolNaming = SubagentToolNaming(
        execute: "run_terminal_cmd",
        read: "read_file",
        edit: "search_replace",
        list: "list_dir",
        search: "grep",
        webSearch: "web_search",
        plan: "todo_write"
    )

    private static func makeToolSpec(context: Context) -> ToolSpec {
        let fragmentNaming = Self.fragmentToolNaming
        // Upstream lists built-ins first in catalog order, then discovered
        // entries (`discovery.rs` `merge_subagents`); `availableAgentNames`
        // is alphabetical, so the built-in order is restored by hand.
        let names = availableAgentNames(context: context.definitionContext)
        let builtinOrder = AgentDefinition.subagentNames
        let ordered = names.sorted { lhs, rhs in
            switch (builtinOrder.firstIndex(of: lhs), builtinOrder.firstIndex(of: rhs)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs < rhs
            }
        }
        let descriptors = ordered.map { name -> SubagentDescriptor in
            let definition = discoverAgentDefinition(subagentType: name, context: context.definitionContext)
            // Only a true built-in carries the tool-access fragment; a
            // shadowing project definition's raw description stands alone
            // (builder.rs `build_task_description`).
            let tools = definition?.scope == .builtIn
                ? builtinSubagentByName(name)?.renderTools(fragmentNaming)
                : nil
            return SubagentDescriptor(
                name: name,
                description: definition?.description ?? name,
                tools: tools
            )
        }
        var description = buildTaskDescription(
            subagents: descriptors,
            naming: TaskToolNaming(
                taskTool: advertisedToolName,
                subagentTypeParam: "subagent_type",
                runInBackgroundParam: "background",
                resumeFromParam: "resume_from",
                // The name this session actually advertises for retrieval —
                // the port's background-task family keeps the canonical
                // registry names (recorded divergence from the production
                // rename table).
                backgroundRetrievalTool: LiveBackgroundTaskTools.getTaskOutputName,
                isolationParam: "isolation"
            )
        )
        description += modelGuidance(
            slugs: context.modelSlugs,
            antigravitySelectable: context.antigravitySelectable
        )
        return ToolSpec(
            name: advertisedToolName,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The full task prompt for the subagent to execute."),
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Short description of the task (3-5 words)."),
                    ]),
                    "subagent_type": .object([
                        "type": .string("string"),
                        "description": .string("Name of the subagent type to launch. Built-in types: \"general-purpose\", \"explore\", \"plan\". Additional user-defined types may also be available."),
                    ]),
                    "background": .object([
                        "type": .string("boolean"),
                        "description": .string("Returns immediately with a subagent_id. Use the task output tool to retrieve results. This is set to true by default."),
                    ]),
                    "capability_mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("read-only"), .string("read-write"), .string("execute"), .string("all")]),
                        "description": .string("Capability mode: \"read-only\", \"read-write\", \"execute\", or \"all\". Controls which tool classes the child can use. Default is determined by the role."),
                    ]),
                    "isolation": .object([
                        "type": .string("string"),
                        "enum": .array([.string("none"), .string("worktree")]),
                        "description": .string("Isolation mode: \"none\" (default, shared workspace) or \"worktree\" (isolated git worktree). Worktree mode prevents the child's edits from affecting the parent workspace until explicitly merged."),
                    ]),
                    "resume_from": .object([
                        "type": .string("string"),
                        "description": .string("Resume from a previously completed subagent's conversation. Pass the subagent_id returned by a prior task call. The new subagent continues the previous one's raw transcript with the new task prompt appended. The source must be completed (not running), belong to the current session, and use the same subagent_type."),
                    ]),
                    "cwd": .object([
                        "type": .string("string"),
                        "description": .string("Explicit working directory for the subagent. The path must exist and be a directory. Mutually exclusive with isolation=\"worktree\". Ignored when resume_from is set (the resumed child inherits its source's cwd/worktree)."),
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Optional model slug for this agent. If provided, it must resolve to one of the available model slugs, and its provider must have usable credentials. If omitted, the subagent uses the same model as the parent agent."),
                    ]),
                    "reasoning_effort": .object([
                        "type": .string("string"),
                        "description": .string("Optional reasoning effort for this agent. May also be supplied with resume_from to select the resumed continuation's effort."),
                    ]),
                ]),
                "required": .array([.string("prompt"), .string("description")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// `task_model_guidance` (builder.rs:1362-1383) with the `model` param
    /// name resolved — upstream renders `${{ params.task.model }}` at
    /// finalize time; this composition builds descriptions directly.
    /// Antigravity models are named, not enumerated.
    ///
    /// `spawn` accepts any `antigravity:<model>` slug and validates it against
    /// the live `agy models` roster, but the roster costs a subprocess with a
    /// 15s timeout and this description is built during session construction.
    /// Enumerating here would put that probe on every startup. The cost of
    /// naming the form instead: the model can propose an `antigravity:` slug
    /// that does not exist and learns so from the spawn refusal
    /// (`LiveAntigravityRefusal.unknownModel`, which lists the real roster)
    /// rather than from this description. Saying nothing was worse — the
    /// "MUST use only model slugs from this list" sentence made the accepted
    /// slugs unreachable through the ordinary model-driven path, so the
    /// feature existed and nothing could ask for it.
    private static let antigravityModelGuidance =
        "\n\nAntigravity subagents are enabled: you may also pass `model` as "
        + "`antigravity:<model>` (for example `antigravity:gemini-3-pro`) to run "
        + "the child through the Antigravity CLI instead of an in-process model. "
        + "These slugs are not in the list above; an unavailable one is refused "
        + "with the installed roster."

    private static func modelGuidance(slugs: [String], antigravitySelectable: Bool) -> String {
        let antigravity = antigravitySelectable ? antigravityModelGuidance : ""
        let sorted = Array(Set(slugs)).sorted()
        guard !sorted.isEmpty else {
            return "\n\nNo explicit model slugs are currently available. Omit `model` to inherit the parent model."
                + antigravity
        }
        let list = sorted.map { "- \($0)" }.joined(separator: "\n")
        return "\n\nYou may choose a different model or provider for a subagent when it materially fits the delegated task better (for example, speed, cost, depth, or provider capabilities). You MUST use only model slugs from this list:\n"
            + list
            + "\n\nOmit `model` to inherit the parent model when no listed model is a better fit."
            + antigravity
    }

    // MARK: - Spawn (the `task` tool path)

    /// The map one spawn resolves personas against: the trusted project
    /// overlay from `{parent_cwd}/.opengrok/personas/*.toml` merged over the
    /// session's trust-independent base. Recomputed per spawn, exactly as
    /// upstream recomputes `effective_definition_maps` in every spawn
    /// context (subagent_coordinator.rs:459-474) — one directory scan, no
    /// cache to go stale. The trust bit is the session's folder-trust
    /// verdict (the same one that gated the config document); upstream
    /// re-reads the trust store per spawn, but this port has no mid-session
    /// trust transition surface, so the session verdict is the whole truth.
    func effectiveSpawnPersonas() -> [String: SubagentPersona] {
        SubagentPersonaLoader.effectivePersonas(
            base: context.basePersonas,
            cwd: context.workingDirectory,
            projectTrusted: context.securityContext.projectTrusted
        )
    }

    /// Execute one `spawn_subagent` call. Validation order and error copy
    /// follow `TaskTool::run`: sanitize, cwd check, eager type validation,
    /// model check, then background fire-and-forget or a foreground await.
    ///
    /// `persona` is the port of `SubagentRequest.runtime_overrides.persona`
    /// (task/types.rs:331-332): an internal-spawner channel. The model-facing
    /// task input has NO persona parameter at the pin — `TaskTool::run`
    /// hardcodes `persona: None` (task/mod.rs:394) — so tool dispatch always
    /// leaves this nil and the schema advertises nothing. Do not "fix" that
    /// by adding a persona property to the tool schema; upstream lacks it.
    func spawn(
        args: JSONValue,
        toolCallID: String,
        persona requestedPersona: String? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        guard case .object(var object) = args else {
            return .failure(.invalidCall("\(Self.advertisedToolName) requires an object argument"))
        }
        // The production rename is client-facing only; map it back before the
        // canonical decoder runs (`with_param_rename`, registry/types.rs:166).
        if object["run_in_background"] == nil, let background = object["background"] {
            object["run_in_background"] = background
        }
        let input: TaskToolInput
        do {
            input = try JSONDecoder().decode(TaskToolInput.self, from: JSONEncoder().encode(object))
        } catch {
            return .failure(.invalidCall("\(Self.advertisedToolName) arguments are invalid: \(error)"))
        }

        // cwd: sanitize; validate it names a real directory only for a fresh
        // spawn. On resume the schema ignores caller cwd — source
        // cwd/worktree wins (`select_override_cwd`, subagent/mod.rs:1623-1632).
        // Final child CWD is chosen after resume bookkeeping loads so a
        // resumed child cannot inherit the parent path by accident.
        let sanitizedCwd = sanitizeOptionalArg(input.cwd)
        let resumeID = sanitizeOptionalArg(input.resumeFrom)
        let requestCWD: URL?
        if resumeID == nil, let sanitizedCwd {
            let path = (sanitizedCwd as NSString).isAbsolutePath
                ? sanitizedCwd
                : context.workingDirectory.appendingPathComponent(sanitizedCwd).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .failure(.invalidCall("cwd \"\(sanitizedCwd)\" does not exist"))
            }
            guard isDirectory.boolValue else {
                return .failure(.invalidCall("cwd \"\(sanitizedCwd)\" exists but is not a directory"))
            }
            requestCWD = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            requestCWD = nil
        }

        // Eager type validation, before any background spawn can escape with
        // a bad roster entry (task/mod.rs step 2).
        let definition: AgentDefinition
        do {
            definition = try resolveAgentDefinition(
                subagentType: input.subagentType,
                context: context.definitionContext
            )
        } catch let error as ResolutionError {
            return .failure(.invalidCall(Self.validationMessage(error)))
        } catch {
            return .failure(.invalidCall("Cannot validate subagent '\(input.subagentType)'"))
        }

        // Explicit model slugs must resolve against the public catalog
        // (task/mod.rs step 2b); the error vocabulary is the resolution
        // module's own (`ResolutionError.modelUnavailable`). Antigravity
        // slugs bypass the catalog — spawn validation below is authoritative
        // (antigravity.rs:333-337; antigravity_runner.rs:100-127).
        let requestedModelSlug = sanitizeOptionalArg(input.model)
        let requestedAntigravityModel = requestedModelSlug
            .flatMap(LiveAntigravityComposition.stripModelPrefix)
        if resumeID == nil,
           let requestedModel = requestedModelSlug,
           requestedAntigravityModel == nil,
           !context.modelSlugs.contains(requestedModel) {
            return .failure(.invalidCall("subagent model \"\(requestedModel)\" is unavailable"))
        }

        let requestedCapability = input.capabilityMode.map { mode -> OpenGrokSubagentResolution.SubagentCapabilityMode in
            switch mode {
            case .readOnly: return .readOnly
            case .readWrite: return .readWrite
            case .execute: return .execute
            case .all: return .all
            }
        }
        // A resume inherits the source's persona BEFORE resolution — the
        // source's value wins over the caller's, including a nil that
        // clears it (handle_request.rs:255-258 assigns unconditionally).
        // The caller's explicit ask is still validated against the source
        // in the resume arm below, so a mismatch errors rather than being
        // silently replaced.
        let sourcePersona = resumeID.flatMap { bookkeeping[$0]?.persona }
        let effectivePersona = resumeID != nil ? sourcePersona : requestedPersona
        var runtime = resolveRuntimeConfig(
            subagentType: input.subagentType,
            overrides: SubagentRuntimeOverrides(
                model: sanitizeOptionalArg(input.model),
                persona: effectivePersona,
                reasoningEffort: sanitizeOptionalArg(input.reasoningEffort),
                capabilityMode: requestedCapability,
                isolation: input.isolation,
                allowNestedSubagents: false
            ),
            roles: [:],
            // The per-spawn map: project overlay over the session base. The
            // `cwd:` below is the PARENT session's cwd because that is what
            // relative persona `instructions_file` references resolve
            // against upstream (handle_request.rs:296-301 passes
            // `parent_session_info.cwd`), not the task's own `cwd` argument.
            personas: effectiveSpawnPersonas(),
            cwd: context.workingDirectory,
            definition: definition,
            parent: ParentRuntimeDefaults(
                model: context.parentModel,
                capabilityMode: context.parentCapabilityCeiling
            )
        )
        // ANY persona error aborts the spawn — not just the fatal file-I/O
        // arm. Upstream's shell returns a failure whenever `persona_error`
        // is set (handle_request.rs:308-315: "Persona resolution failed,
        // aborting subagent spawn"); the resolution crate's `fatal` flag
        // only governs whether the OTHER runtime fields still resolved.
        // Checking only `fatal` here would let a named-but-missing persona
        // spawn silently without its instructions — the §3 arm this slice
        // exists to close.
        if let personaError = runtime.personaError {
            return .failure(.invalidCall(personaError))
        }
        // `run_shell_child` intersects once more with the definition's own
        // ceiling after resolution (handle_request.rs:540-543).
        runtime.capabilityMode = intersectCapabilityModes(
            requested: runtime.capabilityMode,
            ceiling: definition.capabilityMode.map { mode -> OpenGrokSubagentResolution.SubagentCapabilityMode in
                switch mode {
                case .readOnly: return .readOnly
                case .readWrite: return .readWrite
                case .execute: return .execute
                case .all: return .all
                }
            }
        )

        // Resume: the source must be a completed child of this session with a
        // persisted transcript; identity validation is the resolution
        // module's own (`validate_resume_identity`). Load bookkeeping BEFORE
        // final child-CWD selection so resume inherits the source path
        // (handle_request.rs:327-351 → select_override_cwd at :737).
        var resumeItems: [ConversationItem]? = nil
        var resumeSource: Bookkeeping? = nil
        if let resumeID {
            let activeIDs = await coordinator.listActive(parentSessionID: context.sessionID)
                .map { $0.request.id }
            if activeIDs.contains(resumeID) {
                return .failure(.invalidCall(
                    "Cannot resume from subagent '\(resumeID)': it is still running. Wait for it to complete before resuming."
                ))
            }
            guard let source = bookkeeping[resumeID] else {
                return .failure(.invalidCall(Self.resumeNotFoundMessage(resumeID)))
            }
            resumeSource = source
            do {
                // The caller's explicit persona (internal channel; nil from
                // tool dispatch) is checked against the source's recorded
                // one — a resume must not silently swap SOULs
                // (`validate_resume_identity`, resolution resume.rs:48+).
                // `childCWD` here is the SOURCE identity, not the (not yet
                // selected) resumed child's path.
                try validateResumeIdentity(
                    requestedType: input.subagentType,
                    requestedPersona: requestedPersona,
                    source: ResumeSourceData(
                        subagentID: resumeID,
                        subagentType: source.subagentType,
                        persona: source.persona,
                        modelID: source.model,
                        childCWD: source.childCWD?.path ?? "",
                        worktreePath: source.worktreePath,
                        childSessionID: resumeID,
                        antigravityConversationID: source.antigravityConversationID
                    )
                )
            } catch {
                return .failure(.invalidCall(String(describing: error)))
            }
            if LiveAntigravityComposition.stripModelPrefix(source.model) != nil {
                guard source.antigravityConversationID != nil else {
                    return .failure(.invalidCall(
                        LiveAntigravityRefusal.cannotResume(subagentID: resumeID)
                    ))
                }
            } else {
                guard let record = try? await context.conversationStore.loadIfPresent(sessionID: resumeID) else {
                    return .failure(.invalidCall(Self.resumeNotFoundMessage(resumeID)))
                }
                resumeItems = record.items
            }
            // A resumed child pins the source's model; an explicit override is
            // ignored, mirroring `run_shell_child`'s resume arm.
            runtime.model = source.model
        }

        // Final child CWD: reusable worktree > resume-inherited/request cwd >
        // parent (`resolve_child_cwd` / `select_override_cwd`,
        // subagent/mod.rs:1590-1632). Caller cwd was already dropped above
        // when `resume_from` is set. Recorded worktree *presence* is threaded
        // separately from the reusable URL so a missing worktree falls
        // through to Shared/parent instead of stale `childCWD`
        // (`resume_inherited_cwd` checks `worktree_path.is_some()`,
        // subagent/mod.rs:1621).
        let resumedWorktree = Self.resumeWorktreePath(resumeSource?.worktreePath)
        let overrideCWD: URL? = resumeID != nil
            ? Self.resumeInheritedCWD(
                sourceCWD: resumeSource?.childCWD,
                recordedWorktreePath: resumeSource?.worktreePath
            )
            : requestCWD
        let childCWD = Self.resolveChildCWD(
            worktreePath: resumedWorktree,
            overrideCWD: overrideCWD,
            parentCWD: context.workingDirectory
        )

        let childModel = runtime.model ?? context.parentModel
        let antigravityModel = LiveAntigravityComposition.stripModelPrefix(childModel)
        var antigravityRoster: [String] = []
        // Upstream assigns `Uuid::now_v7()`. The port has no v7 helper; a v4
        // UUID costs the time-ordered id sort (cosmetic only — completion
        // order is tracked separately), noted in the slice report.
        let childID = sanitizeOptionalArg(input.taskId) ?? UUID().uuidString.lowercased()
        // `task_id` is decoder-supported but not advertised in the schema, so
        // nothing upstream of here constrains it. The Antigravity runner joins
        // it into `$OPENGROK_HOME/sessions/<session>/subagents/<childID>` and
        // hands that to `createDirectory` and `agy --log-file`, so a value like
        // `../../outside` writes outside the session tree. Rejected rather than
        // sanitized: silently rewriting the id would hand the caller a child it
        // cannot address by the name it asked for.
        guard isSafeSubagentChildID(childID) else {
            return .failure(.invalidCall("subagent task_id \"\(childID)\" is not a valid identifier"))
        }

        // Antigravity gates, eager and in this order
        // (antigravity_runner.rs:100-127), before coordinator.spawn so a
        // background spawn cannot escape with a refusal.
        if let antigravityModel {
            let config = context.antigravityServices.loadConfig(context.environment)
            guard config.enabled else {
                return .failure(.invalidCall(LiveAntigravityRefusal.featureDisabled))
            }
            guard context.antigravityServices.isCLIInstalled(
                config.binary,
                context.environment
            ) else {
                return .failure(.invalidCall(
                    LiveAntigravityRefusal.cliNotInstalled(binary: config.binary)
                ))
            }
            let status = await context.antigravityServices.probeModels(config.binary)
            guard status.signedIn else {
                return .failure(.invalidCall(
                    LiveAntigravityRefusal.notSignedIn(
                        binary: config.binary,
                        detail: status.detail ?? "sign-in required"
                    )
                ))
            }
            if !status.models.isEmpty, !status.models.contains(antigravityModel) {
                return .failure(.invalidCall(
                    LiveAntigravityRefusal.unknownModel(
                        antigravityModel,
                        available: status.prefixedModels
                    )
                ))
            }
            antigravityRoster = status.models
            if let issue = antigravityModelAvailabilityIssue(
                model: antigravityModel,
                roster: status.models
            ) {
                return .failure(.invalidCall(
                    antigravityUnavailableModelMessage(model: antigravityModel, issue: issue)
                ))
            }
        }

        // The child's tool policy: the resolved definition after the nested
        // spawn/plan strip and the capability filter, so the child can never
        // hold a surface the policy removed — and it never sees a subagent
        // host, so `spawn_subagent` is absent from its list twice over.
        var strippedDefinition = definition
        applyChildToolPolicy(
            definition: &strippedDefinition,
            capabilityMode: runtime.capabilityMode,
            allowNestedSubagents: false
        )
        strippedDefinition.capabilityMode = runtime.capabilityMode.map { mode in
            switch mode {
            case .readOnly: return AgentCapabilityMode.readOnly
            case .readWrite: return AgentCapabilityMode.readWrite
            case .execute: return AgentCapabilityMode.execute
            case .all: return AgentCapabilityMode.all
            }
        }
        // Frozen for the @Sendable child closure: a captured `var` is a
        // concurrency error, and these never change after this point.
        let childDefinition = strippedDefinition
        let childRuntime = runtime
        let inheritedItems = resumeItems
        let childAntigravityRoster = antigravityRoster
        let inheritedAntigravityConversationID = resumeSource?.antigravityConversationID

        bookkeeping[childID] = Bookkeeping(
            startedAt: Date(),
            subagentType: input.subagentType,
            description: input.description,
            model: childModel,
            persona: runtime.persona,
            childCWD: childCWD,
            worktreePath: resumedWorktree,
            liveItems: antigravityModel == nil ? [] : [
                .user(input.prompt),
                .assistant(AssistantItem(content: "Antigravity: Starting")),
            ],
            antigravityConversationID: inheritedAntigravityConversationID,
            antigravityPhase: antigravityModel == nil ? nil : "Starting"
        )
        let request = OpenGrokChildRequest(
            id: childID,
            parentSessionID: context.sessionID,
            parentPromptID: LiveSubagentParentPromptContext.promptID,
            subagentType: input.subagentType,
            description: input.description,
            childCWD: childCWD.path,
            worktreePath: resumedWorktree?.path,
            owner: antigravityModel == nil ? .task : .antigravity,
            runInBackground: input.runInBackground,
            capabilityMode: runtime.capabilityMode?.rawValue,
            reasoningEffort: runtime.reasoningEffort,
            resumeFrom: resumeID,
            surfaceCompletion: true
        )
        do {
            try await coordinator.spawn(request) { [weak self] in
                guard let self else {
                    return OpenGrokChildResult(
                        id: childID,
                        success: false,
                        error: "subagent host was torn down before the child ran"
                    )
                }
                // Operation body runs only after coordinator registration.
                // Upsert/remove bracket the child so background, foreground,
                // antigravity, and resume share one counting seam.
                return await self.withActiveBackgroundWorkCounting(for: request) {
                    if let antigravityModel {
                        return await self.runAntigravityChild(
                            childID: childID,
                            prompt: input.prompt,
                            model: antigravityModel,
                            runtime: childRuntime,
                            cwd: childCWD,
                            modelRoster: childAntigravityRoster,
                            conversationID: inheritedAntigravityConversationID
                        )
                    }
                    return await self.runChild(
                        childID: childID,
                        prompt: input.prompt,
                        definition: childDefinition,
                        runtime: childRuntime,
                        model: childModel,
                        cwd: childCWD,
                        resumeItems: inheritedItems
                    )
                }
            }
        } catch let error as OpenGrokCoordinatorError {
            bookkeeping.removeValue(forKey: childID)
            // Spawn never reached the operation body — remove is a no-op
            // unless a future path upserts before this catch.
            await emitActiveBackgroundWorkRemove(id: childID)
            return .failure(.failed(error.description))
        } catch {
            bookkeeping.removeValue(forKey: childID)
            await emitActiveBackgroundWorkRemove(id: childID)
            return .failure(.failed("subagent \(childID) could not be registered: \(error)"))
        }

        if input.runInBackground {
            let text = formatSubagentStartedBackground(
                subagentId: childID,
                subagentType: input.subagentType,
                description: input.description,
                taskOutputToolName: LiveBackgroundTaskTools.getTaskOutputName
            )
            return .success(OpenGrokShellToolCallResult(
                value: .object([
                    "subagent_id": .string(childID),
                    "subagent_type": .string(input.subagentType),
                    "description": .string(input.description),
                    "status": .string("background"),
                ]),
                promptText: text
            ))
        }

        // Foreground: await the child, forwarding a turn cancellation to the
        // coordinator so the child dies with the turn (upstream's
        // `cancellation_forwarder`, task/mod.rs:370-379). The foreground
        // await budget that auto-backgrounds a slow child upstream is not
        // wired here — a foreground spawn waits until completion or cancel.
        let result: OpenGrokChildResult
        do {
            result = try await withTaskCancellationHandler {
                try await coordinator.awaitResult(childID)
            } onCancel: { [coordinator] in
                Task { await coordinator.cancel(.childID(childID)) }
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed("subagent \(childID) did not produce a result: \(error)"))
        }

        if result.success {
            let stats = bookkeeping[childID]
            let output = SubagentCompletedOutput(
                output: result.output,
                subagentId: childID,
                subagentType: input.subagentType,
                toolCalls: stats?.terminalToolCalls ?? 0,
                turns: stats?.terminalTurns ?? 0,
                durationMs: result.durationMS
            )
            let encoded = (try? JSONEncoder().encode(output)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
            return .success(OpenGrokShellToolCallResult(
                value: encoded,
                promptText: output.toModelText()
            ))
        }
        if result.cancelled {
            return .failure(.cancelled)
        }
        // Upstream surfaces partial work and the resume hint on a terminal
        // failure (task/mod.rs step 6 else-arm).
        var message = result.error ?? "Unknown subagent error"
        let partial = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty {
            let truncated = partial.count > 4_000
            message += "\n\nPartial output before the failure\(truncated ? " (truncated)" : ""):\n"
                + String(partial.prefix(4_000))
        }
        let stats = bookkeeping[childID]
        message += "\n\nThe subagent's session was preserved (\(stats?.terminalToolCalls ?? 0) tool calls, \(stats?.terminalTurns ?? 0) turns). To retry or continue it, call this tool again with resume_from: \"\(childID)\"."
        return .failure(.invalidCall(message))
    }

    static func validationMessage(_ error: ResolutionError) -> String {
        switch error {
        case .unknown(let subagentType, let available):
            let suffix = available.isEmpty ? "" : ". Available types: \(available.joined(separator: ", "))"
            return "Unknown subagent type: \(subagentType)\(suffix)"
        case .disabled(let subagentType):
            return "Subagent '\(subagentType)' is disabled via [subagents.toggle] in config.toml"
        case .notAllowed(let subagentType, let allowed):
            return "agent can only spawn: \(allowed.joined(separator: ", ")); '\(subagentType)' not allowed"
        default:
            return error.description
        }
    }

    static func resumeNotFoundMessage(_ resumeID: String) -> String {
        "Cannot resume from subagent '\(resumeID)': not found. The subagent may have been evicted or the ID is invalid."
    }

    /// Precedence: worktree path > non-empty override > parent cwd
    /// (`resolve_child_cwd`, subagent/mod.rs:1590-1599).
    static func resolveChildCWD(
        worktreePath: URL?,
        overrideCWD: URL?,
        parentCWD: URL
    ) -> URL {
        if let worktreePath {
            return worktreePath.standardizedFileURL
        }
        if let overrideCWD {
            return overrideCWD.standardizedFileURL
        }
        return parentCWD.standardizedFileURL
    }

    /// Reuse a recorded worktree when it still exists on disk. Missing paths
    /// yield `nil` here (no reusable URL) but do **not** clear recorded
    /// presence — callers must still pass the original `worktreePath` into
    /// `resumeInheritedCWD` so Shared/parent wins over stale `childCWD`
    /// (`ResumeWorktreeAction::Shared` — this host has no snapshot rehydrate).
    static func resumeWorktreePath(_ recorded: URL?) -> URL? {
        guard let recorded else { return nil }
        let path = recorded.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return recorded.standardizedFileURL
    }

    /// The cwd a resumed child inherits from its source, or `nil` so
    /// `resolveChildCWD` falls back to the parent workspace
    /// (`resume_inherited_cwd`, subagent/mod.rs:1619-1632).
    ///
    /// `recordedWorktreePath` is the bookkeeping value's *presence*
    /// (`worktree_path.is_some()`), not the existence-filtered reusable URL.
    /// A worktree-backed source never inherits `childCWD` here — reuse goes
    /// through `resumeWorktreePath`, and a missing worktree is Shared/parent.
    /// A missing source directory is the explicit safe fallback to parent.
    static func resumeInheritedCWD(
        sourceCWD: URL?,
        recordedWorktreePath: URL?
    ) -> URL? {
        if recordedWorktreePath != nil { return nil }
        guard let sourceCWD else { return nil }
        let path = sourceCWD.standardizedFileURL.path
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return sourceCWD.standardizedFileURL
    }

    // MARK: - Child runner

    /// One child session end to end: build the clamped tool surface, run the
    /// turn loop against the parent's sampler, persist the transcript, and
    /// report to the coordinator. Modelled on `LiveWorkflowChildAgent.run`;
    /// the differences are the definition-rendered system prompt, the
    /// session persistence (a workflow child's durable record is the journal;
    /// a task child's is its resumable transcript), and the stop-hook event.
    func runChild(
        childID: String,
        prompt: String,
        definition: AgentDefinition,
        runtime: EffectiveRuntimeConfig,
        model: String,
        cwd: URL,
        resumeItems: [ConversationItem]?
    ) async -> OpenGrokChildResult {
        let startedAt = Date()
        let samplingRoute: ChildSamplerRoute
        do {
            samplingRoute = try await resolveChildSamplerRoute(model: model)
        } catch {
            return OpenGrokChildResult(
                id: childID,
                success: false,
                error: "child agent sampling route unavailable: \(error)",
                durationMS: Self.milliseconds(since: startedAt)
            )
        }
        // Live-loop registration brackets the whole run: a follow-up that
        // arrives after the final drain but before this defer runs is
        // accepted and never seen — the same window upstream has, where
        // `deliver_followup`'s channel send can succeed against a child that
        // is already terminating.
        liveChildLoopIDs.insert(childID)
        defer {
            liveChildLoopIDs.remove(childID)
            pendingChildFollowups.removeValue(forKey: childID)
        }
        let executor: LiveToolExecutor
        do {
            executor = try await LiveToolExecutor(
                processBackend: context.processBackend,
                sessionID: childID,
                workingDirectory: cwd,
                toolPolicy: LiveAgentToolPolicy(definition: definition),
                telemetryBootstrapContext: context.telemetryBootstrapContext,
                fileAccessPolicy: context.fileAccessPolicy,
                environment: context.environment,
                imageToolContext: context.imageToolContext,
                webToolContext: context.webToolContext,
                sandboxDecision: context.sandboxDecision,
                securityContext: context.securityContext,
                // Children get no rewind/memory surface in this slice; the
                // capability lists keep their names harmlessly (nothing
                // advertised matches them).
                sessionServices: nil,
                permissionOptions: context.permissionOptions,
                inheritedPermissionHandle: parentPermissionHandle,
                // The team mailbox, with the child's own identity. Upstream
                // children always carry the quartet: the builder pushes the
                // collaboration tools past the definition's tool list
                // (builder.rs:871-877), every capability mode allows the
                // kind, and the nested strip keeps them
                // (strip_nested_spawn_tools, task/types.rs:442-452).
                agentCollaboration: LiveAgentCollaboration(
                    coordinator: coordinator,
                    identity: AgentMailboxIdentity(
                        teamScopeID: context.sessionID,
                        agentID: childID
                    )
                )
            )
        } catch {
            return OpenGrokChildResult(
                id: childID,
                success: false,
                error: "child agent tool surface unavailable: \(error)",
                durationMS: Self.milliseconds(since: startedAt)
            )
        }
        childExecutors[childID] = executor

        var items = resumeItems ?? []
        if resumeItems == nil {
            if let systemPrompt = renderSubagentSystemPrompt(
                definition: definition,
                runtime: runtime,
                workingDirectory: cwd
            ) {
                items.append(.system(systemPrompt))
            }
            // "Subagents receive a compacted version of project instructions"
            // (the tool description's own promise): the AGENTS.md chain rides
            // as the first user message, as
            // `renderSubagentInitialUserMessage` renders it.
            if let agentsBody = renderSubagentInitialUserMessage(
                definition: definition,
                workingDirectory: cwd
            ) {
                items.append(.user(agentsBody))
            }
        }
        items.append(.user(prompt))
        bookkeeping[childID]?.liveItems = items

        let childProvider = samplingRoute.provider
        if !childProvider.profile.allowsXaiServices {
            context.parentExportBoundary?.observe(childProvider)
            try? await context.providerBoundarySync?(true)
        }

        var record = LiveConversationRecord.new(sessionID: childID, workingDirectory: cwd)
        record.parentSessionID = context.sessionID
        record.sessionKind = "subagent"
        record.cacheAffinityID = context.parentCacheAffinityID ?? context.sessionID
        record.currentProvider = childProvider
        record.currentModelID = model
        if !childProvider.profile.allowsXaiServices {
            record.everUsedNonXAI = true
        }
        let history = LiveConversationHistory(record: record, store: context.conversationStore)
        let logicalTurnID = "\(childID)-\(bookkeeping[childID]?.turns ?? 0)"
        let activeChildren = await coordinator.listActive(parentSessionID: context.sessionID)
        let parentPromptID = activeChildren.first { $0.request.id == childID }?.request.parentPromptID
            ?? LiveSubagentParentPromptContext.promptID
        await history.beginUsagePrompt(logicalTurnID)

        var stopHookContinuations = 0
        var stopHookActive = false
        var finalOutput = ""
        var terminalError: String? = nil
        var cancelled = false

        while true {
            do {
                try Task.checkCancellation()
            } catch {
                cancelled = true
                terminalError = "Subagent was cancelled"
                break
            }
            // Follow-ups land at the top of every sampler round — the child
            // loop's "safe model boundary" (the root loop's identical drain
            // point sits at LiveShellSamplingDriver.runTurn's round top).
            items.append(contentsOf: takeChildFollowups(childID))
            bookkeeping[childID]?.liveItems = items
            // Child sampling effort (Rust handle_request.rs:705-714): parse
            // the resolved runtime token when present. A non-nil but unknown
            // token is treated as no override so the parent sampler default
            // still applies — fail-open on the string, not fail-closed.
            let childEffort = runtime.reasoningEffort.flatMap(parseCanonicalEffortToken)
            let childCodexPermissions: CodexPermissions?
            if samplingRoute.provider == .codex, parentPermissionHandle != nil {
                childCodexPermissions = await executor.currentCodexPermissions(
                    provider: samplingRoute.provider
                )
            } else {
                childCodexPermissions = samplingRoute.codexPermissions
            }
            let response: OpenGrokLiveSamplingResponse
            do {
                response = try await samplingRoute.sampler.sample(OpenGrokLiveSamplingRequest(
                    sessionID: childID,
                    cacheAffinityID: context.parentCacheAffinityID ?? context.sessionID,
                    turnID: "\(childID)-\(bookkeeping[childID]?.turns ?? 0)",
                    logicalTurnID: logicalTurnID,
                    model: model,
                    prompt: prompt,
                    items: items,
                    tools: executor.tools,
                    reasoningEffort: childEffort,
                    codexPermissions: childCodexPermissions
                )) { _ in
                    // A child's tokens stream to no pane; the parent reads the
                    // finished result, same as a workflow child.
                }
            } catch is CancellationError {
                cancelled = true
                terminalError = "Subagent was cancelled"
                break
            } catch {
                terminalError = "\(error)"
                break
            }
            items.append(contentsOf: response.items)
            bookkeeping[childID]?.liveItems = items
            do {
                try await history.recordMainUsage(
                    modelID: model,
                    usage: response.usage,
                    costUsdTicks: response.costUsdTicks
                )
            } catch {
                let markedIncomplete = await history.markUsageIncomplete(
                    prompt: true,
                    session: true
                )
                terminalError = markedIncomplete
                    ? "child agent usage could not be recorded: \(error)"
                    : "child agent usage could not be recorded or marked incomplete: \(error)"
                break
            }

            guard !response.toolCalls.isEmpty else {
                if stopHookContinuations < 8 {
                    let stopResult = await executor.runStop(
                        event: .subagentStop,
                        promptID: childID,
                        payload: [
                            "phase": .string("gate"),
                            "subagentId": .string(childID),
                            "subagentType": .string(bookkeeping[childID]?.subagentType ?? ""),
                            "reason": .string("end_turn"),
                            "stopHookActive": .boolean(stopHookActive),
                            "lastAssistantMessage": .string(response.output),
                        ]
                    )
                    if stopResult.preventContinuation == nil, stopResult.wantsContinuation {
                        stopHookContinuations += 1
                        stopHookActive = true
                        items.append(.autoContinue(formatLiveStopFeedback(stopResult)))
                        bookkeeping[childID]?.liveItems = items
                        continue
                    }
                }
                finalOutput = response.output
                break
            }
            let round = (bookkeeping[childID]?.turns ?? 0) + 1
            guard round <= context.maxToolRounds else {
                terminalError = "agent \(childID) exceeded \(context.maxToolRounds) tool rounds"
                break
            }
            bookkeeping[childID]?.turns = UInt32(round)
            do {
                let toolItems = try await executeChildCalls(
                    response.toolCalls,
                    childID: childID,
                    cwd: cwd,
                    executor: executor
                )
                items.append(contentsOf: toolItems)
                bookkeeping[childID]?.liveItems = items
            } catch is CancellationError {
                cancelled = true
                terminalError = "Subagent was cancelled"
                break
            } catch {
                terminalError = "\(error)"
                break
            }
        }

        if cancelled {
            let markedIncomplete = await history.markUsageIncomplete(
                prompt: true,
                session: true
            )
            if !markedIncomplete {
                terminalError = "Subagent was cancelled and its usage could not be marked incomplete"
            }
        }
        await history.endUsagePrompt(logicalTurnID)

        let stats = bookkeeping[childID]
        bookkeeping[childID]?.liveItems = items
        bookkeeping[childID]?.terminalToolCalls = stats?.toolCalls
        bookkeeping[childID]?.terminalTurns = stats?.turns
        // The transcript is the resume substrate: only a child whose save
        // landed joins the resume index, so `resume_from` never promises a
        // conversation that is not on disk.
        if await persistChild(history: history, childID: childID, items: items) {
            bookkeeping[childID]?.model = model
        }
        let childUsage = await history.usageSnapshot
        if let parentUsageHistory {
            let byModel = childUsage?.models.map {
                (model: $0.modelID, totals: $0.totals.usageTotals)
            } ?? []
            let applied = await parentUsageHistory.foldSubagentUsage(
                byModel: byModel,
                parentPromptID: parentPromptID,
                incomplete: childUsage?.incomplete ?? true
            )
            if !applied, let parentPromptID {
                await coordinator.markUsageNotApplied(
                    parentSessionID: context.sessionID,
                    promptID: parentPromptID
                )
            }
        } else if let parentPromptID {
            await coordinator.markUsageNotApplied(
                parentSessionID: context.sessionID,
                promptID: parentPromptID
            )
        }
        await executor.shutdown()
        childExecutors.removeValue(forKey: childID)

        return OpenGrokChildResult(
            id: childID,
            success: terminalError == nil,
            output: terminalError == nil ? finalOutput : Self.lastAssistantText(items),
            cancelled: cancelled,
            error: terminalError,
            tokensUsed: childUsage?.totals.totalTokens ?? 0,
            durationMS: Self.milliseconds(since: startedAt)
        )
    }

    private func resolveChildSamplerRoute(model: String) async throws -> ChildSamplerRoute {
        let parentProvider = context.parentProvider
            ?? resolveSubagentModelProvider(context.parentModel)
            ?? .xai

        if model == context.parentModel {
            return ChildSamplerRoute(
                sampler: context.sampler,
                provider: parentProvider,
                codexPermissions: context.parentCodexPermissions
            )
        }

        if let factory = context.childSamplerFactory {
            let resolved = try await factory(model, context.parentCodexPermissions)
            return ChildSamplerRoute(
                sampler: resolved.sampler,
                provider: resolved.provider,
                codexPermissions: resolved.provider == .codex
                    ? resolved.codexPermissions ?? context.parentCodexPermissions
                    : nil
            )
        }

        guard resolveSubagentModelProvider(model) == parentProvider
        else {
            throw CLIApplicationError.failed(
                "subagent model \"\(model)\" requires an isolated provider sampling route"
            )
        }
        return ChildSamplerRoute(
            sampler: context.sampler,
            provider: parentProvider,
            codexPermissions: context.parentCodexPermissions
        )
    }

    /// Parallel, order-preserving tool execution with the workflow child's
    /// failure rule: a failed tool is the model's problem to route around, a
    /// cancelled one ends the child.
    private func executeChildCalls(
        _ calls: [ToolCall],
        childID: String,
        cwd: URL,
        executor: LiveToolExecutor
    ) async throws -> [ConversationItem] {
        var results = [ConversationItem?](repeating: nil, count: calls.count)
        try await withThrowingTaskGroup(of: (Int, ToolResultItem).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { [self] in
                    let outcome = await executor.invoke(
                        sessionID: childID,
                        workingDirectory: cwd,
                        call: call
                    )
                    let content: String
                    switch outcome {
                    case .success(let value):
                        content = value.promptText
                    case .failure(.cancelled):
                        throw CancellationError()
                    case .failure(let error):
                        // A failed tool is the model's problem to route
                        // around: the child sees the failure text and gets
                        // another round.
                        content = "Tool \(call.name) failed: \(error.description)"
                        await self.noteChildToolCall(childID: childID, name: call.name, failed: true)
                        return (index, ToolResultItem(toolCallId: call.callId, content: content))
                    }
                    await self.noteChildToolCall(childID: childID, name: call.name, failed: false)
                    return (index, ToolResultItem(toolCallId: call.callId, content: content))
                }
            }
            for try await (index, result) in group {
                results[index] = .toolResult(result)
            }
        }
        return results.compactMap { $0 }
    }

    private func noteChildToolCall(childID: String, name: String, failed: Bool) {
        bookkeeping[childID]?.toolCalls += 1
        if failed {
            bookkeeping[childID]?.errors += 1
        }
        if bookkeeping[childID]?.toolsUsed.contains(name) == false {
            bookkeeping[childID]?.toolsUsed.append(name)
        }
    }

    private func persistChild(
        history: LiveConversationHistory,
        childID: String,
        items: [ConversationItem]
    ) async -> Bool {
        do {
            try await history.commit(sessionID: childID, items: items)
            return true
        } catch {
            // A lost save means `resume_from` reports not-found later — the
            // honest failure — rather than resuming into a stale transcript.
            return false
        }
    }

    private static func lastAssistantText(_ items: [ConversationItem]) -> String {
        for item in items.reversed() {
            if case .assistant(let assistant) = item, !assistant.content.isEmpty {
                return assistant.content
            }
        }
        return ""
    }

    private static func milliseconds(since start: Date) -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince(start)) * 1_000)
    }

    // MARK: - LiveSubagentQuerying

    func subagentSnapshot(id: String) async -> LiveSubagentSnapshot? {
        let isActive = await coordinator.listActive(parentSessionID: context.sessionID)
            .contains { $0.request.id == id }
        if isActive {
            let meta = bookkeeping[id]
            let started = meta?.startedAt ?? Date()
            return LiveSubagentSnapshot(
                subagentID: id,
                subagentType: meta?.subagentType ?? "unknown",
                description: meta?.description ?? "",
                status: "running",
                output: runningOutput(id: id, meta: meta, startedAt: started),
                startedAt: started,
                durationMS: Self.milliseconds(since: started),
                exitCode: nil,
                turnCount: meta?.turns ?? 0,
                toolCallCount: meta?.toolCalls ?? 0
            )
        }
        guard let completed = await coordinator.listCompleted()
            .first(where: { $0.request.id == id }),
              let result = completed.result else { return nil }
        let meta = bookkeeping[id]
        let started = meta?.startedAt ?? Date()
        let status = completed.state
        let output: String
        switch status {
        case "completed":
            // The upstream Completed arm: output, then `<subagent_meta>`, then
            // the resume footer (task_output/mod.rs:700-720).
            let toolCalls = meta?.terminalToolCalls ?? 0
            let turns = meta?.terminalTurns ?? 0
            output = result.output
                + "\n\n<subagent_meta>id=\(id), type=\(meta?.subagentType ?? "unknown"), tool_calls=\(toolCalls), turns=\(turns), duration_ms=\(result.durationMS)</subagent_meta>"
                + "\n\n" + formatResumeFooter(
                    subagentId: id,
                    subagentType: meta?.subagentType ?? "unknown",
                    persona: nil
                )
        case "failed":
            output = result.error ?? "Unknown subagent error"
        default:
            output = result.error ?? "Subagent was cancelled"
        }
        return LiveSubagentSnapshot(
            subagentID: id,
            subagentType: meta?.subagentType ?? "unknown",
            description: meta?.description ?? "",
            status: status,
            output: output,
            startedAt: started,
            durationMS: result.durationMS,
            exitCode: status == "completed" ? 0 : 1,
            turnCount: meta?.terminalTurns ?? meta?.turns ?? 0,
            toolCallCount: meta?.terminalToolCalls ?? meta?.toolCalls ?? 0
        )
    }

    func subagentConversationItems(id: String) -> [ConversationItem]? {
        bookkeeping[id]?.liveItems
    }

    /// The Running arm of `format_subagent_snapshot`, minus the context-token
    /// fraction this composition does not measure (recorded divergence).
    private func runningOutput(id: String, meta: Bookkeeping?, startedAt: Date) -> String {
        let elapsed = Double(Self.milliseconds(since: startedAt)) / 1_000
        let tools = meta?.toolsUsed.isEmpty == false ? (meta?.toolsUsed.joined(separator: ", ") ?? "") : "none yet"
        var lines = [
            "Subagent is still running.",
            "Type: \(meta?.subagentType ?? "unknown")",
            "Description: \(meta?.description ?? "")",
            "Elapsed: \(String(format: "%.1f", elapsed))s",
            "Progress: turn \(meta?.turns ?? 0), \(meta?.toolCalls ?? 0) tool calls",
        ]
        if let phase = meta?.antigravityPhase {
            lines.append("Phase: \(phase)")
        }
        lines.append("Tools used: \(tools)")
        lines.append("Errors: \(meta?.errors ?? 0)")
        return lines.joined(separator: "\n")
    }

    func awaitSubagent(id: String, timeoutMS: UInt64) async -> LiveSubagentSnapshot? {
        guard let current = await subagentSnapshot(id: id) else { return nil }
        if current.completed { return current }
        do {
            // The awaited result is re-read through `subagentSnapshot` either
            // way — the snapshot is the single rendering path — so the value
            // itself is intentionally unused; the throws are the status.
            _ = try await coordinator.awaitResult(id, timeoutMS: timeoutMS)
        } catch OpenGrokCoordinatorError.childNotFound {
            return nil
        } catch {
            // Timeout: fall through to the still-running snapshot.
        }
        return await subagentSnapshot(id: id)
    }

    func cancelSubagent(id: String) async -> LiveSubagentCancelOutcome {
        let active = await coordinator.listActive(parentSessionID: context.sessionID)
        if active.contains(where: { $0.request.id == id }) {
            let cancelled = await coordinator.cancel(.childID(id))
            return cancelled > 0 ? .cancelled : .notFound
        }
        if let completed = await coordinator.listCompleted().first(where: { $0.request.id == id }) {
            return .alreadyFinished(status: completed.state)
        }
        return .notFound
    }

    func knownSubagentIDs() async -> [String] {
        let active = await coordinator.listActive(parentSessionID: context.sessionID).map { $0.request.id }
        let completed = await coordinator.listCompleted().map { $0.request.id }
        return (active + completed).sorted()
    }

    /// Session teardown: cancel every child of this session and release the
    /// tool surfaces they built (MCP connections, shell sessions).
    func shutdown() async {
        await coordinator.teardown(sessionID: context.sessionID)
        // Chip must clear immediately on host death. Child tasks may still
        // be unwinding; their later removes hit the latch and stay silent.
        let outstanding = countedActiveBackgroundWorkIDs
        for id in outstanding {
            await emitActiveBackgroundWorkRemove(id: id)
        }
        let executors = Array(childExecutors.values)
        childExecutors.removeAll()
        for executor in executors {
            await executor.shutdown()
        }
    }
}
