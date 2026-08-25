// PermissionManager.swift
//
// Permission request pipeline: policy → YOLO/auto → grants → prompt.
// Ported conceptually from `xai-grok-workspace/src/permission/manager.rs`
// without the full actor runtime (session wiring lands later).

import Foundation
import OpenGrokConfig
import OpenGrokShared

/// Resolved once: `protectedEditPath` needs it on every edit request, and the
/// answer cannot change within a process.
let userGrokHomePath: String? = userGrokHome()?.path

private let sessionShellExecVehicleHeads: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "fish", "pwsh", "powershell", "cmd",
    "deno", "bun", "julia", "rscript", "awk", "gawk", "mawk", "nawk",
    "nodejs", "luajit", "phpdbg", "php-cgi", "pythonw",
    "npx", "bunx", "pipx", "uvx", "uv",
    "xargs", "find", "sudo", "doas", "su", "ssh", "watch", "setsid",
    "flock", "chroot", "nsenter", "docker", "podman",
    "env", "timeout", "nice", "ionice", "chrt", "stdbuf", "nohup",
    "command", "builtin", "exec", "eval", "source", ".", "busybox",
    "export", "set", "unset", "declare", "typeset", "readonly",
    "script", "setpriv", "unshare", "systemd-run", "taskset", "prlimit",
]

private func sessionShellProgramHead(_ word: String) -> String {
    let component = word.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
    let lowered = component.map(String.init)?.lowercased() ?? word.lowercased()
    return lowered.hasSuffix(".exe") ? String(lowered.dropLast(4)) : lowered
}

private func sessionShellHeadExecutesCode(_ head: String) -> Bool {
    if sessionShellExecVehicleHeads.contains(head) { return true }
    for family in ["python", "node", "ruby", "perl", "php", "lua"] {
        guard head.hasPrefix(family) else { continue }
        let suffix = String(head.dropFirst(family.count))
        let version = suffix.hasSuffix("t") ? String(suffix.dropLast()) : suffix
        if version.allSatisfy({ $0 == "." || $0.wholeNumberValue != nil }) {
            return true
        }
    }
    return false
}

private func sessionShellGrantWords(_ script: String) -> [String]? {
    let normalized = script.trimmingCharacters(in: .whitespaces)
    guard !normalized.isEmpty,
          let segments = allCommandsFromScript(normalized),
          segments.count == 1
    else {
        return nil
    }

    var words: [String] = []
    var current = ""
    var startedWord = false
    var inSingleQuote = false
    var inDoubleQuote = false
    var escaped = false

    for character in normalized {
        if character.isNewline { return nil }
        if escaped {
            current.append(character)
            startedWord = true
            escaped = false
            continue
        }
        if character == "\\" && !inSingleQuote {
            startedWord = true
            escaped = true
            continue
        }
        if character == "'" && !inDoubleQuote {
            startedWord = true
            inSingleQuote.toggle()
            continue
        }
        if character == "\"" && !inSingleQuote {
            startedWord = true
            inDoubleQuote.toggle()
            continue
        }
        if character == "$" && !inSingleQuote { return nil }
        if character == "`" { return nil }
        if !inSingleQuote && !inDoubleQuote {
            if ";|&<>()*?[]{}".contains(character) { return nil }
            if character.isWhitespace {
                if startedWord {
                    words.append(current)
                    current = ""
                    startedWord = false
                }
                continue
            }
        }
        current.append(character)
        startedWord = true
    }

    guard !escaped, !inSingleQuote, !inDoubleQuote else { return nil }
    if startedWord { words.append(current) }
    guard let program = words.first,
          !program.isEmpty,
          !isEnvAssignment(program),
          words.filter({ !$0.isEmpty }) == segments[0]
    else {
        return nil
    }

    let head = sessionShellProgramHead(program)
    var normalizedWords = words
    normalizedWords[0] = head
    guard !isDangerousCommandWords(normalizedWords),
          !sessionShellHeadExecutesCode(head),
          !(head == "rg" && rgHasPreFlag(words)),
          !(head == "git" && words.dropFirst().first?.hasPrefix("-") == true)
    else {
        return nil
    }
    return words
}

/// Replay only a benign, single-command shell approval without widening argv.
///
/// Rust bash_grants.rs:38-65 and 78-101 permits exact dangerous-script replay;
/// this live seam is deliberately stricter: dangerous commands, executable
/// wrappers, redirects, expansions, assignments, and chains always prompt again.
public func matchesSessionBashGrant(_ command: String, grant: String) -> Bool {
    guard let commandWords = sessionShellGrantWords(command),
          let grantWords = sessionShellGrantWords(grant)
    else {
        return false
    }

    let normalizedCommand = command.trimmingCharacters(in: .whitespaces)
    let normalizedGrant = grant.trimmingCharacters(in: .whitespaces)
    if normalizedCommand == normalizedGrant { return true }

    let joinedGrant = grantWords.joined(separator: " ")
    guard sessionShellGrantWords(joinedGrant) == grantWords,
          commandWords.starts(with: grantWords)
    else {
        return false
    }
    return matchesCommandPrefix(commandWords.joined(separator: " "), pattern: joinedGrant)
}

