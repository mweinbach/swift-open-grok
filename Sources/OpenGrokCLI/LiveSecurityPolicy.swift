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


/// Rejects every prompt-requiring access with an actionable message instead of
/// hanging on a prompt no terminal is listening for.
struct LiveWriteDenialPrompter: PermissionPrompter {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        _ = toolCallId
        return .reject(LiveWriteDenialPrompter.denialMessage(
            toolName: toolName,
            access: access
        ))
    }

    /// Shell commands reach this prompter too now that `run_terminal_cmd` is
    /// gated, and "would modify files" is the wrong sentence for one — so the
    /// message names the actual access.
    static func denialMessage(toolName: String, access: AccessKind? = nil) -> String {
        let suffix = " Set OPENGROK_ALLOW_WRITES=1 to allow them."
        switch access {
        case .bash:
            return "'\(toolName)' needs approval to run a shell command, and no "
                + "approval prompt is available in this session." + suffix
        case .edit, .none:
            return "'\(toolName)' would modify files, and file mutations are "
                + "disabled for this session." + suffix
        default:
            return "'\(toolName)' needs approval, and no approval prompt is "
                + "available in this session." + suffix
        }
    }
}

/// "Allow for the rest of the session", held outside the coordinator so a
/// second access never re-prompts once the user has said yes.
///
/// Scoped per access kind. A single `allowsAll` flag meant that approving one
/// file edit also pre-approved every later edit *and*, now that shell is gated,
/// every later shell command — which is not what "allow for this session" on a
/// write prompt says. Bash grants are held per command prefix, matching the
/// `bashPrefixGrants` the permission engine already models.
actor LiveSessionWritePolicy {
    private var allowsEdits = false
    private var bashPrefixGrants: [String] = []
    private var otherGrants: Set<String> = []

    init() {}

    func isAllowed(_ access: AccessKind) -> Bool {
        switch access {
        case .edit:
            return allowsEdits
        case .bash(let command):
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            return bashPrefixGrants.contains { !$0.isEmpty && trimmed.hasPrefix($0) }
        case .read, .grep, .webSearch:
            return true
        case .webFetch(let url):
            return otherGrants.contains(url)
        case .mcpTool(let name, _):
            return otherGrants.contains(name)
        }
    }

    func allowForSession(_ access: AccessKind) {
        switch access {
        case .edit:
            allowsEdits = true
        case .bash(let command):
            // Grant the whole command as its own prefix: a session grant for
            // `npm test` must not also cover `npm publish`.
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { bashPrefixGrants.append(trimmed) }
        case .webFetch(let url):
            otherGrants.insert(url)
        case .mcpTool(let name, _):
            otherGrants.insert(name)
        case .read, .grep, .webSearch:
            break
        }
    }
}

/// Routes a mutation through the pager's permission sheet.
///
/// Fails closed when no presenter is installed — headless runs, non-TTY pipes,
/// and the window after teardown — so a tool can never suspend on a modal that
/// will not be drawn.
struct LivePermissionModalPrompter: PermissionPrompter {
    let coordinator: PagerPermissionCoordinator
    let sessionPolicy: LiveSessionWritePolicy

    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        if await sessionPolicy.isAllowed(access) { return .allow }
        guard await coordinator.hasPresenter else {
            return .reject(LiveWriteDenialPrompter.denialMessage(
                toolName: toolName,
                access: access
            ))
        }
        let request = PagerPermissionRequest(
            id: toolCallId.isEmpty ? UUID().uuidString : toolCallId,
            toolName: toolName,
            targetPath: Self.targetPath(for: access),
            detail: Self.detail(for: access)
        )
        switch await coordinator.decision(for: request) {
        case .allowOnce:
            return .allow
        case .allowSession:
            await sessionPolicy.allowForSession(access)
            return .allow
        case .deny:
            return .reject("'\(toolName)' was denied.")
        }
    }

    /// Second line of the sheet.
    ///
    /// For a protected edit target this is the reason that edit is dangerous —
    /// `.opengrok/hooks/**`, `.claude/settings.json`, a shell startup file and
    /// the rest all install something that runs later without a separate
    /// execution approval, and the user cannot weigh the prompt without being
    /// told that. The classifier existed but returned a bare `Bool`, so the
    /// explanation never reached anyone.
    private static func detail(for access: AccessKind) -> String? {
        guard case .edit(let path) = access else { return nil }
        return protectedEditReason(path, userGrokHome: userGrokHome()?.path)?.explanation
    }

    private static func targetPath(for access: AccessKind) -> String? {
        switch access {
        case .edit(let path):
            return path
        case .read(let path):
            return path
        case .grep(let path, _):
            return path
        case .bash(let command):
            return command
        case .webFetch(let url):
            return url
        case .webSearch(let query):
            return query
        case .mcpTool(let name, _):
            return name
        }
    }
}

