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


struct LiveConversationRecord: Codable, Sendable, Equatable {
    var sessionID: String
    var workingDirectory: String
    var parentSessionID: String?
    var createdAt: Date
    var updatedAt: Date
    var items: [ConversationItem]
    var sandboxProfile: String?
    var currentModelID: String?
    var currentProvider: ModelProvider?
    var everUsedNonXAI: Bool?
    /// User-chosen session title (`/rename`, upstream rename.rs:42-53).
    /// `nil` means "never renamed"; readers derive a title from the first
    /// real user turn instead. Optional so records written before this field
    /// existed keep decoding unchanged.
    var title: String?

    init(
        sessionID: String,
        workingDirectory: String,
        parentSessionID: String?,
        createdAt: Date,
        updatedAt: Date,
        items: [ConversationItem],
        sandboxProfile: String? = nil,
        currentModelID: String? = nil,
        currentProvider: ModelProvider? = nil,
        everUsedNonXAI: Bool? = nil,
        title: String? = nil
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.parentSessionID = parentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
        self.sandboxProfile = sandboxProfile
        self.currentModelID = currentModelID
        self.currentProvider = currentProvider
        self.everUsedNonXAI = everUsedNonXAI
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case workingDirectory
        case parentSessionID
        case createdAt
        case updatedAt
        case items
        case sandboxProfile = "sandbox_profile"
        case currentModelID = "current_model_id"
        case currentProvider = "current_provider"
        case everUsedNonXAI = "ever_used_codex"
        case title
    }

    static func new(
        sessionID: String,
        workingDirectory: URL,
        sandboxProfile: String? = nil
    ) -> LiveConversationRecord {
        let now = Date()
        return LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: nil,
            createdAt: now,
            updatedAt: now,
            items: [],
            sandboxProfile: sandboxProfile,
            currentModelID: nil,
            currentProvider: nil,
            everUsedNonXAI: false
        )
    }
}

actor LiveConversationStore {
    private let sessionsDirectory: URL
    private let fileManager: FileManager

    init(openGrokHome: URL, fileManager: FileManager = .default) {
        self.sessionsDirectory = openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    static func validateSessionID(_ sessionID: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !sessionID.isEmpty,
              sessionID.count <= 128,
              sessionID != ".",
              sessionID != "..",
              sessionID.allSatisfy(allowed.contains)
        else {
            throw CLIApplicationError.failed("invalid session ID: \(sessionID)")
        }
    }

    func load(sessionID: String) throws -> LiveConversationRecord {
        guard let record = try loadIfPresent(sessionID: sessionID) else {
            throw CLIApplicationError.failed("session not found: \(sessionID)")
        }
        return record
    }

    func loadIfPresent(sessionID: String) throws -> LiveConversationRecord? {
        try Self.validateSessionID(sessionID)
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(LiveConversationRecord.self, from: data)
            guard record.sessionID == sessionID else {
                throw CLIApplicationError.failed("session file ID mismatch: \(sessionID)")
            }
            return record
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("failed to load session \(sessionID): \(error)")
        }
    }

    func latest(workingDirectory: URL) throws -> LiveConversationRecord? {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return nil }
        let expectedDirectory = workingDirectory.standardizedFileURL.path
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiveConversationRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(LiveConversationRecord.self, from: data),
                      URL(fileURLWithPath: record.workingDirectory).standardizedFileURL.path == expectedDirectory
                else { return nil }
                return record
            }
            .max { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.sessionID < rhs.sessionID
                }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    func save(_ record: LiveConversationRecord) throws {
        try Self.validateSessionID(record.sessionID)
        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(record)
            try data.write(to: fileURL(sessionID: record.sessionID), options: .atomic)
        } catch {
            throw CLIApplicationError.failed("failed to save session \(record.sessionID): \(error)")
        }
    }

    /// `x.ai/session/rename` for a session that is NOT the live spine: load,
    /// set the stored title, persist — one actor turn, so the read-modify-
    /// write cannot interleave with another store call. Returns `false` when
    /// no such session exists. The LIVE session must rename through its
    /// `LiveConversationHistory` instead: the turn loop re-saves the whole
    /// in-memory record on every commit, so a title written here for the
    /// resident session would silently vanish at the next turn's save.
    func renameStored(sessionID: String, title: String) throws -> Bool {
        guard var record = try loadIfPresent(sessionID: sessionID) else { return false }
        record.title = title
        record.updatedAt = Date()
        try save(record)
        return true
    }

    /// Copy one session as a coupled transcript/rewind artifact transaction.
    ///
    /// The export marker and provider route are copied before the child can be
    /// launched, and a rewind sidecar is copied byte-for-byte when present so
    /// the child coordinator resumes the parent's prompt numbering and points.
    /// A legacy source is refused because its export boundary cannot be safely
    /// inherited. Any partial child artifacts are removed before the error is
    /// returned, so a failed fork never leaves a misleading session behind.
    func fork(
        sourceSessionID: String,
        destinationSessionID: String,
        workingDirectory: URL
    ) throws -> LiveConversationRecord {
        try Self.validateSessionID(sourceSessionID)
        try Self.validateSessionID(destinationSessionID)
        guard sourceSessionID != destinationSessionID else {
            throw CLIApplicationError.failed("forked session ID must differ from the source session")
        }
        guard let source = try loadIfPresent(sessionID: sourceSessionID) else {
            throw CLIApplicationError.failed("session not found: \(sourceSessionID)")
        }
        guard source.everUsedNonXAI != nil else {
            throw CLIApplicationError.failed(
                "cannot fork legacy session \(sourceSessionID): its session record has no "
                    + "ever_used_codex export-boundary marker. Resume it once with this build "
                    + "to persist the boundary before forking."
            )
        }
        guard try loadIfPresent(sessionID: destinationSessionID) == nil else {
            throw CLIApplicationError.failed("session already exists: \(destinationSessionID)")
        }

        let destinationRecordURL = fileURL(sessionID: destinationSessionID)
        let sourceRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: sourceSessionID
        )
        let destinationRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: destinationSessionID
        )
        guard !fileManager.fileExists(atPath: destinationRewindURL.path) else {
            throw CLIApplicationError.failed("rewind state already exists: \(destinationSessionID)")
        }

        let now = Date()
        let child = LiveConversationRecord(
            sessionID: destinationSessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: source.sessionID,
            createdAt: now,
            updatedAt: now,
            items: source.items,
            sandboxProfile: source.sandboxProfile,
            currentModelID: source.currentModelID,
            currentProvider: source.currentProvider,
            everUsedNonXAI: source.everUsedNonXAI,
            title: source.title
        )

        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(child).write(to: destinationRecordURL, options: .atomic)
            if fileManager.fileExists(atPath: sourceRewindURL.path) {
                let rewindBytes = try Data(contentsOf: sourceRewindURL)
                try rewindBytes.write(to: destinationRewindURL, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: destinationRecordURL)
            try? fileManager.removeItem(at: destinationRewindURL)
            throw CLIApplicationError.failed(
                "failed to fork session \(sourceSessionID) as \(destinationSessionID): \(error)"
            )
        }
        return child
    }

    private func fileURL(sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID).appendingPathExtension("json")
    }
}