private func securityNormalizedShellCommand(_ command: String) -> String {
    command
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

/// Trusted permission-prompt settings resolved once for one live session.
///
/// Requirement pins outrank inherited environment and effective configuration.
/// Unknown cursor values select allow-once: this port has no separately
/// authorized global always-approve row to safely preselect.
public struct PermissionPromptSettings: Sendable, Equatable {
    public var rememberToolApprovals: Bool
    public var defaultSelectedPermission: String

    public init(
        rememberToolApprovals: Bool = false,
        defaultSelectedPermission: String = "allow_once"
    ) {
        self.rememberToolApprovals = rememberToolApprovals
        self.defaultSelectedPermission = Self.canonicalDefaultSelection(
            defaultSelectedPermission
        ) ?? "allow_once"
    }

    public static func resolve(
        document: TOMLValue?,
        requirements: [TOMLValue] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        remoteRememberToolApprovals: Bool? = nil
    ) -> PermissionPromptSettings {
        let rememberPath = ["ui", "remember_tool_approvals"]
        let remember: Bool
        if let requirement = requirements.lazy.compactMap({ $0[path: rememberPath] }).first {
            remember = requirement.boolValue ?? false
        } else if let configured = envBool(
            "GROK_REMEMBER_TOOL_APPROVALS",
            environment: environment
        ) {
            remember = configured
        } else if let configured = document?[path: rememberPath] {
            remember = configured.boolValue ?? false
        } else {
            remember = remoteRememberToolApprovals ?? false
        }

        let selectedPath = ["ui", "default_selected_permission"]
        let selected: String
        if let requirement = requirements.lazy.compactMap({ $0[path: selectedPath] }).first {
            selected = requirement.stringValue.flatMap(canonicalDefaultSelection) ?? "allow_once"
        } else if let override = environment["GROK_DEFAULT_SELECTED_PERMISSION"],
                  let canonical = canonicalDefaultSelection(override) {
            selected = canonical
        } else {
            selected = document?[path: selectedPath]?.stringValue
                .flatMap(canonicalDefaultSelection) ?? "allow_once"
        }

        return PermissionPromptSettings(
            rememberToolApprovals: remember,
            defaultSelectedPermission: selected
        )
    }

    private static func canonicalDefaultSelection(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "allow_once":
            return "allow_once"
        case "allow_command_always":
            return "allow_command_always"
        case "always_allow_all_sessions":
            return "always_allow_all_sessions"
        case "reject":
            return "reject"
        default:
            return nil
        }
    }
}

/// Interactive prompter seam. Headless implementations return deny/cancel.
public protocol PermissionPrompter: Sendable {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision
}

/// Headless prompter that denies without interaction.
public struct HeadlessPermissionPrompter: PermissionPrompter {
    public init() {}
    public func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        _ = (access, toolName, toolCallId)
        return .reject("permission prompt unavailable in headless mode")
    }
}

/// Auto-mode classifier seam.
public protocol PermissionClassifier: Sendable {
    func classify(access: AccessKind, toolName: String) async -> PermissionDecision

    func classify(
        access: AccessKind,
        toolName: String,
        accessDetail: String?,
        transcript: String
    ) async -> PermissionDecision
}

extension PermissionClassifier {
    /// Default ignores detail/transcript so existing two-parameter classifiers compile.
    public func classify(
        access: AccessKind,
        toolName: String,
        accessDetail: String?,
        transcript: String
    ) async -> PermissionDecision {
        _ = (accessDetail, transcript)
        return await classify(access: access, toolName: toolName)
    }
}

/// Always-ask classifier (safe default).
public struct AskPermissionClassifier: PermissionClassifier {
    public init() {}
    public func classify(access: AccessKind, toolName: String) async -> PermissionDecision {
        _ = (access, toolName)
        return .ask
    }
}