/// Config, folder trust, and the permission policy for one session, resolved
/// together because each depends on the one before it.
///
/// Before this existed the live path called `loadEffectiveConfigDiskOnly`,
/// which merges only systemManaged → managed → user → requirements: a repo's
/// `.opengrok/config.toml` was silently dropped, and nothing read `[permission]`
/// at all, so the rule engine ran over an empty policy.
struct LiveSecurityContext: Sendable {
    /// Full authority chain: built-ins < user < project < env < CLI + managed.
    var document: TOMLValue
    /// Whether this workspace may load repo-local code-exec config.
    var projectTrusted: Bool
    var permissions: ResolvedPermissions
    /// Requirements layers, kept so the sandbox can apply the same admin
    /// precedence the permission resolver did.
    var requirements: [TOMLValue]

    /// Resolve for `workspaceRoot`.
    ///
    /// Folder trust is decided **first** and gates the project tier: an
    /// untrusted repo's `.opengrok/config.toml` never enters the merge, so it
    /// can neither declare MCP servers nor widen its own permission rules.
    static func resolve(
        workspaceRoot: URL,
        environment: [String: String],
        isInteractive: Bool,
        // `--allow` / `--deny` / `--permission-mode` / `--always-approve` /
        // `--trust`, parsed by the root CLI parser. This is the tier that lets
        // a scripted user authorize a command through the supported path
        // instead of an environment-variable bypass.
        cli: CLIPermissionOptions = CLIPermissionOptions()
    ) -> LiveSecurityContext {
        // One disk load, reused for the trust flag, the merge and the sandbox.
        let layers = try? ConfigLayers.load(environment: environment)
        // The base chain without the project tier, used to read the folder
        // trust feature flag itself — a repo must not be able to switch off
        // the gate that is deciding whether to read it.
        let base = layers?.effectiveConfigBase() ?? .table(TOMLTable())

        let featureEnabled = folderTrustEnabled(document: base, environment: environment)
        let store = PersistentFolderTrustStore(environment: environment)
        let outcome = decideFolderTrust(
            featureEnabled: featureEnabled,
            inputs: FolderTrustDecideInputs(
                storeTrusted: store.isTrusted(workspaceRoot),
                repoConfigsPresent: repoConfigsPresent(at: workspaceRoot),
                isInteractive: isInteractive,
                keyRecordable: !isUnsafeTrustRoot(
                    workspaceRoot.path,
                    home: environment["HOME"]
                )
            )
        )
        // `.prompt` is "not yet decided". Until the pager can raise a trust
        // sheet, an undecided folder is treated as untrusted — the failure mode
        // is a repo whose servers do not start, not one whose servers run.
        // `--trust` is the explicit answer to that undecided case.
        let projectTrusted = outcome == .trusted || cli.trustFolder

        // Passing `cwd: nil` for an untrusted folder is the whole gate: the
        // project chain is never discovered, so its MCP servers, hooks and
        // permission rules cannot enter the merged document.
        let project: TOMLValue = projectTrusted
            ? loadMergedProjectConfig(
                cwd: workspaceRoot,
                userHome: userGrokHome(environment: environment),
                environment: environment
            )
            : .table(TOMLTable())
        let document = layers.map {
            AuthorityComposition.from(layers: $0, project: project).effective()
        } ?? base

        let requirements = [
            layers?.userRequirements,
            layers?.systemRequirements,
            layers?.mdmRequirements,
        ].compactMap { $0 }

        let home = URL(
            fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()
        )
        // Each `[permission]` layer is passed separately with its own trust
        // tier, never as the merged document: `deepMergeTOML` replaces arrays,
        // so a user `config.toml` deny list would otherwise overwrite the
        // managed one instead of adding to it. Tiering matters too — only
        // system requirements and managed settings are admin tier, so a
        // *user's* requirements.toml cannot smuggle a catch-all allow past the
        // YOLO pin.
        var permissionLayers: [(document: TOMLValue, source: PermissionRuleSource)] = []
        if let systemRequirements = layers?.systemRequirements {
            permissionLayers.append((systemRequirements, .systemRequirements))
        }
        if let mdmRequirements = layers?.mdmRequirements {
            permissionLayers.append((mdmRequirements, .systemRequirements))
        }
        if let userRequirements = layers?.userRequirements {
            permissionLayers.append((userRequirements, .requirements))
        }
        if let systemManaged = layers?.systemManaged {
            permissionLayers.append((systemManaged, .managedConfig))
        }
        if let managed = layers?.managed {
            permissionLayers.append((managed, .managedConfig))
        }
        if let user = layers?.user {
            permissionLayers.append((user, .config))
        }
        // Absent entirely when the folder is untrusted.
        if projectTrusted {
            permissionLayers.append((project, .config))
        }

        let permissions = resolvePermissions(PermissionResolutionInputs(
            permissionLayers: permissionLayers,
            requirementsLayers: requirements,
            managedSettings: loadManagedSettingsPermissions(environment: environment),
            cwd: workspaceRoot,
            home: home,
            projectTrusted: projectTrusted,
            cliAllowRules: cli.allowRules,
            cliDenyRules: cli.denyRules,
            cliMode: cli.mode.map { DefaultPermissionMode(parsing: $0.rawValue) },
            cliAlwaysApprove: cli.alwaysApprove
        ))

        return LiveSecurityContext(
            document: document,
            projectTrusted: projectTrusted,
            permissions: permissions,
            requirements: requirements
        )
    }

