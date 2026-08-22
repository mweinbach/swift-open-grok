import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokCodeMode
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokDiagnostics
import OpenGrokFileTools
import OpenGrokFastWorktree
import OpenGrokHTTP
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokHunkTracker
import OpenGrokInterjection
import OpenGrokLSP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTokenEstimation
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokSandbox
import OpenGrokScheduler
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokSubagentResolution
import OpenGrokTerminalCore
import OpenGrokTextArea
import OpenGrokToolRegistry
import OpenGrokToolTypes
import OpenGrokToolsAPI
import OpenGrokTTY
import OpenGrokVersion
import OpenGrokVoice
import OpenGrokWebMediaTools
import OpenGrokWorkspace

struct LiveToolExecutor: Sendable {
    let tools: [ToolSpec]
    let workingDirectory: URL
    private let sessionEnvironment: [String: String]
    private let sessionDirectories: LiveSessionDirectoryRegistry
    private let composition: OpenGrokShellToolRuntimeComposition
    private let fileToolBridge: ToolBridge
    private let registryToolNames: Set<String>
    /// The same gate the file tools run through. `run_terminal_cmd` used to
    /// dispatch straight to `composition.invoke`, so shell execution never saw
    /// a deny rule, a PreToolUse hook, or the permission modal.
    private let permissionPipeline: PermissionPipeline?
    /// Mutable permission-mode state the pager toggles at runtime (`Ctrl+O`,
    /// Shift+Tab). Shares the pipeline handle the tool gate consults.
    let sessionPermissionMode: LiveSessionPermissionMode?
    /// The pipeline's live `PermissionHandle` — the state the tool gate
    /// consults on every request. The ACP notification gateway's
    /// `x.ai/permissions/reset` and auto-mode arms mutate THIS handle, never
    /// a mirror, so an inbound reset lands where the next tool call looks.
    /// (`async` because `PermissionPipeline` is an actor in another module,
    /// where even a `let` hop is isolated.)
    func permissionHandle() async -> PermissionHandle? {
        guard let permissionPipeline else { return nil }
        return await permissionPipeline.permissions
    }

    /// The same pipeline tools prepare through. ACP composition proofs need
    /// this actor (not a reconstructed one) after `liveACPServices` installs
    /// the reverse prompter — otherwise the suite can only cover the prompter
    /// in isolation and miss a deleted `setPrompter` line.
    func toolPermissionPipeline() -> PermissionPipeline? {
        permissionPipeline
    }

    /// Provider policy is sampled from the live gate, not the launch flags:
    /// `/auto` and `/yolo` can change between two requests in the same session.
    func currentCodexPermissions(provider: ModelProvider) async -> CodexPermissions? {
        guard provider == .codex else { return nil }
        let handle = await permissionHandle()
        let yoloMode = await handle?.yoloMode ?? false
        let autoMode = await handle?.autoMode ?? false
        let yoloPinned = await handle?.yoloPinReason != nil
        return Self.codexPermissions(
            provider: provider,
            sandbox: sandbox,
            workingDirectory: workingDirectory,
            environment: sessionEnvironment,
            alwaysApprove: yoloMode && !yoloPinned,
            autoReviewEnabled: autoMode
        )
    }

    static func codexPermissions(
        provider: ModelProvider,
        sandbox: LiveSandboxDecision,
        workingDirectory: URL,
        environment: [String: String],
        alwaysApprove: Bool,
        autoReviewEnabled: Bool
    ) -> CodexPermissions? {
        guard provider == .codex else { return nil }
        let activeProfile = sandbox.enforced && OpenGrokSandbox.isSandboxActive()
            ? OpenGrokSandbox.activeProfileName()
            : nil
        let sandboxMode: String
        switch activeProfile {
        case nil:
            sandboxMode = "danger-full-access"
        case "read-only", "readonly":
            sandboxMode = "read-only"
        default:
            sandboxMode = "workspace-write"
        }
        let sandboxName: String
        if activeProfile == nil {
            sandboxName = "none"
        } else {
#if os(macOS)
            sandboxName = "seatbelt"
#elseif os(Linux)
            sandboxName = "landlock"
#elseif os(Windows)
            sandboxName = "windows_sandbox"
#else
            sandboxName = "external"
#endif
        }
        let writableRoots: [String]
        if let activeProfile,
           let profile = try? ProfileName(parsing: activeProfile).resolve(
               workspace: workingDirectory,
               config: loadSandboxConfig(workspace: workingDirectory, environment: environment),
               environment: environment
           )
        {
            writableRoots = profile.readWrite.map(\.path)
        } else {
            writableRoots = []
        }
        return CodexPermissions(
            sandbox: sandboxName,
            sandboxMode: sandboxMode,
            sandboxProfile: activeProfile,
            networkAccess: !OpenGrokSandbox.shouldRestrictChildNetwork(),
            writableRoots: writableRoots,
            approvalPolicy: alwaysApprove ? .never : .onRequest,
            autoReviewEnabled: autoReviewEnabled
        )
    }
    private let hookPermissionGate: HookPermissionGate?
    /// The OS sandbox this session runs under. `profileName` is what a session
    /// writer persists so a resume is pinned to the same profile.
    let sandbox: LiveSandboxDecision
    /// Which of `get_task_output` / `wait_tasks` / `kill_task` this session
    /// actually advertised. Only an advertised name is dispatched, so a profile
    /// that filtered one out cannot reach it by calling it anyway.
    private let backgroundTaskToolNames: Set<String>
    /// The session's subagent host: one `OpenGrokAgentCoordinator` per root
    /// session plus the child runner. `nil` when the surface is gated off
    /// (`--no-subagents` or an empty roster), which also strips the spawn
    /// tool from the advertised list.
    let subagentHost: LiveSubagentHost?
    /// The advertised spawn-surface names (at most `["spawn_subagent"]`).
    /// Dispatch accepts the canonical `task` spelling too, but only while
    /// this set is non-empty — an unadvertised surface is unreachable.
    private let subagentToolNames: Set<String>
    /// The advertised swarm-surface names (at most `["agent_swarm"]`).
    /// Same reachability rule: an unadvertised surface is undispatchable.
    private let swarmToolNames: Set<String>
    /// The session's handle on the team mailbox — coordinator plus this
    /// session's identity. Root sessions derive it from `subagentHost`;
    /// children receive theirs from the host with the child identity. `nil`
    /// when the collaboration surface is gated off, which also strips the
    /// quartet from the advertised list.
    let agentCollaboration: LiveAgentCollaboration?
    /// The advertised collaboration-tool names (at most the quartet). Same
    /// reachability rule as the spawn/swarm surfaces: only an advertised
    /// name dispatches.
    private let collaborationToolNames: Set<String>
    /// The session's scheduler runtime: task store + sleep-until-due timer +
    /// the in-session fire seam. `nil` when the composition has no fire path
    /// (headless, ACP, children), which also strips the `scheduler_*` tools
    /// from the advertised list — absence of the surface means absence of
    /// the tool, never a create whose fires can never run (AGENTS.md §4).
    let schedulerHost: LiveSchedulerHost?
    /// The advertised scheduler-tool names (at most the trio). Same
    /// reachability rule: an unadvertised surface is undispatchable.
    private let schedulerToolNames: Set<String>
    /// The session's monitor runtime: real background processes with
    /// `kind: .monitor` plus the stdout pipelines that stream their lines
    /// as model-facing events. `nil` when the composition has no delivery
    /// seam (headless, ACP, children), which strips `monitor` from the
    /// advertised list — a monitor whose events can never arrive is worse
    /// than an absent tool (AGENTS.md §4).
    let monitorHost: LiveMonitorHost?
    /// The advertised monitor-tool name (at most `["monitor"]`). Same
    /// reachability rule: an unadvertised surface is undispatchable.
    private let monitorToolNames: Set<String>
    /// Session-local swarm-mode tracker, shared by the `/swarm` slash path,
    /// the `agent_swarm` tool trigger, and the turn loop's reminder
    /// injection — one tracker, so the three can never disagree (the port
    /// of the `swarm_mode` field on session state, acp_session.rs:320).
    let swarmMode = LiveSwarmModeState()
    private let mcpConnections: MCPSessionConnections
    /// Per-server connection outcomes recorded when the session brought its
    /// configured MCP servers online. `/mcps` renders these; before they were
    /// captured, `connectConfiguredServers`' report was discarded and the
    /// session had no way to say which server failed or why.
    let mcpServerConnections: [MCPServerConnection]
    /// The live MCP surfaces the `x.ai/mcp/*` ACP handlers operate on: the
    /// SAME pool the session's bridged tools call through, and the SAME
    /// toolset the model is offered — an ext-method mutation
    /// (upsert/delete/auth_trigger) must land on the running session, never
    /// on a parallel copy (AGENTS.md §3).
    var mcpSessionConnections: MCPSessionConnections { mcpConnections }
    var mcpToolset: FinalizedToolset { fileToolBridge.toolset }
    /// Rewind snapshots, memory and goals. Optional so every construction site
    /// that predates them keeps compiling and simply advertises none of their
    /// tools; see `LiveSessionServices.swift`.
    let sessionServices: LiveSessionServices?
    let hookPresentationStore: LiveHookPresentationStore
    /// The exact store backing the advertised `todo_write` handler. The
    /// renderer reads this actor through the executor so a successful tool
    /// call and the visible pane can never point at different lists.
    let todoStore: LiveTodoStore
    let telemetryStatus: LiveTelemetryStatus
    /// Live LSP pull session when `features.lsp_tools` registered a tool.
    private let lspPullSession: LSPPullSession?