struct LiveAgentProfile: Sendable, Equatable {
    let model: String?
    let systemPrompt: String?
    let toolPolicy: LiveAgentToolPolicy
    let discoverSkills: Bool
}

struct LiveAgentToolPolicy: Sendable, Equatable {
    let configuredTools: [String]
    let allowlist: [String]
    let denylist: [String]
    let sessionAllowlist: [String]?
    let sessionDenylist: [String]
    let capabilityMode: AgentCapabilityMode?

    init(definition: AgentDefinition) {
        configuredTools = definition.toolConfig.toolNames
        allowlist = definition.tools
        denylist = definition.disallowedTools
        sessionAllowlist = definition.sessionToolsAllowlist
        sessionDenylist = definition.sessionToolsDenylist ?? []
        capabilityMode = definition.capabilityMode
    }

    private init(
        configuredTools: [String],
        allowlist: [String],
        denylist: [String],
        sessionAllowlist: [String]?,
        sessionDenylist: [String],
        capabilityMode: AgentCapabilityMode?
    ) {
        self.configuredTools = configuredTools
        self.allowlist = allowlist
        self.denylist = denylist
        self.sessionAllowlist = sessionAllowlist
        self.sessionDenylist = sessionDenylist
        self.capabilityMode = capabilityMode
    }