    /// Apply the configured OS sandbox, if any.
    ///
    /// Returns the profile name to persist with the session so a resume cannot
    /// silently come back weaker. Throws `SandboxError` when a profile was
    /// requested and could not be enforced — never degrades silently.
    func applySandbox(
        workspaceRoot: URL,
        cliProfile: String?,
        persistedProfile: String?,
        environment: [String: String],
        runtime: (any LiveSandboxRuntime)? = nil
    ) throws -> LiveSandboxDecision {
        if let runtime {
            return try LiveSandboxComposition.bootstrap(
                workspaceRoot: workspaceRoot,
                document: document,
                requirements: requirements,
                cliProfile: cliProfile,
                persistedProfile: persistedProfile,
                environment: environment,
                runtime: runtime
            )
        }
        return try LiveSandboxComposition.bootstrap(
            workspaceRoot: workspaceRoot,
            document: document,
            requirements: requirements,
            cliProfile: cliProfile,
            persistedProfile: persistedProfile,
            environment: environment
        )
    }

    /// Vendor `managed-settings.json` — admin tier, so it is read regardless of
    /// folder trust.
    private static func loadManagedSettingsPermissions(
        environment: [String: String]
    ) -> ClaudeSettingsPermissions? {
        _ = environment
        guard let path = claudeManagedSettingsPath(),
              let data = try? Data(contentsOf: path) else { return nil }
        return parseClaudeSettingsJSON(data)
    }
}