/// Mutable permission handle for a session.
public actor PermissionHandle {
    public private(set) var config: PermissionConfig
    public private(set) var policy: CompiledPolicy
    public private(set) var yoloMode: Bool
    public private(set) var autoMode: Bool
    public private(set) var yoloPinReason: String?
    public private(set) var sessionGrants: [SessionGrant]
    public private(set) var bashPrefixGrants: [String]
    public private(set) var bashDisallows: [String]
    private var sessionWorkingDirectoryRoots: [String: [URL]]
    public private(set) var allowAll: Bool
    public private(set) var allowEditsForSession: Bool
    public private(set) var rememberToolApprovals: Bool
    public private(set) var projectApprovalStateURL: URL?
    public private(set) var lastProjectApprovalPersistenceError: String?
    public private(set) var editPolicy: EditPolicy
    private var projectApprovalStore: ProjectPermissionApprovalStore?
    private var projectApprovalState: ProjectPermissionApprovalState
    private var projectAllowedMCPServers: Set<String>
    /// Workspace cwd used for shell file-access path resolution.
    public var shellCwd: String
    public var prompter: any PermissionPrompter
    public var classifier: (any PermissionClassifier)?
    public let sandboxAutoAllowBash: @Sendable () -> Bool
    public private(set) var events: [PermissionEvent]
    /// Last matched rule source for auditing (deny/ask/allow).
    public private(set) var lastMatchedRuleSource: PermissionRuleSource?
    /// Flat transcript fed to the auto-mode classifier (hostile-intent scan + LLM context).
    public private(set) var classifierTranscript: String
    /// Optional AGENTS.md / project instructions for the LLM classifier prompt.
    public private(set) var classifierProjectInstructions: String?
    /// True when the installed classifier is an `LlmPermissionClassifier` with a live side-query.
    public private(set) var hasLLMSideQuery: Bool

    public init(
        config: PermissionConfig = PermissionConfig(),
        yoloMode: Bool = false,
        autoMode: Bool = false,
        yoloPinReason: String? = nil,
        allowAll: Bool = false,
        shellCwd: String = FileManager.default.currentDirectoryPath,
        prompter: any PermissionPrompter = HeadlessPermissionPrompter(),
        /// Production default is the Rust heuristic classifier. Tests that need
        /// a fixed or absent classifier pass one explicitly (or `nil`).
        classifier: (any PermissionClassifier)? = HeuristicPermissionClassifier(),
        sandboxAutoAllowBash: @Sendable @escaping () -> Bool = { false },
        rememberToolApprovals: Bool = false
    ) {
        var cfg = config
        if yoloPinReason != nil {
            cfg.rules = clampRulesForYoloPin(cfg.rules)
        }
        self.config = cfg
        // Path rules anchor against the session cwd, so a rule written
        // `Edit(src/**)` matches the absolute path a tool actually receives.
        self.policy = CompiledPolicy(
            config: cfg,
            pathContext: PathRuleContext(cwd: shellCwd)
        )
        self.yoloMode = yoloPinReason != nil ? false : yoloMode
        self.autoMode = autoMode
        self.yoloPinReason = yoloPinReason
        self.sessionGrants = []
        self.bashPrefixGrants = []
        self.bashDisallows = []
        self.sessionWorkingDirectoryRoots = [:]
        self.allowAll = yoloPinReason == nil && allowAll
        self.allowEditsForSession = false
        self.rememberToolApprovals = rememberToolApprovals
        self.projectApprovalStateURL = nil
        self.lastProjectApprovalPersistenceError = nil
        self.editPolicy = .ask
        self.projectApprovalStore = nil
        self.projectApprovalState = ProjectPermissionApprovalState()
        self.projectAllowedMCPServers = []
        self.shellCwd = shellCwd
        self.prompter = prompter
        self.classifier = classifier
        self.sandboxAutoAllowBash = sandboxAutoAllowBash
        self.events = []
        self.lastMatchedRuleSource = nil
        self.classifierTranscript = ""
        self.classifierProjectInstructions = nil
        self.hasLLMSideQuery = Self.sideQueryEnabled(classifier)
    }

    public func setYoloMode(_ enabled: Bool) {
        // Authoritative re-clamp under pin — no optimistic true window.
        if yoloPinReason != nil {
            yoloMode = false
            return
        }
        yoloMode = enabled
        if enabled { autoMode = false }
    }

    public func setAutoMode(_ enabled: Bool) {
        autoMode = enabled
        if enabled { yoloMode = false }
    }

    public func setRememberToolApprovals(_ enabled: Bool) {
        guard rememberToolApprovals != enabled else { return }
        rememberToolApprovals = enabled
        if enabled {
            guard let projectApprovalStore else { return }
            do {
                let state = try projectApprovalStore.load()
                installProjectApprovalState(state)
                lastProjectApprovalPersistenceError = nil
            } catch {
                rememberToolApprovals = false
                lastProjectApprovalPersistenceError = String(describing: error)
            }
            return
        }
        sessionGrants.removeAll { grant in
            switch grant.access {
            case .bash, .mcpTool, .webFetch:
                return grant.scope != .once
            case .edit, .read, .grep, .webSearch:
                return false
            }
        }
        bashPrefixGrants.removeAll()
        projectAllowedMCPServers.removeAll()
    }

    /// Install the trusted owner/project boundary before any remembered grant is consulted.
    /// Loading is read-only: empty projects do not acquire state directories or documents.
    public func configureProjectApprovalPersistence(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        clientIdentifier: String? = nil
    ) throws {
        guard canonicalWorkspacePathKey(workingDirectory.path)
            == canonicalWorkspacePathKey(shellCwd)
        else {
            throw ProjectPermissionApprovalPersistenceError.invalidWorkspace(workingDirectory.path)
        }

        let store = try ProjectPermissionApprovalStore(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment,
            clientIdentifier: clientIdentifier
        )
        if let existing = projectApprovalStore,
           existing.fileURL.path != store.fileURL.path
                || existing.openGrokHome.path != store.openGrokHome.path {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(store.fileURL.path)
        }

        let state = try store.load()
        projectApprovalStore = store
        projectApprovalStateURL = store.fileURL
        installProjectApprovalState(state)
        lastProjectApprovalPersistenceError = nil
    }

    /// Recheck policy floors before a session-local prompter reuses a grant.
    /// A shell-file ask is deliberately never satisfied by remembered approval.
    public func canReuseRememberedApproval(_ access: AccessKind) -> Bool {
        let editSession: Bool
        if case .edit = access {
            editSession = true
        } else {
            editSession = false
        }
        guard rememberToolApprovals || editSession else { return false }
        if let matched = policy.evaluateWithSource(access) {
            switch matched.decision {
            case .policyDeny, .reject, .cancelled, .followupMessage:
                return false
            case .ask:
                if Self.isManagedPolicySource(matched.ruleSource) { return false }
                if !rememberToolApprovals && !editSession { return false }
            case .allow:
                break
            }
        }

        switch access {
        case .edit(let path):
            return !protectedEditPath(path, userGrokHome: userGrokHomePath)
        case .bash(let command):
            guard matchesSessionBashGrant(command, grant: command) else { return false }
            if let decision = policy.evaluateBashCommandPolicy(command) {
                switch decision {
                case .policyDeny, .reject, .cancelled, .followupMessage:
                    return false
                case .ask:
                    if !rememberToolApprovals { return false }
                case .allow:
                    break
                }
            }
            if let decision = policy.evaluateShellFileAccess(command, cwd: shellCwd),
               decision != .allow {
                return false
            }
            return evaluateBashSegments(
                command,
                grants: [],
                disallows: bashDisallows
            ).reason != "disallow"
        case .mcpTool, .webFetch:
            return rememberToolApprovals
        case .read, .grep, .webSearch:
            return false
        }
    }

    public func setClassifier(_ classifier: (any PermissionClassifier)?) {
        self.classifier = classifier
        self.hasLLMSideQuery = Self.sideQueryEnabled(classifier)
    }

    /// Swap the interactive prompter after construction. `prompter` is
    /// actor-isolated state, so a caller outside the actor cannot assign it
    /// directly; the ACP carrier needs this to replace the fail-closed default
    /// with the reverse-request prompter once a client is connected.
    public func setPrompter(_ prompter: any PermissionPrompter) {
        self.prompter = prompter
    }

    public func setClassifierTranscript(_ transcript: String) {
        classifierTranscript = transcript
    }

    public func setClassifierProjectInstructions(_ instructions: String?) {
        classifierProjectInstructions = instructions
    }

    private static func sideQueryEnabled(_ classifier: (any PermissionClassifier)?) -> Bool {
        guard let llm = classifier as? LlmPermissionClassifier else { return false }
        return llm.hasSideQuery
    }

    private static func isManagedPolicySource(_ source: PermissionRuleSource?) -> Bool {
        switch source {
        case .systemRequirements, .requirements, .managedSettings, .managedConfig:
            return true
        case .unknown, .config, .settings, .cli, .synthetic, nil:
            return false
        }
    }

    private func installProjectApprovalState(_ state: ProjectPermissionApprovalState) {
        projectApprovalState = state
        sessionGrants.removeAll { $0.scope == .project }
        bashDisallows = Array(Set(bashDisallows).union(state.disallowedBashCommands)).sorted()
        projectAllowedMCPServers.removeAll()

        guard rememberToolApprovals else {
            bashPrefixGrants = sessionGrants.compactMap { grant in
                guard case .bash(let command) = grant.access,
                      grant.scope != .once
                else { return nil }
                return grant.pattern ?? command
            }
            return
        }

        for command in state.allowedBashCommands.sorted() {
            guard matchesSessionBashGrant(command, grant: command) else { continue }
            sessionGrants.append(SessionGrant(
                access: .bash(command),
                scope: .project,
                pattern: command
            ))
        }
        for domain in state.allowedWebFetchDomains.sorted() {
            guard Self.validatedWebFetchDomain(domain) == domain else { continue }
            sessionGrants.append(SessionGrant(
                access: .webFetch("https://" + domain),
                scope: .project,
                pattern: domain
            ))
        }
        for tool in state.allowedMCPTools.sorted() {
            guard Self.isValidMCPToolName(tool) else { continue }
            sessionGrants.append(SessionGrant(
                access: .mcpTool(name: tool, input: .null),
                scope: .project,
                pattern: tool
            ))
        }
        projectAllowedMCPServers = Set(state.allowedMCPServers.filter(Self.isValidMCPServerName))
        bashPrefixGrants = sessionGrants.compactMap { grant in
            guard case .bash(let command) = grant.access,
                  grant.scope != .once
            else { return nil }
            return grant.pattern ?? command
        }
    }

    private func persistProjectGrant(_ grant: SessionGrant) -> Bool {
        guard rememberToolApprovals, let store = projectApprovalStore else { return false }

        var updated = projectApprovalState
        switch grant.access {
        case .bash(let command):
            let approved = command.trimmingCharacters(in: .whitespaces)
            guard !approved.isEmpty,
                  approved.utf8.count <= ProjectPermissionApprovalState.maximumEntryBytes,
                  grant.pattern == nil || grant.pattern == approved,
                  matchesSessionBashGrant(approved, grant: approved)
            else { return false }
            updated.allowedBashCommands.insert(approved)

        case .webFetch(let rawURL):
            guard let components = URLComponents(string: rawURL),
                  let host = components.host,
                  let domain = Self.validatedWebFetchDomain(host),
                  grant.pattern == nil
                    || Self.validatedWebFetchDomain(grant.pattern ?? "") == domain
            else { return false }
            updated.allowedWebFetchDomains.insert(domain)

        case .mcpTool(let name, _):
            guard Self.isValidMCPToolName(name),
                  grant.pattern == nil || grant.pattern == name
            else { return false }
            updated.allowedMCPTools.insert(name)

        // "Allow edits during this session" is never a project grant.
        case .edit, .read, .grep, .webSearch:
            return false
        }

        do {
            installProjectApprovalState(try store.save(updated, merging: true))
            lastProjectApprovalPersistenceError = nil
            return true
        } catch {
            lastProjectApprovalPersistenceError = String(describing: error)
            return false
        }
    }

    private static func validatedWebFetchDomain(_ raw: String) -> String? {
        let normalized = normalizeDomain(raw)
        guard !normalized.isEmpty,
              normalized.utf8.count <= ProjectPermissionApprovalState.maximumEntryBytes,
              !normalized.unicodeScalars.contains(where: { scalar in
                  scalar.properties.generalCategory == .control
                      || scalar == "/" || scalar == "\\" || scalar == "@"
              }),
              let components = URLComponents(string: "https://" + normalized),
              components.host.map(normalizeDomain) == normalized,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        return normalized
    }

    private static func isValidMCPToolName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= ProjectPermissionApprovalState.maximumEntryBytes
            && !name.unicodeScalars.contains { scalar in
                scalar.properties.generalCategory == .control
            }
    }

    private static func isValidMCPServerName(_ name: String) -> Bool {
        isValidMCPToolName(name) && !name.contains("__")
    }

    private static func qualifiedMCPServer(_ name: String) -> String? {
        guard isValidMCPToolName(name) else { return nil }
        let bytes = Array(name.utf8)
        var boundary: Int?
        for index in bytes.indices.dropLast() where bytes[index] == 95 && bytes[index + 1] == 95 {
            guard boundary == nil else { return nil }
            boundary = index
        }
        guard let boundary, boundary > 0, boundary + 2 < bytes.count else { return nil }
        let server = String(decoding: bytes[..<boundary], as: UTF8.self)
        return isValidMCPServerName(server) ? server : nil
    }

    public func setAllowEditsForSession(_ enabled: Bool) {
        allowEditsForSession = enabled
    }

    public func setEditPolicy(_ policy: EditPolicy) {
        editPolicy = policy
    }

    public func replaceConfig(_ config: PermissionConfig) {
        var cfg = config
        if yoloPinReason != nil {
            cfg.rules = clampRulesForYoloPin(cfg.rules)
        }
        self.config = cfg
        self.policy = CompiledPolicy(
            config: cfg,
            pathContext: PathRuleContext(cwd: shellCwd)
        )
    }

    @discardableResult
    public func grant(_ grant: SessionGrant) -> Bool {
        if grant.scope == .project {
            return persistProjectGrant(grant)
        }

        sessionGrants.append(grant)
        if case .bash(let cmd) = grant.access, grant.scope != .once {
            bashPrefixGrants.append(grant.pattern ?? cmd)
        }
        if case .edit = grant.access, grant.scope == .session {
            allowEditsForSession = true
        }
        return true
    }

    public func disallowBashPrefix(_ prefix: String) {
        bashDisallows.append(prefix)
        guard let store = projectApprovalStore,
              !prefix.isEmpty,
              prefix.utf8.count <= ProjectPermissionApprovalState.maximumEntryBytes,
              !prefix.unicodeScalars.contains("\0")
        else { return }

        var updated = projectApprovalState
        updated.disallowedBashCommands.insert(prefix)
        do {
            installProjectApprovalState(try store.save(updated, merging: true))
            lastProjectApprovalPersistenceError = nil
        } catch {
            lastProjectApprovalPersistenceError = String(describing: error)
        }
    }

    /// Atomically replace one authenticated root session's extra directory grants.
    /// An empty replacement revokes every previous root before this call returns.
    public func replaceWorkingDirectoryRules(sessionID: String, roots: [URL]) {
        guard !sessionID.isEmpty else { return }
        var canonicalRoots: [URL] = []
        var seen: Set<String> = []
        for root in roots {
            guard root.isFileURL else { continue }
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path != "/" else { continue }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: canonical.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }
            if seen.insert(canonical.path).inserted {
                canonicalRoots.append(canonical)
            }
        }
        if canonicalRoots.isEmpty {
            sessionWorkingDirectoryRoots.removeValue(forKey: sessionID)
        } else {
            sessionWorkingDirectoryRoots[sessionID] = canonicalRoots
        }
    }

    public func workingDirectoryRoots(sessionID: String) -> [URL] {
        sessionWorkingDirectoryRoots[sessionID] ?? []
    }

    public func resetState() {
        sessionGrants.removeAll()
        bashPrefixGrants.removeAll()
        sessionWorkingDirectoryRoots.removeAll()
        allowEditsForSession = false
        projectAllowedMCPServers.removeAll()
        guard let store = projectApprovalStore else { return }
        do {
            projectApprovalState = try store.save(ProjectPermissionApprovalState(), merging: false)
            bashDisallows.removeAll()
            lastProjectApprovalPersistenceError = nil
        } catch {
            lastProjectApprovalPersistenceError = String(describing: error)
        }
    }

    /// Core request path matching the Rust permission actor order.
    public func request(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        sessionID: String? = nil
    ) async -> PermissionDecision {
        lastMatchedRuleSource = nil
        var policyForcedPrompt = false
        var policyAllowed = false
        var shellFileForcedPrompt = false
        var autoForcedPrompt = false
        let safeBashPrefixGrants: [String]
        let policyAccess: AccessKind
        if case .bash(let command) = access {
            policyAccess = .bash(securityNormalizedShellCommand(command))
            safeBashPrefixGrants = bashPrefixGrants.filter {
                matchesSessionBashGrant(command, grant: $0)
            }
        } else {
            policyAccess = access
            safeBashPrefixGrants = []
        }

        // 1. Compiled policy direct evaluate (deny > ask > allow).
        if let matched = policy.evaluateWithSource(policyAccess) {
            lastMatchedRuleSource = matched.ruleSource
            switch matched.decision {
            case .policyDeny(let reason), .reject(let reason):
                let decision = PermissionDecision.policyDeny(reason)
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: decision, autoApproved: false, userPrompted: false,
                    reason: "policy_deny", reject: reason
                )
                return decision
            case .ask:
                policyForcedPrompt = true
            case .allow:
                // Bash can still touch a denied file or contain a denied
                // command segment, so its allow cannot win before preflight.
                policyAllowed = true
            case .followupMessage, .cancelled:
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: matched.decision, autoApproved: false, userPrompted: false,
                    reason: "policy"
                )
                return matched.decision
            }
        }

        // 2. Bash segment policy + shell file-access escalation (never Allow).
        if case .bash(let rawCommand) = access {
            let cmd = securityNormalizedShellCommand(rawCommand)
            if let bashDecision = policy.evaluateBashCommandPolicy(cmd) {
                switch bashDecision {
                case .policyDeny, .reject:
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: bashDecision, autoApproved: false, userPrompted: false,
                        reason: "bash_policy"
                    )
                    return bashDecision
                case .ask:
                    policyForcedPrompt = true
                default:
                    break
                }
            }
            if let shellDecision = policy.evaluateShellFileAccess(cmd, cwd: shellCwd) {
                switch shellDecision {
                case .policyDeny, .reject:
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: shellDecision, autoApproved: false, userPrompted: false,
                        reason: "shell_file_access"
                    )
                    return shellDecision
                case .ask:
                    shellFileForcedPrompt = true
                    policyForcedPrompt = true
                default:
                    break
                }
            }
        }

        if policyAllowed, !policyForcedPrompt {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "policy_allow"
            )
            return .allow
        }

        if allowAll, !policyForcedPrompt {
            record(
                access: access,
                toolName: toolName,
                toolCallId: toolCallId,
                decision: .allow,
                autoApproved: true,
                userPrompted: false,
                reason: "allow_all"
            )
            return .allow
        }

        // Protected edit paths always force prompt (not YOLO-bypassable for safety lists
        // but YOLO still allows — Rust YOLO short-circuits after policy/shell ask).
        var protectedEdit = false
        if case .edit(let path) = access {
            // Passing the user grok home is what makes
            // `$OPENGROK_HOME/config.toml` and `$OPENGROK_HOME/hooks/**`
            // protected, not just the `.opengrok/` forms.
            protectedEdit = protectedEditPath(path, userGrokHome: userGrokHomePath)
        }

        // 3. YOLO / always-approve (blocked by policy/shell Ask; pin keeps false).
        if yoloMode && yoloPinReason == nil && !policyForcedPrompt {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "yolo"
            )
            return .allow
        }

        // 4. Session grants (before auto classifier). Shell-file forced asks
        // still prompt; protected edits still prompt.
        if !policyForcedPrompt,
           !protectedEdit,
           matchesWorkingDirectoryGrant(access, sessionID: sessionID) {
            record(
                access: access,
                toolName: toolName,
                toolCallId: toolCallId,
                decision: .allow,
                autoApproved: true,
                userPrompted: false,
                reason: "session_directory_grant"
            )
            return .allow
        }

        let grantMaySatisfyPrompt: Bool
        if policyForcedPrompt, Self.isManagedPolicySource(lastMatchedRuleSource) {
            grantMaySatisfyPrompt = false
        } else if !policyForcedPrompt || rememberToolApprovals {
            grantMaySatisfyPrompt = true
        } else if case .edit = access {
            grantMaySatisfyPrompt = true
        } else {
            grantMaySatisfyPrompt = false
        }
        if !shellFileForcedPrompt,
           grantMaySatisfyPrompt,
           !protectedEdit,
           matchesSessionGrant(access) {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "session_grant"
            )
            return .allow
        }

        // 5. Built-in auto-allows / bash safe classification.
        if !policyForcedPrompt {
            switch access {
            case .read, .grep, .webSearch:
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "safe_command"
                )
                return .allow
            case .edit:
                if allowEditsForSession && !protectedEdit {
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: .allow, autoApproved: true, userPrompted: false,
                        reason: "persisted_grant"
                    )
                    return .allow
                }
                if editPolicy == .reject {
                    let d = PermissionDecision.reject("edits prohibited")
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: d, autoApproved: false, userPrompted: false,
                        reason: "session_deny"
                    )
                    return d
                }
            case .bash(let cmd):
                let securityCommand = securityNormalizedShellCommand(cmd)
                let seg = evaluateBashSegments(
                    securityCommand,
                    grants: safeBashPrefixGrants,
                    disallows: bashDisallows
                )
                if let reason = seg.reason, reason == "disallow" {
                    let d = PermissionDecision.reject("bash prefix disallowed")
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: d, autoApproved: false, userPrompted: false,
                        reason: "session_deny"
                    )
                    return d
                }
                if seg.autoAllow && !seg.needsPrompt,
                   bashSandboxAutoAllow(securityCommand, exactGrants: safeBashPrefixGrants) {
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: .allow, autoApproved: true, userPrompted: false,
                        reason: "safe_command"
                    )
                    return .allow
                }
            case .mcpTool, .webFetch:
                break
            }
        } else if case .bash(let cmd) = access {
            // Still honor hard disallow under ask floor.
            let seg = evaluateBashSegments(
                securityNormalizedShellCommand(cmd),
                grants: safeBashPrefixGrants,
                disallows: bashDisallows
            )
            if let reason = seg.reason, reason == "disallow" {
                let d = PermissionDecision.reject("bash prefix disallowed")
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: d, autoApproved: false, userPrompted: false,
                    reason: "session_deny"
                )
                return d
            }
        }

        // 6. Auto mode classifier (not when policy forced prompt).
        if autoMode, !policyForcedPrompt, let classifier {
            let classified: PermissionDecision
            if let llm = classifier as? LlmPermissionClassifier {
                // Prefer the outcome API so Unavailable (timeout/transport)
                // forces a prompt rather than a silent deny.
                let outcome = await llm.classifyOutcome(
                    toolName: toolName,
                    access: access,
                    accessDetail: access.detail,
                    context: ClassifierContext(
                        transcript: classifierTranscript,
                        projectInstructions: classifierProjectInstructions
                    )
                )
                switch outcome.verdict {
                case .allow:
                    classified = .allow
                case .block:
                    classified = .policyDeny(
                        outcome.reason ?? "auto mode: classifier blocked"
                    )
                case .unavailable:
                    classified = .ask
                }
            } else {
                classified = await classifier.classify(
                    access: access,
                    toolName: toolName,
                    accessDetail: access.detail,
                    transcript: classifierTranscript
                )
            }
            if case .allow = classified {
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "auto_classifier_allow"
                )
                return .allow
            }
            if case .policyDeny = classified {
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: classified, autoApproved: false, userPrompted: false,
                    reason: "auto_classifier_block"
                )
                return classified
            }
            if case .ask = classified {
                autoForcedPrompt = true
            }
        }

        // Sandbox auto-approval is intentionally later than policy, hooks,
        // shell-file escalation, and auto classification. The Bash floor helper
        // keeps opaque shell, dangerous segments, executable indirection,
        // unsafe environment assignments, and real-file writes on the prompt
        // path even when the OS sandbox is active.
        if case .bash(let cmd) = access,
           !policyForcedPrompt,
           !autoForcedPrompt,
           sandboxAutoAllowBash(),
           bashSandboxAutoAllow(
                securityNormalizedShellCommand(cmd),
                exactGrants: safeBashPrefixGrants
           ) {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "sandbox_auto"
            )
            return .allow
        }

        // 7. Prompt policy.
        switch config.promptPolicy {
        case .deny:
            let d = PermissionDecision.policyDeny("prompt policy: dontAsk")
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: d, autoApproved: false, userPrompted: false,
                reason: "prompt_deny"
            )
            return d
        case .auto:
            return await promptPath(
                access: access, toolName: toolName, toolCallId: toolCallId,
                reason: policyForcedPrompt ? "policy_ask" : "auto_needs_user"
            )
        case .ask:
            return await promptPath(
                access: access, toolName: toolName, toolCallId: toolCallId,
                reason: policyForcedPrompt ? "policy_ask" : "needs_user"
            )
        }
    }

    private func promptPath(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        reason: String
    ) async -> PermissionDecision {
        let decision = await prompter.prompt(
            access: access,
            toolName: toolName,
            toolCallId: toolCallId
        )
        record(
            access: access, toolName: toolName, toolCallId: toolCallId,
            decision: decision, autoApproved: false, userPrompted: true,
            reason: reason
        )
        return decision
    }

    private func matchesWorkingDirectoryGrant(
        _ access: AccessKind,
        sessionID: String?
    ) -> Bool {
        guard let sessionID,
              !sessionID.isEmpty,
              let roots = sessionWorkingDirectoryRoots[sessionID],
              !roots.isEmpty
        else {
            return false
        }

        let rawPath: String
        let edit: Bool
        switch access {
        case .read(let path?):
            rawPath = path
            edit = false
        case .edit(let path):
            rawPath = path
            edit = true
        case .read(nil), .bash, .grep, .webSearch, .webFetch, .mcpTool:
            return false
        }

        let base = URL(fileURLWithPath: shellCwd, isDirectory: true)
        let candidate = URL(fileURLWithPath: rawPath, relativeTo: base)
            .standardizedFileURL
        let canonicalPath = canonicalWorkspacePathKey(candidate.path)
        if edit, protectedEditPath(canonicalPath, userGrokHome: userGrokHomePath) {
            return false
        }
        return roots.contains { root in
            containsPath(root: root.path, candidate: canonicalPath)
        }
    }

    private func matchesSessionGrant(_ access: AccessKind) -> Bool {
        if case .bash(let command) = access,
           evaluateBashSegments(command, grants: [], disallows: bashDisallows).reason == "disallow" {
            return false
        }

        if rememberToolApprovals {
            switch access {
            case .mcpTool(let name, _):
                if let server = Self.qualifiedMCPServer(name),
                   projectAllowedMCPServers.contains(server) {
                    return true
                }
            case .bash(let command):
                if matchesSessionBashGrant(command, grant: command),
                   yoloPinReason == nil,
                   projectApprovalState.allowBashExecute
                    || projectApprovalState.allowedBashGlobs.contains(where: {
                        globMatches(text: command, pattern: $0, pathContext: false)
                    }) {
                    return true
                }
            case .read, .grep, .edit, .webFetch, .webSearch:
                break
            }
        }

        for index in sessionGrants.indices {
            let grant = sessionGrants[index]
            let matches: Bool
            switch (grant.access, access) {
            case (.edit, .edit(let path)):
                if let pattern = grant.pattern {
                    matches = globMatches(text: path, pattern: pattern, pathContext: true)
                } else {
                    matches = true
                }
            case (.read, .read(let path)):
                if let pattern = grant.pattern, let path {
                    matches = globMatches(text: path, pattern: pattern, pathContext: true)
                } else {
                    matches = grant.pattern == nil
                }
            case (.bash, .bash(let command)):
                let prefix = grant.pattern ?? {
                    if case .bash(let approvedCommand) = grant.access { return approvedCommand }
                    return ""
                }()
                matches = matchesSessionBashGrant(command, grant: prefix)
            case (.mcpTool(let approvedName, _), .mcpTool(let name, _)):
                matches = approvedName == name
            case (.webFetch, .webFetch(let url)):
                if let pattern = grant.pattern {
                    matches = domainMatches(pattern: pattern, url: url)
                } else {
                    matches = false
                }
            default:
                matches = false
            }

            if matches {
                if grant.scope == .once {
                    sessionGrants.remove(at: index)
                }
                return true
            }
        }
        return false
    }

    private func record(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        decision: PermissionDecision,
        autoApproved: Bool,
        userPrompted: Bool,
        reason: String,
        reject: String? = nil
    ) {
        let decisionStr: String
        var rejectReason = reject
        switch decision {
        case .allow: decisionStr = "allow"
        case .ask: decisionStr = "ask"
        case .followupMessage: decisionStr = "followup"
        case .reject(let r):
            decisionStr = "reject"
            rejectReason = r
        case .policyDeny(let r):
            decisionStr = "policy_deny"
            rejectReason = r
        case .cancelled:
            decisionStr = "cancelled"
        }
        events.append(PermissionEvent(
            toolId: toolCallId,
            toolName: toolName,
            accessKind: access.label,
            accessDetail: access.detail,
            yoloMode: yoloMode,
            autoApproved: autoApproved,
            userPrompted: userPrompted,
            decision: decisionStr,
            rejectReason: rejectReason,
            decisionReason: reason,
            permissionMode: yoloMode ? "always-approve" : (autoMode ? "auto" : "ask"),
            ruleSource: lastMatchedRuleSource?.rawValue
        ))
    }
}