    init(
        processBackend: any ShellProcessBackend,
        sessionID: String,
        workingDirectory: URL,
        toolPolicy: LiveAgentToolPolicy?,
        telemetryBootstrapContext: LiveTelemetryBootstrapContext,
        fileAccessPolicy: FileToolAccessPolicy = .denyByDefault,
        // Hooks and MCP servers are discovered from config and environment, and
        // both of them *spawn processes*. Taking the environment as an argument
        // keeps that discovery bound to the caller's session rather than to
        // whatever `ProcessInfo` happens to hold, so a test can build an
        // executor without picking up the developer's real hooks and servers.
        environment: [String: String] = ProcessInfo.processInfo.environment,
        // Image-tool availability is a *credential* decision, so it needs the
        // session's resolved sampling identity. Defaulted so the many
        // construction sites that predate the image tools keep compiling; a
        // session that passes nothing simply never advertises them.
        imageToolContext: LiveImageToolContext? = nil,
        // Video tools share the image transport and the same xAI credential
        // gate. Defaulted so older construction sites advertise nothing.
        videoToolContext: LiveVideoToolContext? = nil,
        // Web-tool availability is likewise a credential decision — plus the
        // `--disable-web-search` switch. Defaulted so construction sites that
        // predate the web tools keep compiling and simply advertise nothing.
        webToolContext: LiveWebToolContext? = nil,
        // Foundation and workflow children pass the auth-derived policy from
        // the parent session; standalone fixtures must choose an explicit
        // context rather than silently defaulting to telemetry-enabled.
        sandboxDecision: LiveSandboxDecision? = nil,
        securityContext: LiveSecurityContext? = nil,
        // The `sandbox_profile` a resumed session was created under. A resume
        // that would weaken it is refused rather than silently downgraded.
        persistedSandboxProfile: String? = nil,
        // Rewind / memory / goals. Defaulted to nil so a session that opts into
        // none of them advertises no extra tools and writes nothing to disk.
        sessionServices: LiveSessionServices? = nil,
        // `common.permissions` from the root parser. Defaulted so the many
        // construction sites that predate the flags keep compiling; a session
        // that passes nothing simply has no CLI permission tier.
        permissionOptions: CLIPermissionOptions = CLIPermissionOptions(),
        inheritedPermissionHandle: PermissionHandle? = nil,
        sandboxAutoAllowBash: (@Sendable () -> Bool)? = nil,
        // Plan mode is a root-session interaction: a subagent calling
        // `exit_plan_mode` would present a plan dialog indistinguishable from
        // the parent's, so upstream strips the plan-mode tools from every
        // subagent toolset (`strip_plan_mode_tools`,
        // `xai-grok-agent/src/builder.rs:798-803`). The Swift port has no
        // live subagent sessions yet, so this defaults to false and the strip
        // rule is encoded as the branch that drops the plan-mode tools here.
        // The day a subagent session exists, this is the single switch that
        // keeps the lifecycle out of its hands; do not register the tools and
        // then no-op them — that violates §4.
        subagent: Bool = false,
        // The subagent host. Defaulted to nil so every construction site that
        // predates the subagent stack keeps compiling and simply advertises
        // no spawn surface; children are built with nil here, which is half
        // of the nested-spawn strip (the other half is the policy filter).
        subagentHost: LiveSubagentHost? = nil,
        // The team-mailbox context for a CHILD composition. Root sessions
        // leave this nil and derive their own from `subagentHost`; the
        // subagent host passes one per child with the child's identity. A
        // child context advertises the full quartet unfiltered — upstream
        // children always carry it: the builder pushes the collaboration
        // tools past the definition's tool list (builder.rs:871-877), every
        // capability mode allows `ToolKind::AgentCollaboration`
        // (task/types.rs:484-573), and the nested strip keeps them
        // ("mailbox collaboration must remain", task/types.rs:1407-1434).
        agentCollaboration: LiveAgentCollaboration? = nil,
        // The `ask_user_question` surface. Defaulted to nil so headless, ACP
        // and subagent-child constructions simply never advertise the tool —
        // absence of the surface must mean absence of the tool, never a tool
        // that errors (§4: no dead dropdown rows). Only the interactive TUI
        // foundation passes one.
        userQuestions: (any UserQuestionPresenting)? = nil,
        // The dedicated `exit_plan_mode` plan-approval view. Defaulted to nil
        // so every other construction keeps the generic permission-sheet
        // fallback (`PermissionPipeline.requestExitPlanApproval`) — the
        // pre-dedicated-view behavior, never an auto-approve. Only the
        // interactive TUI foundation passes one.
        planApprovals: (any PlanApprovalPrompting)? = nil,
        // The scheduler runtime. Defaulted to nil so every construction site
        // without an in-session fire path (headless, ACP, workflow children,
        // subagent children) advertises no `scheduler_*` tools; only the
        // interactive TUI foundation passes one.
        schedulerHost: LiveSchedulerHost? = nil,
        // The monitor runtime, same defaulting rule: only the interactive
        // TUI foundation has an event-delivery seam, so only it passes one.
        monitorHost: LiveMonitorHost? = nil
    ) async throws {
        self.subagentHost = subagentHost
        self.sessionEnvironment = environment
        let composition = OpenGrokShellToolRuntimeComposition(
            processBackend: processBackend,
            runtime: LiveRunTerminalToolRuntime(subagents: subagentHost)
        )
        try await composition.registerSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        let standardizedWorkingDirectory = workingDirectory.standardizedFileURL
        let hookPresentationStore = LiveHookPresentationStore()
        self.hookPresentationStore = hookPresentationStore
        let hooks = LiveHooksComposition.load(
            sessionId: sessionID,
            workspaceRoot: standardizedWorkingDirectory,
            environment: environment
        )
        hooks.gate?.setRunObserver { event, id, records in
            Task {
                await hookPresentationStore.record(event: event, id: id, records: records)
            }
        }
        // Config precedence, folder trust and the permission policy, resolved
        // once and shared by the file tools, `run_terminal_cmd` and MCP.
        let security = securityContext ?? LiveSecurityContext.resolve(
            workspaceRoot: standardizedWorkingDirectory,
            environment: environment,
            isInteractive: fileAccessPolicy.isInteractive,
            cli: permissionOptions
        )
        // Deliberately `bootstrapFromDisk` rather than the security context's
        // already-loaded document: that document carries the project tier, and
        // upstream has no project layer for telemetry. Passing it would let a
        // repo's checked-in `.opengrok/config.toml` enable telemetry for
        // everyone who clones it. Pinned by `projectConfigCannotEnableTelemetry`.
        self.telemetryStatus = LiveTelemetry.bootstrapFromDisk(
            environment: environment,
            zeroDataRetention: telemetryBootstrapContext.zeroDataRetention,
            userID: telemetryBootstrapContext.userID,
            teamID: telemetryBootstrapContext.teamID
        )
        // Applied before any tool can run. A configured-but-unenforceable
        // profile throws out of `init`, so the session refuses to start rather
        // than running unsandboxed after the user asked for one.
        if let sandboxDecision {
            self.sandbox = sandboxDecision
        } else {
            self.sandbox = try security.applySandbox(
                workspaceRoot: standardizedWorkingDirectory,
                cliProfile: permissionOptions.sandboxProfile,
                persistedProfile: persistedSandboxProfile,
                environment: environment
            )
        }
        let sandboxIsEnforced = self.sandbox.enforced
        let sandboxPredicate: @Sendable () -> Bool = sandboxAutoAllowBash ?? {
            sandboxIsEnforced && shouldAutoAllowBash()
        }
        // One live hunk tracker per session. Attribution is recorded inside
        // `SessionFS.writeText` / `ApplyPatchTool` *only after* a successful
        // write (gate order step 7), so a denied or failed edit records
        // nothing — wiring the actor here is what makes that reachability
        // real rather than a tested library no live session constructs.
        let hunkTracker = HunkTrackerActor(
            sessionId: sessionID,
            workingDir: standardizedWorkingDirectory.path,
            defaultAgentId: "main"
        )
        // One live plan tracker per session, rooted at the workspace. The
        // plan gate (PermissionPipeline step 1) and plan-file auto-approval
        // (step 3) consult this; without a live tracker the gate could never
        // arm, so `enter_plan_mode` would be a no-op dropdown row.
        let planMode = PlanModeTracker(
            state: .inactive,
            planFilePath: ".opengrok/plan.md",
            sessionDirectory: standardizedWorkingDirectory.path
        )
        let fileToolResources = FileToolSession.makeResources(
            workspaceRoot: standardizedWorkingDirectory.path,
            sessionId: sessionID,
            agentId: "main",
            policy: fileAccessPolicy,
            planMode: planMode,
            hooks: hooks.gate.map { $0 as any PreToolUseHookRunner } ?? FailOpenPreToolUseHookRunner(),
            hunkTracker: hunkTracker,
            resolved: security.permissions,
            inheritedPermissionHandle: inheritedPermissionHandle,
            sandboxAutoAllowBash: sandboxPredicate
        )
        // The dedicated plan-approval view, root sessions only: a child's
        // plan sheet would be indistinguishable from the parent's (the same
        // reason the plan-mode tools themselves are stripped below), and the
        // subagent guard means a child pipeline can never present one.
        if !subagent, let planApprovals, let pipeline = fileToolResources.permissionPipeline {
            await pipeline.installPlanApprovalPrompter(planApprovals)
        }
        // The build pack plus, when the session's credentials allow it, the
        // image tools. Both go through one `finalize`, so image tools inherit
        // the same capability filter, permission pipeline and dispatch path.
        var builder = FileToolPack.makeBuilder()
        var toolConfig = toolServerConfig(
            for: .build,
            catalogKinds: builder.knownToolKinds()
        )
        if let imageToolContext {
            let availability = imageToolContext.availability
            if availability.advertisesAnything,
               let imageClient = try? ImageGenClient(
                   config: availability.config,
                   transport: imageToolContext.transport
               ) {
                let handler = LiveImageToolHandler(client: imageClient)
                let kinds = BuiltinToolCatalog.mediaToolKinds
                if availability.imageGenEnabled {
                    builder.setHandler(
                        qualifiedId: BuiltinToolCatalog.imageGenQualifiedId,
                        handler: handler
                    )
                    toolConfig.tools.append(ToolConfig.fromId(
                        BuiltinToolCatalog.imageGenQualifiedId,
                        kind: kinds[BuiltinToolCatalog.imageGenQualifiedId]
                    ))
                }
                if availability.imageEditEnabled {
                    builder.setHandler(
                        qualifiedId: BuiltinToolCatalog.imageEditQualifiedId,
                        handler: handler
                    )
                    toolConfig.tools.append(ToolConfig.fromId(
                        BuiltinToolCatalog.imageEditQualifiedId,
                        kind: kinds[BuiltinToolCatalog.imageEditQualifiedId]
                    ))
                }
            }
        }
        if let videoToolContext {
            LiveVideoToolComposition.registerImageToVideo(
                context: videoToolContext,
                builder: &builder,
                toolConfig: &toolConfig
            )
        }
        // `todo_write` needs no credentials and no configuration — its whole
        // backing state is this session's in-memory list — so unlike the image
        // and web tools it is registered unconditionally and gated only by the
        // agent profile.
        let todoStore = LiveTodoStore()
        self.todoStore = todoStore
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.todoWriteQualifiedId,
            handler: LiveTodoToolHandler(store: todoStore)
        )
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.todoWriteQualifiedId,
            kind: BuiltinToolCatalog.sessionStateToolKinds[BuiltinToolCatalog.todoWriteQualifiedId]
        ))
        // `enter_plan_mode` / `exit_plan_mode` — the agent-initiated plan-mode
        // lifecycle. Registered on the live tool list only for the root session;
        // a subagent session never sees them (see `subagent` above and
        // `strip_plan_mode_tools` upstream). The handlers arm/disarm the
        // session's `PlanModeTracker` through the live `PermissionPipeline`,
        // so the plan gate (step 1) and plan-file auto-approval (step 3) can
        // finally fire on the live path.
        if !subagent {
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.enterPlanModeQualifiedId,
                handler: EnterPlanModeToolHandler()
            )
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.exitPlanModeQualifiedId,
                handler: ExitPlanModeToolHandler()
            )
            let planModeKinds = BuiltinToolCatalog.planModeToolKinds
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.enterPlanModeQualifiedId,
                kind: planModeKinds[BuiltinToolCatalog.enterPlanModeQualifiedId]
            ))
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.exitPlanModeQualifiedId,
                kind: planModeKinds[BuiltinToolCatalog.exitPlanModeQualifiedId]
            ))
        }
        // `ask_user_question` — root sessions with a live interactive question
        // surface, and nothing else. The `userQuestions` gate is the honest
        // form of upstream's `ask_user_question_enabled` strip
        // (`xai-grok-agent/src/builder.rs:819-825`): headless/ACP/child
        // compositions pass no surface, so the model is never offered a tool
        // that would block on a sheet no one can see. The subagent guard also
        // diverges from upstream's inherit-the-parent-gate
        // (`xai-grok-shell/src/agent/subagent/mod.rs:196-198`) — see the strip
        // in `applyChildToolPolicy` for why the port's children cannot ask.
        if !subagent, let userQuestions {
            fileToolResources.userQuestions = userQuestions
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.askUserQuestionQualifiedId,
                handler: AskUserQuestionToolHandler()
            )
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.askUserQuestionQualifiedId,
                kind: BuiltinToolCatalog.askUserQuestionToolKinds[
                    BuiltinToolCatalog.askUserQuestionQualifiedId
                ]
            ))
        }
        if let webToolContext {
            let availability = webToolContext.availability
            if availability.advertisesAnything {
                // A session with `web_fetch` but no search backend still gets a
                // handler; `searchClient` stays nil and only the search arms
                // refuse. Fetching a URL needs no API key.
                let searchClient = availability.searchConfig.isEnabled
                    ? try? WebSearchClient(
                        configuration: availability.searchConfig,
                        transport: webToolContext.transport
                    )
                    : nil
                let handler = LiveWebToolHandler(
                    searchClient: searchClient,
                    fetchClient: WebFetchClient(
                        transport: webToolContext.transport,
                        environment: environment
                    )
                )
                let kinds = BuiltinToolCatalog.webToolKinds
                let advertised: [(Bool, String)] = [
                    (availability.webSearchEnabled && searchClient != nil,
                     BuiltinToolCatalog.webSearchQualifiedId),
                    (availability.webFetchEnabled,
                     BuiltinToolCatalog.webFetchQualifiedId),
                    (availability.xSearchEnabled && searchClient != nil,
                     BuiltinToolCatalog.xSearchQualifiedId),
                ]
                for (enabled, qualifiedId) in advertised where enabled {
                    builder.setHandler(qualifiedId: qualifiedId, handler: handler)
                    toolConfig.tools.append(ToolConfig.fromId(
                        qualifiedId,
                        kind: kinds[qualifiedId]
                    ))
                }
            }
        }
        // MCP meta-tools (`search_tool` / `use_tool`). Always retained in the
        // catalog; listed here so they survive finalize for this session.
        // `use_tool`'s handler needs the finalized toolset and is installed
        // immediately after finalize (see below).
        let mcpSearchIndex = LiveMCPToolSearchIndex()
        fileToolResources.extras.insert(ToolSearchIndexResource(mcpSearchIndex))
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.searchToolQualifiedId,
            handler: SearchToolHandler()
        )
        let mcpMetaKinds = BuiltinToolCatalog.mcpMetaToolKinds
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.searchToolQualifiedId,
            kind: mcpMetaKinds[BuiltinToolCatalog.searchToolQualifiedId]
        ))
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.useToolQualifiedId,
            kind: mcpMetaKinds[BuiltinToolCatalog.useToolQualifiedId]
        ))
        let fileToolBridge = try ToolBridge.finalize(
            builder: builder,
            config: toolConfig,
            resources: fileToolResources,
            options: FinalizeOptions(
                capabilityMode: Self.capabilityMode(for: toolPolicy)
            )
        )
        let toolset = fileToolBridge.toolset
        // `UseToolHandler` dispatches through the same toolset — install after
        // finalize so the circular dependency is a stored reference, not a
        // builder-time value that does not exist yet.
        toolset.setHandler(
            clientName: "use_tool",
            handler: UseToolHandler(toolset: toolset)
        )
        let nativeNames = Set(
            toolset.clientNames.filter { name in
                toolset.tool(named: name)?.namespace != .mcp
            }
        )
        toolset.resources.extras.insert(EnabledNativeToolNames(nativeNames))
        let mcpConnections = MCPSessionConnections()
        // `security.document` already excludes the project tier when the folder
        // is untrusted, so a hostile repo's `.opengrok/config.toml` servers are
        // simply not present here — they never reach `makeTransport`, which is
        // what spawns the process.
        let mcpServerConnections = await LiveMCPComposition.connectConfiguredServers(
            document: security.document,
            toolset: toolset,
            connections: mcpConnections,
            environment: environment
        )
        // LSP `pull_diagnostics` — after MCP so both share one search index
        // refresh, and before `toolDefinitions()` so the model list includes it.
        let lspPullSession = LiveLspComposition.registerTools(
            toolset: toolset,
            workingDirectory: standardizedWorkingDirectory,
            document: security.document,
            environment: environment
        )
        mcpSearchIndex.refresh(from: toolset)
        let fileToolDefinitions = fileToolBridge.toolDefinitions()
        let allowedFileToolDefinitions = fileToolDefinitions.filter {
            toolPolicy?.allows(liveToolName: $0.name) ?? true
        }
        // The spawn surface's own requirement expr (task/mod.rs:120-128): it
        // exists only alongside the retrieval and kill surfaces for what it
        // spawns. Both must survive the profile filter below.
        let outputToolAllowed = toolPolicy?.allows(
            liveToolName: LiveBackgroundTaskTools.getTaskOutputName
        ) ?? true
        let killToolAllowed = toolPolicy?.allows(
            liveToolName: LiveBackgroundTaskTools.killTaskName
        ) ?? true
        let advertisesSubagents = subagentHost != nil
            && (toolPolicy?.allows(liveToolName: LiveSubagentHost.advertisedToolName) ?? true)
            && outputToolAllowed
            && killToolAllowed
        self.subagentToolNames = advertisesSubagents
            ? [LiveSubagentHost.advertisedToolName]
            : []
        // `agent_swarm` exists only alongside the task surface it
        // orchestrates: upstream strips task, agent_swarm, workflow and the
        // collaboration tools together when subagents are disabled or the
        // roster is empty (builder.rs:848-869), and the tool's own
        // requirement expression demands the Task tool
        // (`requires_expr`, agent_swarm/mod.rs:237-239). `advertisesSubagents`
        // is that gate; the profile filter can still strip the swarm alone.
        let advertisesSwarm = advertisesSubagents
            && (toolPolicy?.allows(liveToolName: LiveSubagentHost.swarmToolName) ?? true)
        self.swarmToolNames = advertisesSwarm
            ? [LiveSubagentHost.swarmToolName, LiveSubagentHost.swarmWaitToolName]
            : []
        // The collaboration quartet. Enablement is the task surface's own
        // (ad95b111 pins presence to subagents_enabled; builder.rs:848-877
        // strips task, agent_swarm, workflow and the quartet together and
        // pushes the quartet back only when the roster survives), then the
        // per-tool profile filter applies on top — the same two-layer shape
        // as `advertisesSwarm`. A CHILD composition arrives with an explicit
        // `agentCollaboration` and no host: it advertises the full quartet
        // unfiltered, the port of upstream's builder push past the
        // definition tool list plus the nested strip keeping the mailbox
        // tools (see the parameter comment above).
        let collaborationTools: [ToolSpec]
        if let agentCollaboration {
            self.agentCollaboration = agentCollaboration
            collaborationTools = LiveAgentCollaboration.toolSpecs()
        } else if advertisesSubagents, let subagentHost {
            let advertised = AgentCollaborationTool.allCases.filter {
                toolPolicy?.allows(liveToolName: $0.toolID) ?? true
            }
            self.agentCollaboration = advertised.isEmpty ? nil : LiveAgentCollaboration(
                coordinator: subagentHost.coordinator,
                identity: AgentMailboxIdentity(teamScopeID: sessionID, agentID: sessionID)
            )
            collaborationTools = LiveAgentCollaboration.toolSpecs(for: advertised)
        } else {
            self.agentCollaboration = nil
            collaborationTools = []
        }
        self.collaborationToolNames = Set(collaborationTools.map(\.name))
        // The background-task consumers only make sense alongside the producer:
        // without `run_terminal_cmd` there is no task for them to read, wait on
        // or kill. Upstream registers all three in every preset that has bash
        // (`xai-grok-tools/src/registry/types.rs:694-701`) for the same reason.
        let backgroundTaskTools: [ToolSpec]
        let terminalTools: [ToolSpec]
        let monitorTools: [ToolSpec]
        if toolPolicy?.allows(liveToolName: Self.runTerminalTool.name) == false {
            backgroundTaskTools = []
            terminalTools = []
            // The monitor rides the same process surface `run_terminal_cmd`
            // does (upstream requires the `Terminal` resource, tool.rs:90);
            // a profile that strips the terminal strips the monitor with it.
            monitorTools = []
        } else {
            backgroundTaskTools = LiveBackgroundTaskTools
                .toolSpecs(environment: environment, subagentsPresent: advertisesSubagents)
                .filter { toolPolicy?.allows(liveToolName: $0.name) ?? true }
            terminalTools = [Self.runTerminalTool] + backgroundTaskTools
            // `monitor` — enablement is the host's presence (only the
            // interactive foundation constructs one; its event sink's idle
            // half is the controller's queue), then the per-tool profile
            // filter. Upstream's `requires_expr` is `Expr::True`
            // (tool.rs:41-43); the host-presence gate is this port's
            // narrower advertisement, recorded.
            if monitorHost != nil,
               toolPolicy?.allows(liveToolName: LiveMonitorTools.toolName) ?? true {
                monitorTools = [LiveMonitorTools.toolSpec()]
            } else {
                monitorTools = []
            }
        }
        self.backgroundTaskToolNames = Set(backgroundTaskTools.map(\.name))
        self.monitorHost = monitorHost
        self.monitorToolNames = Set(monitorTools.map(\.name))
        let spawnTools: [ToolSpec] = advertisesSubagents
            ? subagentHost.map { host in
                [host.toolSpec] + (advertisesSwarm ? [LiveSubagentHost.swarmToolSpec, LiveSubagentHost.swarmWaitToolSpec] : [])
            } ?? []
            : []
        // The scheduler trio. Enablement is the host's presence (only the
        // interactive foundation constructs one — a session with no fire
        // path must not accept creates whose fires never run), then the
        // per-tool profile filter. `scheduler_delete`/`scheduler_list`
        // require the create surface — upstream's `requires_expr` on both
        // names `SchedulerCreateTool` (delete.rs:48-56, list.rs:45-53) —
        // so a profile that strips `scheduler_create` drops all three.
        self.schedulerHost = schedulerHost
        let schedulerTools: [ToolSpec]
        if schedulerHost != nil,
           toolPolicy?.allows(liveToolName: LiveSchedulerTools.createToolName) ?? true {
            schedulerTools = LiveSchedulerTools.toolSpecs()
                .filter { toolPolicy?.allows(liveToolName: $0.name) ?? true }
        } else {
            schedulerTools = []
        }
        self.schedulerToolNames = Set(schedulerTools.map(\.name))
        self.permissionPipeline = fileToolResources.permissionPipeline
        if let permissionPipeline = fileToolResources.permissionPipeline {
            self.sessionPermissionMode = LiveSessionPermissionMode(
                pipeline: permissionPipeline,
                resolved: security.permissions
            )
        } else {
            self.sessionPermissionMode = nil
        }
        self.hookPermissionGate = hooks.gate
        self.composition = composition
        self.fileToolBridge = fileToolBridge
        self.mcpConnections = mcpConnections
        self.mcpServerConnections = mcpServerConnections
        self.lspPullSession = lspPullSession
        self.registryToolNames = Set(allowedFileToolDefinitions.map(\.name))
        self.workingDirectory = standardizedWorkingDirectory
        self.sessionDirectories = LiveSessionDirectoryRegistry(
            sessionID: sessionID,
            workingDirectory: standardizedWorkingDirectory
        )
        self.sessionServices = sessionServices
        // Session-service tools run through the same agent-profile gate as
        // every other tool, so a read-only profile that denies `memory_search`
        // does not get it back through this door.
        let sessionTools = (sessionServices?.toolSpecs ?? [])
            .filter { toolPolicy?.allows(liveToolName: $0.name) ?? true }
        // `invoke` checks the session-service branch BEFORE everything else, so
        // a session tool sharing a name with any other dispatched tool would
        // silently win — and win the wrong way. It matters differently for the
        // two branches it can shadow:
        //
        //   * a registry tool loses the capability filter, PreToolUse hooks and
        //     the permission pipeline that `ToolBridge` applies;
        //   * `run_terminal_cmd` or a background-task tool loses `gateTerminalCommand`
        //     / the `kill_task` gate — security checks someone deliberately
        //     wrote, which is strictly worse than being merely unfiltered.
        //
        // Precedence-first is the right trade only for session-state RPCs with
        // no filesystem or process surface (`memory_search`, `update_goal`),
        // where being shadowed by a same-named MCP tool is the real hazard.
        // Anything touching files or processes belongs in the registry so its
        // gating is structural. Assert rather than comment, so the day someone
        // adds a colliding name it fails loudly in debug instead of quietly
        // downgrading that tool's gating.
        let dispatchedToolNames = registryToolNames
            .union(backgroundTaskToolNames)
            .union(subagentToolNames)
            .union(swarmToolNames)
            .union(collaborationToolNames)
            .union(schedulerToolNames)
            .union(monitorToolNames)
            .union([Self.runTerminalTool.name])
        assert(
            Set(sessionTools.map(\.name)).isDisjoint(with: dispatchedToolNames),
            """
            session-service tool name collides with a dispatched tool: \
            \(Set(sessionTools.map(\.name)).intersection(dispatchedToolNames)). \
            The session branch runs first and skips the capability filter and \
            hooks that registry tools get, and the permission gate that shell \
            and background-task tools get.
            """
        )
        // Built by appends, not by one `a + b + … + f.map { … }` chain. As a
        // single expression this exceeded the type checker's budget and failed
        // the macOS CI build outright ("unable to type-check this expression in
        // reasonable time") while still compiling locally off a warm
        // incremental cache — so the break was invisible to every local gate
        // and red on every push. Cost: seven statements instead of one
        // expression, and a new tool surface has to be appended here rather
        // than added to the chain. Do not re-collapse this.
        var advertisedTools: [ToolSpec] = []
        advertisedTools.append(contentsOf: terminalTools)
        advertisedTools.append(contentsOf: monitorTools)
        advertisedTools.append(contentsOf: spawnTools)
        advertisedTools.append(contentsOf: collaborationTools)
        advertisedTools.append(contentsOf: schedulerTools)
        advertisedTools.append(contentsOf: sessionTools)
        for definition in allowedFileToolDefinitions {
            let parameters: JSONValue = definition.argumentsSchema
                ?? .object(["type": .string("object")])
            advertisedTools.append(ToolSpec(
                name: definition.name,
                description: definition.description,
                parameters: parameters
            ))
        }
        self.tools = advertisedTools
    }

    func runStop(
        event: HookEvent = .stop,
        promptID: String?,
        payload: [String: HookJSONValue]
    ) async -> StopDispatchResult {
        guard let hookPermissionGate else { return StopDispatchResult() }
        return await hookPermissionGate.runStop(
            event: event,
            promptId: promptID,
            payload: payload
        )
    }

    /// Fire an observe-only hook event (SessionStart, UserPromptSubmit,
    /// PostToolUse, PostToolUseFailure, PermissionDenied, StopFailure,
    /// Notification, PreCompact, PostCompact, SessionEnd).
    ///
    /// Fire-and-forget: the spawned task awaits the dispatch and records its
    /// results in the gate's buffer, but the turn never waits on it. Observe
    /// events cannot gate the turn (PORT_PLAN.md gate order), so a slow or
    /// failing hook command must not stretch the turn's critical path.
    ///
    /// Cost: a hook spawned here may outlive the turn or even the session, and
    /// its records land in the gate's buffer whenever they land — a test that
    /// asserts "the hook ran" must poll the side-effect file the hook writes,
    /// not the turn's completion. The alternative (awaiting inline) would put
    /// a subprocess on every turn's critical path, which is exactly the
    /// failure mode observe events exist to avoid.
    func fireObserveHook(
        event: HookEvent,
        promptID: String? = nil,
        payload: [String: HookJSONValue] = [:]
    ) {
        guard let hookPermissionGate else { return }
        Task {
            _ = await hookPermissionGate.dispatchObserve(
                event: event,
                promptId: promptID,
                payload: payload
            )
        }
    }

    /// Fire `PermissionDenied` for a tool the pipeline refused to authorize.
    /// Payload mirrors upstream's `HookPayload::PermissionDenied`
    /// (event.rs:441-451): `toolName`, `toolUseId`, `toolInput`,
    /// `toolInputTruncated`. The tool never ran, so the caller returns
    /// `.denied` and `executeToolCalls` fires this instead of
    /// `PostToolUseFailure`.
    private func firePermissionDenied(
        call: ToolCall,
        args: JSONValue,
        reason: String
    ) {
        let (toolInput, truncated) = hookTruncatedPayload(from: args)
        fireObserveHook(
            event: .permissionDenied,
            payload: [
                "toolName": .string(call.name),
                "toolUseId": .string(call.callId),
                "toolInput": toolInput,
                "toolInputTruncated": .boolean(truncated),
            ]
        )
    }

    /// Fire `PostToolUse` for a tool that ran and succeeded. Payload mirrors
    /// upstream's `HookPayload::PostToolUse` (event.rs:406-426). `durationMs`
    /// is omitted (nil) to match the fire site at tool_calls.rs:893, which
    /// passes `None`; `isBackgrounded` is false; `subagentType` is omitted for
    /// the top-level session.
    func firePostToolUse(call: ToolCall, result: OpenGrokShellToolCallResult) {
        let (toolInput, inputTruncated) = hookTruncatedPayload(from: parseToolInput(call.arguments))
        let (toolResult, resultTruncated) = hookTruncatedPayload(from: result.value)
        fireObserveHook(
            event: .postToolUse,
            payload: [
                "toolName": .string(call.name),
                "toolUseId": .string(call.callId),
                "toolInput": toolInput,
                "toolResult": toolResult,
                "toolInputTruncated": .boolean(inputTruncated),
                "toolResultTruncated": .boolean(resultTruncated),
                "isBackgrounded": .boolean(false),
            ]
        )
    }

    /// Fire `PostToolUseFailure` for a tool that ran and errored. Payload
    /// mirrors upstream's `HookPayload::PostToolUseFailure`
    /// (event.rs:427-440). A denied tool never ran, so the caller must use
    /// `firePermissionDenied` instead — see `.denied` in `executeToolCalls`.
    func firePostToolUseFailure(call: ToolCall, error: OpenGrokShellToolRuntimeError) {
        let (toolInput, inputTruncated) = hookTruncatedPayload(from: parseToolInput(call.arguments))
        fireObserveHook(
            event: .postToolUseFailure,
            payload: [
                "toolName": .string(call.name),
                "toolUseId": .string(call.callId),
                "toolInput": toolInput,
                "toolInputTruncated": .boolean(inputTruncated),
                "error": .string(error.description),
            ]
        )
    }

    /// Fire a `Notification` hook for a user-attention event. Payload
    /// mirrors upstream's `HookPayload::Notification` (event.rs:457-467):
    /// `notificationType`, optional `message`/`title`/`level`. The primary
    /// fire sites upstream are the session-update fan-out paths
    /// (DiffReview, AutoRecoveryExhausted, RetryState::Exhausted/Failed,
    /// hook_dispatch.rs:64-93); the port's analog is the auth-retry
    /// exhaustion point in the turn loop, which is on the sampler-driven
    /// seam. The ACP/pager notification fan-out is not on this seam and is
    /// not wired here yet.
    func fireNotification(
        type: String,
        message: String? = nil,
        title: String? = nil,
        level: String? = nil
    ) {
        var payload: [String: HookJSONValue] = ["notificationType": .string(type)]
        if let message { payload["message"] = .string(message) }
        if let title { payload["title"] = .string(title) }
        if let level { payload["level"] = .string(level) }
        fireObserveHook(event: .notification, payload: payload)
    }

    /// Parse a tool's raw argument JSON string into a `JSONValue`, falling
    /// back to null — matching the Rust fire site's
    /// `serde_json::from_str(...).unwrap_or(Null)` (tool_calls.rs:842-843).
    private func parseToolInput(_ raw: String) -> JSONValue {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return parsed
    }

    /// Encode `value` as the hook envelope's JSON and truncate it to the
    /// 128 KiB ceiling upstream applies (`MAX_PAYLOAD_SIZE`, event.rs:4),
    /// returning the truncated value plus whether truncation happened. A
    /// payload over the ceiling would let a hook command read unbounded
    /// stdin, so the wire shape keeps a hard cap.
    private func hookTruncatedPayload(from value: JSONValue) -> (HookJSONValue, Bool) {
        let encoded = hookJSON(from: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(encoded) else {
            return (encoded, false)
        }
        let limit = 128 * 1024
        if data.count <= limit {
            return (encoded, false)
        }
        // Cut on a UTF-8 boundary at or below the limit, then mark it.
        var end = limit
        while end > 0 {
            if let _ = String(data: data.subdata(in: 0..<end), encoding: .utf8) {
                break
            }
            end -= 1
        }
        guard end > 0, let truncated = String(data: data.subdata(in: 0..<end), encoding: .utf8) else {
            return (encoded, false)
        }
        return (.string(truncated + " [truncated]"), true)
    }

    /// Listing gate: a read-only agent profile never sees a mutating tool.
    /// A profile that declares no capability mode gets the pack's default.
    private static func capabilityMode(
        for policy: LiveAgentToolPolicy?
    ) -> ToolCapabilityMode {
        switch policy?.capabilityMode {
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        case .execute: return .execute
        case .all: return .all
        case nil: return .readWrite
        }
    }

    // MARK: - Plan mode (the `/plan` / `/view-plan` slash seam)

    /// Whether the session's plan gate is armed, read from the same live
    /// `PermissionPipeline` the `enter_plan_mode` tool handler mutates —
    /// never a renderer-side mirror, which is exactly the parallel flag the
    /// tool path could not see. `false` when the session has no pipeline
    /// (nothing to arm).
    func planModeActive() async -> Bool {
        guard let permissionPipeline else { return false }
        return await permissionPipeline.planModeActive
    }

    /// Arm the plan gate for `/plan` through the same
    /// `PermissionPipeline.enterPlanMode` seam `EnterPlanModeToolHandler`
    /// calls (`PlanModeTools.swift:62-65`). The nil arguments keep the
    /// composition-configured plan path — `.opengrok/plan.md` under the
    /// workspace root, the identical values the tool passes explicitly
    /// (its `sessionFolder` IS the workspace root) — so both paths arm one
    /// tracker at one path. Deliberately does NOT seed the plan file:
    /// upstream's slash path arms via the session-mode switch alone
    /// (`xai-grok-shell/src/session/acp_session_impl/session_mode.rs:30-51`)
    /// and only the `enter_plan_mode` TOOL seeds.
    /// Status-returning on purpose: a nil pipeline means the gate cannot
    /// arm, and the caller must not announce "Plan mode: on" for an arm
    /// that did not happen. Same no-pipeline convention as `gateKillTask` /
    /// `gateTerminalCommand` — explicit refusal, never silence.
    func armPlanMode() async -> Bool {
        guard let permissionPipeline else { return false }
        await permissionPipeline.enterPlanMode()
        return true
    }

    /// Disarm the plan gate for settings `plan_mode = false` through the same
    /// `PermissionPipeline.exitPlanMode` seam `ExitPlanModeToolHandler`
    /// calls after approval. Status-returning like `armPlanMode`: a nil
    /// pipeline means the gate cannot disarm, and the caller must not claim
    /// an exit that did not happen.
    func disarmPlanMode() async -> Bool {
        guard let permissionPipeline else { return false }
        await permissionPipeline.exitPlanMode()
        return true
    }

    /// The absolute plan-file path `/view-plan` reads — the live tracker's
    /// resolved path, i.e. exactly the file the plan-file auto-approval gate
    /// compares edits against — not a second, recomputed location. `nil`
    /// when the session has no pipeline.
    func planFileResolvedPath() async -> String? {
        guard let permissionPipeline else { return nil }
        return await permissionPipeline.planFileResolvedPath()
    }

    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        await invoke(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            call: call,
            onOutput: nil
        )
    }

    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall,
        onOutput: OpenGrokShellForegroundOutputSink?
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let args: JSONValue
        do {
            args = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(call.arguments.utf8)
            )
        } catch {
            return .failure(.invalidCall(
                "tool arguments are not valid JSON: \(error)"
            ))
        }

        // Session tools are checked first so a same-named MCP tool cannot
        // shadow `memory_search` or `update_goal`.
        if let sessionServices, sessionServices.handles(call.name) {
            let output = await sessionServices.invoke(name: call.name, arguments: args)
            return .success(OpenGrokShellToolCallResult(
                value: .string(output),
                promptText: output
            ))
        }

        // Snapshot whatever this call is about to touch, before it touches it.
        // This is the only point in the live path that sees every file tool
        // invocation with its arguments resolved, which is what makes a rewind
        // point per prompt possible without a hook in each tool.
        await sessionServices?.noteToolCall(name: call.name, arguments: args)

        if registryToolNames.contains(call.name) {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            switch await fileToolBridge.call(
                name: call.name,
                args: args,
                callId: call.callId
            ) {
            case .success(let result):
                let promptText = await appendLspDiagnostics(
                    toolName: call.name,
                    args: args,
                    workingDirectory: workingDirectory,
                    promptText: result.promptText
                )
                return .success(OpenGrokShellToolCallResult(
                    value: result.output.value,
                    promptText: promptText
                ))
            case .failure(let error):
                return .failure(.failed(error.description))
            }
        }

        // The spawn surface. Checked before the terminal guard: it is neither
        // a registry tool nor a shell tool, and it answers to the canonical
        // `task` spelling as well as the advertised production name.
        if !subagentToolNames.isEmpty,
           LiveSubagentHost.dispatchNames.contains(call.name),
           let subagentHost {
            if let denial = await gateSpawnSubagent(args: args, call: call) {
                return .failure(denial)
            }
            return await subagentHost.spawn(args: args, toolCallID: call.callId)
        }

        // The swarm surface. The parent call is auto-approved at the
        // permission gate upstream (`swarm_parent_auto_approve`,
        // tool_calls.rs:1533-1545) — each member's own tool calls carry the
        // real permission decisions — so the only gate here is the same
        // PreToolUse hook pass the spawn surface runs.
        if !swarmToolNames.isEmpty,
           let subagentHost {
            if call.name == LiveSubagentHost.swarmToolName {
                if let denial = await gateSpawnSubagent(args: args, call: call) {
                    return .failure(denial)
                }
                return await subagentHost.runSwarm(
                    args: args,
                    toolCallID: call.callId,
                    // The raw text is the only place JSON object order survives
                    // (the JSONValue hop is a Dictionary) — the resume map's
                    // slot order depends on it.
                    rawArguments: call.arguments
                )
            } else if call.name == LiveSubagentHost.swarmWaitToolName {
                return await subagentHost.runSwarmWait(
                    args: args,
                    toolCallID: call.callId
                )
            }
        }

        // The collaboration quartet. Same hooks-only gate as the spawn and
        // swarm surfaces (there is no permission-rule vocabulary for these
        // upstream either); the mailbox itself enforces team scoping,
        // identity, and the dead-target refusals.
        if collaborationToolNames.contains(call.name),
           let agentCollaboration {
            if let denial = await gateCollaborationTool(args: args, call: call) {
                return .failure(denial)
            }
            return await agentCollaboration.invoke(name: call.name, args: args)
        }

        // The scheduler trio — session-state RPCs against the scheduler
        // host. Same hooks-only gate: upstream runs these through the
        // standard PreToolUse pass and has no scheduler permission-rule
        // kind (`requires_expr` is `Expr::True` for create, create.rs:127-129).
        if schedulerToolNames.contains(call.name),
           let schedulerHost {
            if let denial = await gateSchedulerTool(args: args, call: call) {
                return .failure(denial)
            }
            return await LiveSchedulerTools.invoke(
                name: call.name,
                args: args,
                host: schedulerHost
            )
        }

        // The monitor. Its command is a REAL process, so the gate is the
        // full permission pipeline with the command as the bash access —
        // deliberately STRICTER than upstream, which starts the background
        // process without bash-rule evaluation (tool.rs:113-138): this
        // port's `run_terminal_cmd` evaluates `[permission]` bash segments,
        // and a tool that runs the same commands hooks-only would be a
        // second, open door to the surface that gate exists to guard
        // (AGENTS.md §5). Recorded divergence, cost named in the report.
        if monitorToolNames.contains(call.name),
           let monitorHost {
            if let denial = await gateMonitorCommand(args: args, call: call) {
                return .failure(denial)
            }
            do {
                let execution = try await composition.execution(
                    for: sessionID,
                    workingDirectory: workingDirectory
                )
                return await LiveMonitorTools.invoke(
                    args: args,
                    callID: call.callId,
                    process: execution,
                    host: monitorHost
                )
            } catch {
                return .failure(.failed(String(describing: error)))
            }
        }

        guard call.name == Self.runTerminalTool.name
            || backgroundTaskToolNames.contains(call.name)
        else {
            return .failure(.unsupported("unknown tool '\(call.name)'"))
        }

        // Shell execution goes through the same pipeline the file tools use:
        // PreToolUse hooks, `[permission]` deny/ask/allow with Rust's
        // bash-segment evaluation, the shell file-access escalation that stops
        // a `sed -i` from editing a denied path, and the interactive modal.
        // `kill_task` is gated too. Tearing a process down only de-escalates
        // the *process*; the workspace is what is at risk. A killed `git rebase`
        // leaves a detached HEAD and a half-applied stack, a killed install a
        // partially written store. Ownership-scoping bounds the blast radius to
        // this session's tasks — which are exactly the ones `run_terminal_cmd`
        // started, i.e. the destructive set.
        //
        // Matched on the canonical name, not the literal: dispatch also accepts
        // upstream's `kill_command_or_subagent` spelling — which is what the
        // agent profiles actually spell — so a string match would leave that
        // door open. `get_task_output` / `wait_tasks` stay ungated: they read
        // output from a task whose permission decision was already made.
        //
        // Chained rather than two independent `if`s. The two are disjoint today,
        // so it makes no behavioural difference — but the next gated tool will
        // be copied from the shape that is here.
        if call.name == Self.runTerminalTool.name {
            if let denial = await gateTerminalCommand(args: args, call: call) {
                return .failure(denial)
            }
        } else if LiveBackgroundTaskTools.canonicalName(for: call.name)
            == LiveBackgroundTaskTools.killTaskName {
            if let denial = await gateKillTask(args: args, call: call) {
                return .failure(denial)
            }
        }

        do {
            return try await composition.invoke(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                name: call.name,
                args: args,
                callID: call.callId,
                onOutput: onOutput
            )
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    /// Run `spawn_subagent` through the session's PreToolUse hooks.
    ///
    /// Deliberately hooks-only, unlike the `kill_task` gate: the permission
    /// rule vocabulary has no spawn kind upstream either (`ToolFilter` covers
    /// any/bash/edit/read/grep/mcp/web_fetch/web_search), and modelling the
    /// call as `.bash` for the *engine* would feed "spawn_subagent explore"
    /// to the shell command classifier, which denies unknown commands under a
    /// headless prompter — a wrong answer, not a safer one. The access string
    /// below only reaches hook payloads, where a hook can match the tool name
    /// and see what is being spawned. The security-relevant surface is the
    /// child's own tool calls, and those pass through the child's full
    /// pipeline, built from this session's security context.
    private func gateSpawnSubagent(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        // No pipeline means no hooks to run — PreToolUse's recorded posture
        // is fail-open, so the spawn proceeds.
        guard let permissionPipeline else { return nil }
        let subagentType: String
        if case .object(let object) = args, case .string(let raw) = object["subagent_type"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            subagentType = trimmed.isEmpty ? defaultSubagentType : trimmed
        } else {
            subagentType = defaultSubagentType
        }
        let decision = await permissionPipeline.hooks.runPreToolUse(
            toolName: call.name,
            toolCallId: call.callId,
            access: .bash("spawn_subagent \(subagentType)"),
            permissionMode: nil
        )
        if case .deny(let reason, let hookName) = decision {
            return .failed("hook \(hookName) denied: \(reason)")
        }
        return nil
    }

    /// Run a scheduler tool through the session's PreToolUse hooks.
    ///
    /// Hooks-only, the `gateCollaborationTool` shape: the permission rule
    /// vocabulary has no scheduler kind upstream either, and the calls are
    /// session-state RPCs — no file, no process. The security-relevant
    /// surface is the FIRED prompt's own tool calls, and a cron turn's calls
    /// pass through this session's full pipeline exactly like a typed
    /// prompt's.
    private func gateSchedulerTool(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else { return nil }
        var access = call.name
        if case .object(let object) = args {
            // Surface the schedule and target id to hook payloads, so a hook
            // can match on what is being scheduled or cancelled.
            if case .string(let interval)? = object["interval"] {
                let trimmed = interval.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { access += " \(trimmed)" }
            }
            if case .string(let id)? = object["id"] {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { access += " \(trimmed)" }
            }
        }
        let decision = await permissionPipeline.hooks.runPreToolUse(
            toolName: call.name,
            toolCallId: call.callId,
            access: .bash(access),
            permissionMode: nil
        )
        if case .deny(let reason, let hookName) = decision {
            return .failed("hook \(hookName) denied: \(reason)")
        }
        return nil
    }

    /// Run a collaboration tool through the session's PreToolUse hooks.
    ///
    /// Hooks-only, for the same reason as `gateSpawnSubagent`: the permission
    /// rule vocabulary has no mailbox kind, and the access string below only
    /// reaches hook payloads, where a hook can match the tool name and see
    /// which agent is being addressed. The tools themselves are team-scoped
    /// reads and bounded queue writes; the security-relevant surface is what
    /// the RECIPIENT does with the text, and a recipient's tool calls pass
    /// through its own full pipeline.
    private func gateCollaborationTool(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else { return nil }
        var access = call.name
        if case .object(let object) = args,
           case .string(let target)? = object["target"] {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { access += " \(trimmed)" }
        }
        let decision = await permissionPipeline.hooks.runPreToolUse(
            toolName: call.name,
            toolCallId: call.callId,
            access: .bash(access),
            permissionMode: nil
        )
        if case .deny(let reason, let hookName) = decision {
            return .failed("hook \(hookName) denied: \(reason)")
        }
        return nil
    }

    /// Run `kill_task` through the permission pipeline.
    ///
    /// Modelled as `.bash("kill_task <id>")` so a user can express
    /// `deny = ["Bash(kill_task:*)"]`. With no matching rule the bash path
    /// falls through to the built-in safe classification, so the common case
    /// costs no prompt.
    ///
    /// Two `nil`-shaped situations that are NOT the same thing, and the
    /// distinction is the whole point of a gate:
    ///
    ///   * **No pipeline** — the gate *cannot* authorize, so it denies. Anything
    ///     else means a session with no permission machinery kills freely.
    ///   * **No `task_id`** — there is *nothing* to authorize, so it proceeds.
    ///     `LiveBackgroundTaskTools.killTask` rejects the call with
    ///     `.invalidCall` before it ever reaches `process.killTask`, so nothing
    ///     is killed; duplicating that check here would only produce two
    ///     different error messages for one malformed call.
    private func gateKillTask(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else {
            return .failed(
                "'\(call.name)' has no permission gate configured for this session"
            )
        }
        guard case .object(let object) = args,
              case .string(let rawTaskID)? = object["task_id"]
        else { return nil }
        let taskID = rawTaskID.trimmingCharacters(in: .whitespacesAndNewlines)
        if taskID.isEmpty { return nil }

        let prepared = await permissionPipeline.prepare(PrepareToolAccessRequest(
            access: .bash("kill_task \(taskID)"),
            toolName: call.name,
            toolCallId: call.callId,
            permissionModeLabel: await sessionPermissionMode?.permissionModeLabel()
        ))
        if prepared.mayDispatch { return nil }
        switch prepared.decision {
        case .policyDeny(let reason), .reject(let reason):
            firePermissionDenied(call: call, args: args, reason: reason)
            return .denied(reason)
        case .cancelled:
            return .cancelled
        case .followupMessage(let message):
            return .failed(message)
        case .ask:
            return .failed("'\(call.name)' requires approval, and no prompter is available.")
        case .allow:
            return nil
        }
    }

    /// Run `monitor` through the permission pipeline, `gateTerminalCommand`'s
    /// shape with the monitored command as the bash access: a rule that
    /// denies `Bash(foo:*)` denies monitoring `foo` too, because the monitor
    /// RUNS `foo`. Fails closed on no pipeline for the same reason the
    /// terminal gate does — the tool spawns a real process, and "cannot
    /// authorize" must read as deny, never as dispatch.
    private func gateMonitorCommand(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else {
            return .failed(
                "'\(call.name)' has no permission gate configured for this session"
            )
        }
        guard case .object(let object) = args,
              case .string(let command)? = object["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .invalidCall("\(LiveMonitorTools.toolName) requires a non-empty command")
        }

        let prepared = await permissionPipeline.prepare(PrepareToolAccessRequest(
            access: .bash(command),
            toolName: call.name,
            toolCallId: call.callId,
            permissionModeLabel: await sessionPermissionMode?.permissionModeLabel()
        ))
        if prepared.mayDispatch { return nil }

        switch prepared.decision {
        case .policyDeny(let reason), .reject(let reason):
            firePermissionDenied(call: call, args: args, reason: reason)
            return .denied(reason)
        case .cancelled:
            return .cancelled
        case .followupMessage(let message):
            return .failed(message)
        case .ask:
            // The engine asked and nothing answered — deny rather than run.
            return .failed("'\(call.name)' requires approval, and no prompter is available.")
        case .allow:
            return nil
        }
    }

    /// Run `run_terminal_cmd` through the permission pipeline.
    ///
    /// Returns the error to fail the call with, or nil to proceed. Fails closed
    /// on every path that is not an explicit allow: a session with no pipeline,
    /// a malformed command, a policy deny, a hook deny, and a bare `.ask` that
    /// no prompter resolved all stop the command.
    private func gateTerminalCommand(
        args: JSONValue,
        call: ToolCall
    ) async -> OpenGrokShellToolRuntimeError? {
        guard let permissionPipeline else {
            return .failed(
                "'\(call.name)' has no permission gate configured for this session"
            )
        }
        guard case .object(let object) = args,
              case .string(let command)? = object["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .invalidCall("run_terminal_cmd requires a non-empty command")
        }

        let prepared = await permissionPipeline.prepare(PrepareToolAccessRequest(
            access: .bash(command),
            toolName: call.name,
            toolCallId: call.callId,
            permissionModeLabel: await sessionPermissionMode?.permissionModeLabel()
        ))
        if prepared.mayDispatch { return nil }

        switch prepared.decision {
        case .policyDeny(let reason), .reject(let reason):
            firePermissionDenied(call: call, args: args, reason: reason)
            return .denied(reason)
        case .cancelled:
            return .cancelled
        case .followupMessage(let message):
            return .failed(message)
        case .ask:
            // The engine asked and nothing answered — deny rather than run.
            return .failed("'\(call.name)' requires approval, and no prompter is available.")
        case .allow:
            return nil
        }
    }

    /// After registry tools: notify LSP of search_replace edits (disk re-read)
    /// and drain pending diagnostics into a system-reminder, matching Rust
    /// `LspDiagnosticsReminder` (`reminders/lsp_diagnostics.rs:14-47`).
    private func appendLspDiagnostics(
        toolName: String,
        args: JSONValue,
        workingDirectory: URL,
        promptText: String
    ) async -> String {
        guard let session = lspPullSession else { return promptText }

        // Notify only SearchReplace EditsApplied — Rust does not notify write
        // or apply_patch from this reminder.
        if toolName == "search_replace" || toolName == "edit",
           case .object(let fields) = args
        {
            let path =
                fields["file_path"]?.stringValue
                ?? fields["filePath"]?.stringValue
                ?? fields["path"]?.stringValue
            if let path, !path.isEmpty {
                let absolute: String
                if (path as NSString).isAbsolutePath {
                    absolute = path
                } else {
                    absolute = workingDirectory.appendingPathComponent(path).path
                }
                if let content = try? String(contentsOfFile: absolute, encoding: .utf8) {
                    await session.notifyFileChanged(path: absolute, content: content)
                }
            }
        }

        // Drain pending diagnostics from this or earlier edits (even when
        // this tool did not notify — same as the Rust reminder).
        guard let summary = await session.drainDiagnostics() else {
            return promptText
        }
        let wrapped = "<system-reminder>\n\(summary)\n</system-reminder>"
        return promptText.isEmpty ? wrapped : "\(promptText)\n\n\(wrapped)"
    }

    func shutdown() async {
        // SessionEnd fires before the session's process-bearing resources
        // come down, matching upstream (run_loop.rs:471-490 channel-closed and
        // :2216-2235 shutdown paths both fire BEFORE memory auto-save). The
        // port has no memory auto-save yet, so the ordering is preserved by
        // firing first. Payload carries the reason (event.rs:350-356); turn
        // and tool-call counts are omitted (nil) to match the fire sites.
        fireObserveHook(
            event: .sessionEnd,
            payload: ["reason": .string("shutdown")]
        )
        // The scheduler timer first: a fire delivered into a torn-down
        // controller would enqueue a cron prompt nothing can ever drain —
        // and a Detached fire would spawn a subagent into the teardown the
        // next line performs.
        await schedulerHost?.shutdown()
        // Children first: a child holds its own MCP connections and shell
        // session, and its coordinator entry must not outlive the parent's
        // tool surface.
        await subagentHost?.shutdown()
        // Monitor pipelines before the shell composition: a poll loop that
        // outlives the backend would spin against a dead process table.
        await monitorHost?.shutdown()
        await lspPullSession?.shutdown()
        await mcpConnections.shutdown()
        await composition.shutdown()
    }

    func registerSession(sessionID: String, workingDirectory: URL) async throws {
        try await composition.registerSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        await sessionDirectories.set(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
    }

    func workingDirectory(sessionID: String) async -> URL {
        await sessionDirectories.directory(
            sessionID: sessionID,
            fallback: workingDirectory
        )
    }

    /// The session's registered process execution, for TaskCompleted watching
    /// and other seams that need the live task table. `nil` when the session
    /// was never registered (no tools can have run).
    func processExecution(
        sessionID: String,
        workingDirectory: URL
    ) async -> (any OpenGrokShellProcessExecution)? {
        try? await composition.execution(
            for: sessionID,
            workingDirectory: workingDirectory
        )
    }

    /// Install (or clear) the status-chip push sink on every registered shell
    /// session execution. Shell and monitor tasks share `.shell` — one path.
    func setActiveBackgroundWorkSink(_ sink: LiveActiveBackgroundWorkSink?) async {
        await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
            sink,
            on: composition
        )
    }

    /// The session's live background tasks, for `/tasks` — the same
    /// owner-scoped `listTasks()` the background-task tools consult, read
    /// through the session's registered execution. An unregistered session
    /// returns empty truthfully: no `run_terminal_cmd` can have run through
    /// it, so no task it owns can exist.
    func backgroundTaskSnapshots(
        sessionID: String,
        workingDirectory: URL
    ) async -> [ShellTaskSnapshot] {
        guard let execution = await processExecution(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        ) else { return [] }
        return await execution.listTasks()
    }

    /// Kill one owned background task — the tasks pane's `x` affordance
    /// (B1-t), through the SAME owner-scoped execution `kill_task` uses, so
    /// the pane can never signal a task the session does not own.
    func killBackgroundTask(
        sessionID: String,
        workingDirectory: URL,
        taskID: String
    ) async -> Bool {
        guard let execution = try? await composition.execution(
            for: sessionID,
            workingDirectory: workingDirectory
        ) else { return false }
        switch await execution.killTask(taskID) {
        case .killed: return true
        case .alreadyExited, .notFound: return false
        }
    }

    private static let runTerminalTool = ToolSpec(
        name: "run_terminal_cmd",
        description: "Run a validated shell command in the workspace with bounded output and cancellable process cleanup.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to execute.")
                ]),
                "timeout_ms": .object([
                    "type": .string("integer"),
                    "description": .string("Optional timeout in milliseconds.")
                ]),
                "output_byte_limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum captured output bytes before truncation.")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Short explanation of the command.")
                ]),
                "is_background": .object([
                    "type": .string("boolean"),
                    "description": .string("Run as a background task.")
                ]),
                "environment": .object([
                    "type": .string("object"),
                    "description": .string("Optional environment variables for the command."),
                    "additionalProperties": .object([
                        "type": .string("string")
                    ])
                ])
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false)
        ])
    )
}