/// Runtime permission-mode control for the live pager session.
///
/// Mutates the session's `PermissionPipeline` handle — the same one
/// `FileToolSession.makePipeline` wired — so deny rules still win over
/// always-approve (`PermissionManager.request` evaluates policy before yolo;
/// `FileToolSession.swift:104-124`).
actor LiveSessionPermissionMode {
    enum DisplayMode: String, Sendable, Equatable {
        case ask
        case auto
        case alwaysApprove = "always-approve"
    }

    private let pipeline: PermissionPipeline
    private let yoloPinReason: String?
    private(set) var displayMode: DisplayMode
    /// Optional installer for the LLM side-query when entering `.auto`.
    private var autoModeInstaller: (@Sendable () async -> Void)?
    private var autoModeUninstaller: (@Sendable () async -> Void)?

    init(pipeline: PermissionPipeline, resolved: ResolvedPermissions) {
        self.pipeline = pipeline
        self.yoloPinReason = resolved.yoloPinReason
        if resolved.alwaysApprove, resolved.yoloPinReason == nil {
            displayMode = .alwaysApprove
        } else {
            displayMode = .ask
        }
    }

    func setAutoModeHooks(
        install: @escaping @Sendable () async -> Void,
        uninstall: @escaping @Sendable () async -> Void
    ) {
        autoModeInstaller = install
        autoModeUninstaller = uninstall
    }

    func permissionModeLabel() -> String { displayMode.rawValue }

    func composerFlags() -> [PagerComposerFlag] {
        switch displayMode {
        case .alwaysApprove, .auto:
            return [PagerComposerFlag(label: displayMode.rawValue)]
        case .ask:
            return []
        }
    }

    /// Toggle always-approve (`Ctrl+O`, upstream `dispatch_toggle_yolo`).
    func toggleAlwaysApprove() async -> String? {
        if displayMode != .alwaysApprove, let yoloPinReason {
            return yoloPinReason
        }
        let enabling = displayMode != .alwaysApprove
        await apply(enabling ? .alwaysApprove : .ask)
        return enabling
            ? "\u{26A0} Always-approve ON: all tool actions auto-run"
            : "\u{2713} Always-approve off"
    }

    /// Shift+Tab cycle: ask → auto → always-approve → ask (`modes.rs` when
    /// auto is available).
    func cyclePermissionMode() async -> String? {
        switch displayMode {
        case .ask:
            await apply(.auto)
            return "Mode: Auto"
        case .auto:
            if let yoloPinReason { return yoloPinReason }
            await apply(.alwaysApprove)
            return "Mode: Always-Approve"
        case .alwaysApprove:
            await apply(.ask)
            return "Mode: Normal"
        }
    }

    /// Settings / ACP explicit permission_mode set.
    func applyPermissionMode(_ mode: DisplayMode) async -> String? {
        if mode == .alwaysApprove, yoloPinReason != nil {
            return yoloPinReason
        }
        await apply(mode)
        return nil
    }

    /// The inbound `x.ai/yolo_mode_changed` arm (acp_agent.rs:4486-4513):
    /// an explicit set rather than a toggle, pin-gated the same way the
    /// Ctrl+O toggle is — a pinned enable is refused BEFORE the display mode
    /// moves, so the composer flag can never claim an always-approve the
    /// clamped `PermissionHandle` refused (the manager-side clamp upstream
    /// leans on, run_loop.rs:1093-1105).
    func applyInboundAlwaysApprove(_ enabled: Bool) async {
        if enabled, yoloPinReason != nil { return }
        await apply(enabled ? .alwaysApprove : .ask)
    }

    private func apply(_ newMode: DisplayMode) async {
        let previous = displayMode
        displayMode = newMode
        switch newMode {
        case .ask:
            // Leaving `.auto` without an uninstall hook must still clear the
            // pipeline flag — ACP/tests install no hooks and would otherwise
            // leave `autoMode` stuck true (silent ask UI, live auto gate).
            if previous == .auto, let autoModeUninstaller {
                await autoModeUninstaller()
            } else {
                await pipeline.permissions.setYoloMode(false)
                await pipeline.permissions.setAutoMode(false)
            }
        case .auto:
            await pipeline.permissions.setYoloMode(false)
            if let autoModeInstaller {
                await autoModeInstaller()
            } else {
                await pipeline.permissions.setAutoMode(true)
            }
        case .alwaysApprove:
            if previous == .auto, let autoModeUninstaller {
                await autoModeUninstaller()
            }
            await pipeline.permissions.setAutoMode(false)
            await pipeline.permissions.setYoloMode(true)
        }
    }
}

actor LiveSessionDirectoryRegistry {
    private var directories: [String: URL]

    init(sessionID: String, workingDirectory: URL) {
        directories = [sessionID: workingDirectory.standardizedFileURL]
    }

    func set(sessionID: String, workingDirectory: URL) {
        directories[sessionID] = workingDirectory.standardizedFileURL
    }

    func directory(sessionID: String, fallback: URL) -> URL {
        directories[sessionID] ?? fallback.standardizedFileURL
    }
}