    /// Merge CLI `--tools` / `--disallowed-tools` with an optional agent-profile
    /// policy.
    ///
    /// Merge rules (CLI wins on allowlist, unions on denylist):
    /// - `--tools` set: `configuredTools` and `allowlist` become those names
    ///   (replacing any profile allowlist — membership in `configuredTools` is
    ///   required by `allows()`, so no wildcard).
    /// - only `--disallowed-tools`: `configuredTools = ["*"]`, denylist = those
    ///   names.
    /// - both: allowlist/`configuredTools` from `--tools`, denylist from
    ///   `--disallowed-tools`.
    /// - with a profile: CLI `--tools` replaces the profile allowlist when set;
    ///   CLI disallowed unions with the profile denylist. Session lists and
    ///   capability mode stay on the profile.
    /// - neither CLI flag nor profile: `nil` (unrestricted surface).
    static func resolveLaunchPolicy(
        tools: String?,
        disallowedTools: String?,
        profile: LiveAgentToolPolicy?
    ) -> LiveAgentToolPolicy? {
        let cliTools = parseCommaSeparatedToolNames(tools)
        let cliDenied = parseCommaSeparatedToolNames(disallowedTools)
        if cliTools == nil, cliDenied == nil {
            return profile
        }

        if let profile {
            let configured: [String]
            let allow: [String]
            if let cliTools {
                configured = cliTools
                allow = cliTools
            } else {
                configured = profile.configuredTools
                allow = profile.allowlist
            }
            let denied = uniquingPreserveOrder(profile.denylist + (cliDenied ?? []))
            return LiveAgentToolPolicy(
                configuredTools: configured,
                allowlist: allow,
                denylist: denied,
                sessionAllowlist: profile.sessionAllowlist,
                sessionDenylist: profile.sessionDenylist,
                capabilityMode: profile.capabilityMode
            )
        }

        if let cliTools {
            return LiveAgentToolPolicy(
                configuredTools: cliTools,
                allowlist: cliTools,
                denylist: cliDenied ?? [],
                sessionAllowlist: nil,
                sessionDenylist: [],
                capabilityMode: nil
            )
        }
        return LiveAgentToolPolicy(
            configuredTools: [wildcard],
            allowlist: [],
            denylist: cliDenied ?? [],
            sessionAllowlist: nil,
            sessionDenylist: [],
            capabilityMode: nil
        )
    }