struct LiveRunTerminalToolRuntime: OpenGrokShellToolRuntime, Sendable {
    /// The session's subagent host, so `get_task_output` / `wait_tasks` /
    /// `kill_task` resolve subagent ids against the coordinator when the
    /// shell disowns them. `nil` in sessions without the spawn surface (and
    /// in every child session).
    let subagents: (any LiveSubagentQuerying)?

    func invoke(
        _ call: OpenGrokShellToolCall,
        using process: any OpenGrokShellProcessExecution
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        if LiveBackgroundTaskTools.canonicalName(for: call.name) != nil {
            return await LiveBackgroundTaskTools.invoke(
                name: call.name,
                args: call.args,
                process: process,
                subagents: subagents
            )
        }
        guard call.name == "run_terminal_cmd" else {
            return .failure(.unsupported("unknown tool '\(call.name)'"))
        }
        guard case .object(let object) = call.args,
              case .string(let command)? = object["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.invalidCall("run_terminal_cmd requires a non-empty command"))
        }

        let timeoutMilliseconds = Self.integer(object["timeout_ms"])
            .map { max(1, min(3_600_000, $0)) }
            ?? 30_000
        let outputByteLimit = Self.integer(object["output_byte_limit"])
            .map { max(1, min(1_000_000, $0)) }
            ?? 30_000
        let isBackground = Self.boolean(object["is_background"]) ?? false
        let description = Self.string(object["description"])
        let environment = Self.stringDictionary(object["environment"])
        let request = ShellCommandRequest(
            command: command,
            workingDirectory: process.workingDirectory,
            environment: environment,
            timeout: .milliseconds(Int64(timeoutMilliseconds)),
            outputByteLimit: outputByteLimit,
            toolCallID: call.callID,
            autoBackgroundOnTimeout: true,
            foregroundBlockBudget: .seconds(10),
            ownerSessionID: call.sessionID,
            description: description
        )

        do {
            if isBackground {
                let handle = try await process.runBackground(request)
                let value: JSONValue = .object([
                    "type": .string("background"),
                    "task_id": .string(handle.taskID),
                    "output_file": handle.outputFile.map {
                        .string($0.path)
                    } ?? .null,
                    "pid": handle.processID.map {
                        .number(.int64(Int64($0)))
                    } ?? .null
                ])
                return .success(OpenGrokShellToolCallResult(
                    value: value,
                    promptText: "Background task \(handle.taskID) started."
                ))
            }

            // Prefer the TaskLocal sink set by composition/store; keeps the
            // OpenGrokShellToolRuntime protocol 2-arg so other runtimes compile.
            let result = try await process.run(
                request,
                onOutput: OpenGrokShellToolOutputContext.onOutput
            )
            let value: JSONValue = .object([
                "type": .string(result.backgrounded ? "backgrounded" : "foreground"),
                "combined_output": .string(result.combinedOutput),
                "exit_code": result.exitCode.map {
                    .number(.int64(Int64($0)))
                } ?? .null,
                "signal": result.signal.map(JSONValue.string) ?? .null,
                "truncated": .bool(result.truncated),
                "timed_out": .bool(result.timedOut),
                "cancelled": .bool(result.cancelled),
                "output_file": result.outputFile.map {
                    .string($0.path)
                } ?? .null,
                "total_bytes": .number(.int64(Int64(result.totalBytes))),
                "pid": result.processID.map {
                    .number(.int64(Int64($0)))
                } ?? .null,
                "task_id": result.taskID.map(JSONValue.string) ?? .null
            ])
            // Nonzero exit / signal / timeout stay Result.success so promptText
            // (combined output + exit detail) is not rewritten to "Tool failed:".
            // displayState carries the failed accent for the pager.
            return .success(OpenGrokShellToolCallResult(
                value: value,
                promptText: Self.promptText(for: result),
                displayState: Self.displayState(for: result)
            ))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    func cancel(_ call: OpenGrokShellToolCall) async {
        _ = call
    }

    /// Map process terminal metadata to a card display state.
    /// Rust: `ToolOutput::Bash(b) => b.exit_code != 0` (`output.rs:727-730`).
    static func displayState(for result: ShellCommandResult) -> OpenGrokShellToolState {
        if result.cancelled {
            return .cancelled
        }
        // Auto-promoted to background is not a failure — the process is still
        // running under a task id; the tool return itself succeeded.
        if result.backgrounded {
            return .succeeded
        }
        if result.timedOut {
            return .failed
        }
        if let signal = result.signal,
           !signal.isEmpty,
           signal != "backgrounded" {
            return .failed
        }
        if let exitCode = result.exitCode, exitCode != 0 {
            return .failed
        }
        return .succeeded
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            if let integer = number.int64Value {
                return Int(exactly: integer)
            }
            if let integer = number.uint64Value {
                return Int(exactly: integer)
            }
            return nil
        case .string(let string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let boolean):
            return boolean
        case .string(let string):
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func stringDictionary(_ value: JSONValue?) -> [String: String] {
        guard case .object(let object)? = value else { return [:] }
        return object.reduce(into: [:]) { result, entry in
            if case .string(let value) = entry.value {
                result[entry.key] = value
            }
        }
    }

    private static func promptText(for result: ShellCommandResult) -> String {
        var lines: [String] = []
        if !result.combinedOutput.isEmpty {
            lines.append(result.combinedOutput)
        } else {
            lines.append("(command produced no output)")
        }
        if let exitCode = result.exitCode {
            lines.append("Exit code: \(exitCode)")
        }
        if let signal = result.signal {
            lines.append("Signal: \(signal)")
        }
        if result.timedOut {
            lines.append("The command timed out.")
        }
        if result.cancelled {
            lines.append("The command was cancelled.")
        }
        if result.truncated {
            lines.append("Output was truncated; full output: \(result.outputFile?.path ?? "unavailable")")
        }
        if let taskID = result.taskID {
            lines.append("Background task: \(taskID)")
        }
        return lines.joined(separator: "\n")
    }
}