    /// Comma-separated tool names: trim whitespace, drop empties. `nil` input
    /// stays `nil` (flag absent); an empty/whitespace-only string yields `[]`.
    static func parseCommaSeparatedToolNames(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        return raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func uniquingPreserveOrder(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    /// A policy that constrains nothing except the capability mode.
    ///
    /// `allows(liveToolName:)` requires membership in `configuredTools`, so an
    /// "unrestricted" policy cannot express itself as an empty list — the
    /// sentinel below makes every name match instead. Used for a workflow child
    /// in a session that has no agent profile: the only thing to enforce is the
    /// clamped capability.
    init(unrestrictedWith capabilityMode: AgentCapabilityMode) {
        self.init(
            configuredTools: [Self.wildcard],
            allowlist: [],
            denylist: [],
            sessionAllowlist: nil,
            sessionDenylist: [],
            capabilityMode: capabilityMode
        )
    }

    /// The same policy with a different capability mode. Narrowing only: the
    /// caller (`LiveWorkflowLaunch.clampedPolicy`) has already clamped against
    /// the parent's mode.
    func withCapabilityMode(_ mode: AgentCapabilityMode) -> LiveAgentToolPolicy {
        LiveAgentToolPolicy(
            configuredTools: configuredTools,
            allowlist: allowlist,
            denylist: denylist,
            sessionAllowlist: sessionAllowlist,
            sessionDenylist: sessionDenylist,
            capabilityMode: mode
        )
    }

    static let wildcard = "*"

    func allows(liveToolName: String) -> Bool {
        let aliases = Self.aliases(for: liveToolName)
        guard Self.matches(configuredTools, aliases: aliases) else { return false }
        if !allowlist.isEmpty, !Self.matches(allowlist, aliases: aliases) { return false }
        if Self.matches(denylist, aliases: aliases) { return false }
        if Self.matches(sessionDenylist, aliases: aliases) { return false }
        if let sessionAllowlist, !Self.matches(sessionAllowlist, aliases: aliases) { return false }
        guard let capabilityMode else { return true }
        switch capabilityMode {
        case .readOnly, .readWrite:
            // `monitor` is upstream's process-control class alongside bash:
            // `kind_allowed` keeps `ToolKind::Monitor` only under Execute
            // and All (`xai-grok-workspace/src/capability.rs:157-160`) — it
            // starts an arbitrary command, so it is exactly as execute-
            // shaped as `run_terminal_cmd`.
            return liveToolName != "run_terminal_cmd"
                && liveToolName != LiveMonitorTools.toolName
        case .execute, .all:
            return true
        }
    }

    private static func aliases(for liveToolName: String) -> Set<String> {
        if liveToolName == "run_terminal_cmd" {
            return [liveToolName, "run_terminal_command"]
        }
        // The live surface advertises upstream's production names
        // (`xai-grok-agent/src/config.rs:161-173`); permission rules may still
        // spell either the production name or the registry alias. Without both
        // spellings here, a profile that grants `get_task_output` would
        // silently fail to match the `get_command_or_subagent_output` the
        // session advertises.
        if let alias = Self.backgroundTaskAliases[liveToolName] {
            return [liveToolName, alias]
        }
        // The spawn surface goes the other way: advertised under the
        // production name `spawn_subagent` (config.rs:152-156), matched under
        // the canonical registry id `task` as well, so a profile written
        // against either spelling gates the same surface.
        if liveToolName == LiveSubagentHost.advertisedToolName {
            return [liveToolName, "task"]
        }
        return [liveToolName]
    }

    private static let backgroundTaskAliases: [String: String] = [
        "get_command_or_subagent_output": "get_task_output",
        "wait_commands_or_subagents": "wait_tasks",
        "kill_command_or_subagent": "kill_task",
    ]

    private static func matches(_ entries: [String], aliases: Set<String>) -> Bool {
        entries.contains { entry in
            if entry == wildcard { return true }
            let shortName = entry.split(separator: ":").last.map(String.init) ?? entry
            return aliases.contains(entry) || aliases.contains(shortName)
        }
    }
}

actor LiveConversationHistory {
    private var record: LiveConversationRecord
    private let store: LiveConversationStore
    private var exportBoundary: ExportBoundary

    init(
        record: LiveConversationRecord,
        store: LiveConversationStore,
        exportBoundary: ExportBoundary? = nil
    ) {
        self.record = record
        self.store = store
        self.exportBoundary = exportBoundary ?? ExportBoundary(
            everUsedNonXAI: record.everUsedNonXAI != false
        )
    }

    var items: [ConversationItem] { record.items }

    var sessionID: String { record.sessionID }

    var sharedExportBoundary: ExportBoundary { exportBoundary }

    func snapshot() -> LiveConversationRecord { record }

    /// Switch the in-memory spine only after the replacement record is
    /// durably written. The old record remains available through the store.
    func replace(with record: LiveConversationRecord) throws {
        try LiveConversationStore.validateSessionID(record.sessionID)
        self.record = record
        self.exportBoundary = ExportBoundary(
            everUsedNonXAI: record.everUsedNonXAI != false
        )
    }

    /// Rewrite history to its provider-neutral spine ahead of a provider
    /// change, and persist the result. Returns how many items were dropped.
    ///
    /// This is destructive on purpose: the persisted session must not keep
    /// carriers the next provider would be handed on resume.
    @discardableResult
    func isolateForProviderSwitch() async throws -> Int {
        let before = record.items
        let sanitized = liveProviderNeutralHistory(before)
        guard sanitized != before else { return 0 }
        var next = record
        next.items = sanitized
        next.updatedAt = Date()
        try await store.save(next)
        record = next
        return before.count - sanitized.count
    }

    /// Persist the route before the next provider can observe replayed history.
    /// A legacy record with no route metadata is treated as unsafe when it has
    /// opaque carriers; its unknown export marker remains nil rather than being
    /// rewritten to a falsely clean value.
    @discardableResult
    func reconcileRoute(modelID: String, provider: ModelProvider) async throws -> Int {
        let before = record
        let sanitized = liveProviderNeutralHistory(before.items)
        let hasOpaqueItems = sanitized != before.items
        let routeChanged = before.currentProvider != provider
        let legacyRoute = before.currentModelID == nil || before.currentProvider == nil
        let xAIExportClosed = provider.profile.allowsXaiServices && before.everUsedNonXAI == true
        let shouldSanitize = hasOpaqueItems && (routeChanged || legacyRoute || xAIExportClosed)

        var next = before
        if shouldSanitize {
            next.items = sanitized
        }
        next.currentModelID = modelID
        next.currentProvider = provider
        if !provider.profile.allowsXaiServices {
            next.everUsedNonXAI = true
        }
        if next != before {
            next.updatedAt = Date()
        }
        try await store.save(next)
        record = next
        exportBoundary.observe(provider)
        return shouldSanitize ? before.items.count - sanitized.count : 0
    }

    func itemsForTurn(
        sessionID: String,
        prompt: String,
        schedulerFired: Bool = false
    ) -> [ConversationItem] {
        var items = sessionID == record.sessionID ? record.items : []
        // A scheduler-fired prompt persists with the turn like any user item,
        // tagged so compaction/replay/analytics see the cron turn — the port
        // of `ConversationItem::scheduler_fired` at the same seam
        // (acp_session_impl/turn.rs:858-860).
        items.append(schedulerFired ? .schedulerFired(prompt) : .user(prompt))
        return items
    }

    func commit(sessionID: String, items: [ConversationItem]) async throws {
        guard sessionID == record.sessionID else {
            throw CLIApplicationError.failed("conversation session mismatch: \(sessionID)")
        }
        record.items = items
        record.updatedAt = Date()
        try await store.save(record)
    }

    /// `/rename` (upstream rename.rs:42-53): set the session's stored title
    /// and persist it.
    ///
    /// The write goes through this actor's own record — not a second reader
    /// of the same file — because the turn loop re-saves the whole record on
    /// every commit; a title written around this actor would silently vanish
    /// at the next turn's save.
    func rename(title: String) async throws {
        record.title = title
        record.updatedAt = Date()
        try await store.save(record)
    }
}

struct LiveShellSamplingDriver: OpenGrokShellSamplingDriver, Sendable {
    /// Owns the sampler rather than holding one, so `/model` can rebuild the
    /// provider stack between turns without replacing the shell.
    let modelSwitch: LiveModelSwitchCoordinator
    let toolExecutor: LiveToolExecutor
    let conversationHistory: LiveConversationHistory
    let systemPrompt: String?
    let skillsListing: String?
    /// The tool list this session advertises. In Code Mode it carries `exec`
    /// and `wait` and, in `code_mode_only`, hides everything the cell can
    /// reach through `tools.*`.
    let toolSurface: LiveCodeModeToolSurface
    /// `nil` in `direct` mode, which leaves the turn loop byte-identical to a
    /// session that has never heard of Code Mode.
    let codeMode: LiveCodeModeCoordinator?
    /// Keeps the conversation under the model's context window. Optional only
    /// so a test can build a driver without a model catalog; a live session
    /// always has one, and without it a long session dies at the wall.
    let compaction: LiveCompactionCoordinator?
    /// Mid-turn interjection buffer, drained between sampler rounds. The
    /// producer is the subagent collaboration quartet (`LiveSubagentHost`'s
    /// root-delivery path); `/btw` stopped producing here when it became a
    /// real side question.
    let interjections: LiveSessionInterjections
    /// Headless `--max-turns` cap. `nil` means unlimited sampler rounds
    /// (subject only to the 16-round safety cap). When set, the first model
    /// call counts as turn 1; after tool results, the next sampler round is
    /// allowed only while `toolTurnCount + 1 <= limit` (turn.rs:2347,3130-3140).
    let maxTurns: UInt32?

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        // Open the rewind point around the whole turn, and close it on every
        // exit path — including a thrown error or a cancelled turn, because a
        // turn that died half-way through an edit is precisely the one worth
        // being able to undo. Awaited rather than deferred into a detached
        // task: a `Task { }` in a `defer` is unordered against the *next*
        // turn's `beginPrompt`, which would let a late close swallow the
        // following prompt's point.
        let services = toolExecutor.sessionServices
        await services?.beginPrompt(text: request.text)
        // Interjections may merge into this turn from here on — the port of
        // `current_prompt_id` becoming Some for the Interject arm's
        // running-turn check (run_loop.rs:1968-1974).
        await interjections.beginTurn()
        do {
            let result = try await sampleTurn(context: context, request: request, emit: emit)
            // Buffer left intact: entries that raced past the final drain are
            // flushed into prompt turns by the controller (run_loop.rs:432-447).
            await interjections.endTurn()
            // One-shot swarm mode (task/tool trigger) ends with the turn
            // (run_loop.rs:419 → auto_exit_turn); manual mode survives.
            await toolExecutor.swarmMode.autoExitTurn()
            await services?.endPrompt()
            return result
        } catch {
            if error is CancellationError {
                // Upstream's Cancel arm clears pending interjections — a
                // cancelled turn has nothing to inject into (run_loop.rs:989-991).
                await interjections.cancelTurn()
            } else {
                // A failed turn still flushes stranded interjections into
                // prompt turns, exactly like a completed one — upstream's
                // completion arm handles Err results too (run_loop.rs:416-447).
                await interjections.endTurn()
            }
            // The completion arm runs auto-exit for Err and cancelled
            // resolutions too: a one-shot swarm turn that died must not
            // leave the next unrelated turn in swarm mode.
            await toolExecutor.swarmMode.autoExitTurn()
            await services?.endPrompt()
            throw error
        }
    }

    private func sampleTurn(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        guard let codeMode else {
            return try await runTurn(context: context, request: request, emit: emit)
        }
        // Nested calls raise their tool cards through this turn's sink, and a
        // cancelled turn (Esc) terminates whatever cells are still running.
        await codeMode.beginTurn(emit: emit)
        do {
            let result = try await withTaskCancellationHandler {
                try await runTurn(context: context, request: request, emit: emit)
            } onCancel: {
                Task { await codeMode.cancelActiveCells() }
            }
            await codeMode.endTurn()
            return result
        } catch {
            await codeMode.cancelActiveCells()
            await codeMode.endTurn()
            throw error
        }
    }

    private func runTurn(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        // One snapshot per turn: a switch that lands mid tool loop applies to
        // the next turn, never to half of this one.
        let active = await modelSwitch.snapshot()
        let sampler = active.sampler
        var items = await conversationHistory.itemsForTurn(
            sessionID: context.sessionID,
            prompt: request.text,
            // Derived from the prompt-id prefix, exactly upstream's
            // `PromptOrigin::from_prompt_id` (session/mod.rs:126-127) — the
            // runtime adapter stamps `scheduler-fired-` on cron turns.
            schedulerFired: request.promptID.hasPrefix(
                OpenGrokPagerInteractiveController.schedulerFiredPromptIDPrefix
            )
        )
        let combinedSystemPrompt = [systemPrompt, skillsListing]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")
        if !combinedSystemPrompt.isEmpty,
           !items.contains(where: {
               if case .system = $0 { return true }
               return false
           }) {
            items.insert(.system(combinedSystemPrompt), at: 0)
        }
        // Memory is injected after the system prompt exists so it has an item
        // to splice into, and before compaction runs so the injected block
        // counts toward the budget like everything else. No-ops on every turn
        // after the first, and on a resumed session whose transcript already
        // carries a `<memory-context>` block.
        let services = toolExecutor.sessionServices
        items = await services?.injectMemoryContext(into: items, prompt: request.text) ?? items

        // Swarm mode's entire turn-behavior payload: the `<system-reminder>`
        // user items the tracker queued (run_loop.rs:676 →
        // `maybe_inject_swarm_reminder`, reminders.rs:579-593) — the exit
        // notice first, then the entry steering text, both persisted with
        // the turn like every other item. Injected before compaction so the
        // reminder counts toward the budget like everything else.
        let swarmReminders = await toolExecutor.swarmMode.takeReminders()
        if swarmReminders.exit {
            items.append(.user(wrapSystemReminder(swarmModeExitReminder)))
        }
        if swarmReminders.inject {
            items.append(.user(wrapSystemReminder(swarmModeReminder)))
        }

        // UserPromptSubmit fires once the user message is staged and before
        // the turn loop starts, matching upstream (turn.rs:919-927). Payload
        // carries the prompt text (event.rs:453-456).
        toolExecutor.fireObserveHook(
            event: .userPromptSubmit,
            promptID: request.promptID,
            payload: ["prompt": .string(request.text)]
        )

        var toolTurnCount = 1
        var toolRoundCount = 0
        var stopHookContinuations = 0
        var stopHookActive = false
        var authRetrySchedule = AuthRetrySchedule()

        do {
            while true {
                try Task.checkCancellation()
                // Mid-turn interjections land at the top of every sampler
                // round. Upstream drains right before each request is built
                // (turn.rs:2413) AND immediately after tool results land
                // (tool_calls.rs:509); in this loop those are the same point,
                // because control re-enters here after `executeToolCalls`.
                // Before compaction on purpose: the injected user item must
                // count toward the budget like everything else.
                items.append(contentsOf: await drainPendingInterjections())
                // Before every sample, not only the first: a tool round can add
                // more to the prompt than the whole preceding turn did, and the
                // request that dies at the context wall is usually the one after a
                // large tool result, not the one that opened the turn.
                items = await compactIfNeeded(items: items, emit: emit)
                var response: OpenGrokLiveSamplingResponse?
                while response == nil {
                    do {
                        response = try await sampler.sample(OpenGrokLiveSamplingRequest(
                            sessionID: context.sessionID,
                            turnID: context.turnID,
                            model: active.modelID,
                            prompt: request.text,
                            items: items,
                            tools: toolSurface.modelTools
                        )) { event in
                            switch event {
                            case .output(let text):
                                await emit(.assistantText(text))
                            case .status(let status):
                                await emit(.status(status))
                            }
                        }
                        authRetrySchedule.resetOnSuccess()
                } catch let error as SamplingError {
                    guard case .auth(_, let credential) = error else { throw error }
                    switch authRetrySchedule.onRecovered401(credential) {
                    case .unchargedResubmit:
                        await Task.yield()
                    case .backoff(_, let delaySeconds):
                        try await Task.sleep(
                            nanoseconds: UInt64(max(0, delaySeconds) * 1_000_000_000)
                        )
                    case .exhausted, .runawayGuard:
                        // Notification fires on auth-retry exhaustion, the
                        // port's analog of upstream's `RetryState::Exhausted`
                        // (hook_dispatch.rs:80-85 → `agent_error`).
                        toolExecutor.fireNotification(
                            type: "agent_error",
                            message: "authentication retries exhausted",
                            level: "error"
                        )
                        throw error
                    }
                }
                }
                guard let response else { throw CLIApplicationError.failed("sampling produced no response") }
                items.append(contentsOf: response.items)

                guard !response.toolCalls.isEmpty else {
                    try Task.checkCancellation()
                    if stopHookContinuations < 8 {
                        let stopResult = await toolExecutor.runStop(
                            promptID: request.promptID,
                            payload: [
                                "reason": .string("end_turn"),
                                "stopHookActive": .boolean(stopHookActive),
                                "lastAssistantMessage": .string(response.output),
                            ]
                        )
                        if stopResult.preventContinuation == nil,
                           stopResult.wantsContinuation {
                            stopHookContinuations += 1
                            stopHookActive = true
                            items.append(.autoContinue(formatLiveStopFeedback(stopResult)))
                            continue
                        }
                    }
                    // Pre-completion drain (turn.rs:2956-2959): an
                    // interjection that arrived during the final sampler
                    // round gets one more round instead of missing the turn.
                    let preCompletion = await drainPendingInterjections()
                    if !preCompletion.isEmpty {
                        items.append(contentsOf: preCompletion)
                        continue
                    }
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                    // Late drain during turn-end bookkeeping
                    // (turn.rs:2968-2973): the commit above is this port's
                    // `finalize_turn_bookkeeping`, and an interjection that
                    // landed during it still merges into THIS turn. The next
                    // commit re-saves the record with the extra items.
                    let late = await drainPendingInterjections()
                    if !late.isEmpty {
                        items.append(contentsOf: late)
                        continue
                    }
                    return OpenGrokShellSamplingResult(
                        output: response.output,
                        stopReason: response.stopReason
                    )
                }
                guard toolRoundCount < 16 else {
                    throw CLIApplicationError.failed(
                        "tool loop exceeded 16 rounds"
                    )
                }
                toolRoundCount += 1
                items.append(contentsOf: try await executeToolCalls(
                    response.toolCalls,
                    sessionID: context.sessionID,
                    emit: emit
                ))
                let nextTurn = toolTurnCount + 1
                if let limit = maxTurns, nextTurn > limit {
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                    return OpenGrokShellSamplingResult(
                        output: response.output,
                        stopReason: "max_turns_reached"
                    )
                }
                toolTurnCount = nextTurn
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // StopFailure fires when the turn ends due to an API/turn error
            // rather than a genuine stop, matching upstream (turn.rs:1224-1234).
            // Payload carries the error class, details, and the rendered
            // message (event.rs:376-387). A cancellation is not a failure and
            // is rethrown without firing.
            toolExecutor.fireObserveHook(
                event: .stopFailure,
                promptID: request.promptID,
                payload: [
                    "error": .string(stopFailureKind(for: error)),
                    "errorDetails": .string(String(describing: error)),
                    "lastAssistantMessage": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }

    /// Map a thrown turn error to upstream's `StopFailureKind` snake_case
    /// token (event.rs:294-301). The port does not classify every provider
    /// error yet, so unknown errors map to `unknown` rather than guessing.
    private func stopFailureKind(for error: Error) -> String {
        if error is CancellationError { return "unknown" }
        if let sampling = error as? SamplingError {
            switch sampling {
            case .auth: return "authentication_failed"
            case .api(let status, _, _, _, _, _):
                return status.code == 429 ? "rate_limit" : "server_error"
            default: return "unknown"
            }
        }
        return "unknown"
    }

    /// Drain all pending interjections into synthetic user items — the port
    /// of `drain_pending_interjections` (interjection.rs:290-338): FIFO, one
    /// item per entry, never merged, never appended to tool results, each
    /// wrapped by the shared `formatInterjection` and tagged
    /// `syntheticReason: .interjection` so compaction, replay, and analytics
    /// see the steering text as its own user turn.
    ///
    /// Deliberately narrower than upstream, both recorded divergences:
    /// upstream's image-placeholder sanitizer (interjection.rs:304-305) has
    /// nothing to strip here — this port's interjection path carries no
    /// image placeholders — and the `<skill_information>` expansion for
    /// `/skill` interjections (interjection.rs:239-279) is unported, so a
    /// slash-prefixed interjection reaches the model as bare text.
    private func drainPendingInterjections() async -> [ConversationItem] {
        await interjections.drainAll().map { entry in
            .interjection(formatInterjection(entry.text))
        }
    }

    /// Keep the prompt under the model's context window, reporting what it did.
    ///
    /// Never throws. A session that cannot compact still gets to take its turn
    /// and see the provider's own error — dying here would replace a
    /// recoverable "too long" with an unrecoverable one, which is the failure
    /// this whole path exists to remove.
    private func compactIfNeeded(
        items: [ConversationItem],
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async -> [ConversationItem] {
        guard let compaction else { return items }
        // No status for the check itself: it runs before every sample, so
        // announcing it would put a line on the status bar for a token count
        // that almost always comes back under the threshold. `willCompact`
        // fires only once the coordinator has decided, which is what makes
        // "Compacting…" true whenever it is on screen. It is the third
        // turn-status label, beside "Thinking…" and "Responding…", matching
        // upstream's `TurnActivity::AutoCompacting` (`views/turn_status.rs:704`)
        // — same ellipsis character, and the renderer already gives a
        // `.status(text)` the spinner and the phase timer.
        switch await compaction.compactIfNeeded(items: items, willCompact: {
            // PreCompact fires once the coordinator has decided to compact
            // and before the work begins, matching upstream (compaction.rs:1488).
            // The automatic path's source is "auto" (event.rs:493-496).
            toolExecutor.fireObserveHook(
                event: .preCompact,
                payload: ["source": .string("auto")]
            )
            await emit(.status("Compacting\u{2026}"))
        }) {
        case .notNeeded:
            return items
        case .unableToCompact(let reason):
            await emit(.status("could not compact the conversation: \(reason)"))
            return items
        case .compacted(let replacement, let report):
            // PostCompact fires after a successful compaction, matching
            // upstream (compaction.rs:1081-1089). Source is "auto" here.
            toolExecutor.fireObserveHook(
                event: .postCompact,
                payload: ["source": .string("auto")]
            )
            await emit(.status(report.notice))
            return replacement
        }
    }

    /// Byte-identical copy of the exclusive-batch refusal
    /// (tool_calls.rs:460).
    static let swarmExclusiveBatchError =
        "`agent_swarm` must be the only tool call in its batch. Inspect briefly, "
        + "then make one exclusive agent_swarm call for independent work; use "
        + "ordinary task calls for heterogeneous small work."

    private func executeToolCalls(
        _ calls: [ToolCall],
        sessionID: String,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> [ConversationItem] {
        // Feed the auto-mode classifier the recent conversation (Rust refreshes
        // classifier turns before tool batches — tool_calls.rs:1618-1622).
        if let permissions = await toolExecutor.permissionHandle() {
            let transcript = LiveAutoModeComposition.transcript(
                from: await conversationHistory.items
            )
            await permissions.setClassifierTranscript(transcript)
        }
        // `agent_swarm` must be the only call in its batch
        // (tool_calls.rs:456-468): every call in a violating batch gets the
        // fixed refusal as its tool result and nothing executes.
        let swarmCall = calls.contains { $0.name == LiveSubagentHost.swarmToolName }
        if swarmCall, calls.count != 1 {
            return calls.map {
                ConversationItem.toolResult(ToolResultItem(
                    toolCallId: $0.callId,
                    content: Self.swarmExclusiveBatchError
                ))
            }
        }
        if swarmCall {
            // A swarm call while the mode is off enters it with the `tool`
            // trigger (tool_calls.rs:469-475): no reminder is queued — the
            // model already made the call the reminder exists to elicit —
            // and the mode auto-exits at the turn boundary.
            if await !toolExecutor.swarmMode.enabled {
                await toolExecutor.swarmMode.enter(.tool)
            }
        }

        // `exec` and `wait` are transport, not tools: they raise no card and
        // never announce themselves, so the transcript shows only the nested
        // calls the cell made (turn.rs:1998). They also mutate one runtime, so
        // they run in order rather than joining the parallel group.
        var transportResults: [Int: ToolResultItem] = [:]
        if let codeMode {
            for (index, call) in calls.enumerated() where codeMode.isTransportCall(call) {
                try Task.checkCancellation()
                transportResults[index] = await codeMode.handleTransportCall(call)
            }
        }
        let dispatched = calls.enumerated().filter { transportResults[$0.offset] == nil }

        for (_, call) in dispatched {
            try Task.checkCancellation()
            await emit(.tool(OpenGrokShellToolUpdate(
                callID: call.callId,
                name: call.name,
                input: call.arguments,
                state: .running
            )))
            await emit(.status("running tool \(call.name)"))
        }

        let workingDirectory = await toolExecutor.workingDirectory(sessionID: sessionID)
        return try await withThrowingTaskGroup(
            of: (Int, ToolResultItem).self,
            returning: [ConversationItem].self
        ) { group in
            for (index, call) in dispatched {
                group.addTask {
                    let result = await toolExecutor.invoke(
                        sessionID: sessionID,
                        workingDirectory: workingDirectory,
                        call: call
                    )
                    let content: String
                    switch result {
                    case .success(let result):
                        content = result.promptText
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .succeeded
                        )))
                        await emit(.status("tool \(call.name) completed"))
                        toolExecutor.firePostToolUse(call: call, result: result)
                    case .failure(.cancelled):
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: "Cancelled",
                            state: .cancelled
                        )))
                        throw CancellationError()
                    case .failure(.denied):
                        // The pipeline refused to authorize the call, so the
                        // tool never ran. `PermissionDenied` already fired at
                        // the gate; `PostToolUseFailure` is for a tool that
                        // executed and errored, so it must not fire here.
                        content = "Tool \(call.name) was not executed: denied"
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .failed
                        )))
                        await emit(.status("tool \(call.name) denied"))
                    case .failure(let error):
                        content = "Tool \(call.name) failed: \(error.description)"
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .failed
                        )))
                        await emit(.status("tool \(call.name) failed"))
                        toolExecutor.firePostToolUseFailure(call: call, error: error)
                    }
                    return (index, ToolResultItem(
                        toolCallId: call.callId,
                        content: content
                    ))
                }
            }

            var orderedResults = Array<ToolResultItem?>(repeating: nil, count: calls.count)
            for (index, result) in transportResults {
                orderedResults[index] = result
            }
            for try await (index, result) in group {
                orderedResults[index] = result
            }
            return orderedResults.compactMap { result in
                result.map(ConversationItem.toolResult)
            }
        }
    }

}
