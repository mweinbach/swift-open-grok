import Foundation

public enum CLIParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case invalidValue(option: String, value: String, expected: String)
    case conflictingOptions(String, String)
    case missingSubcommand(String)
    case requiresOption(String, String)

    public var description: String {
        switch self {
        case .unknownCommand(let command):
            return "unknown command '\(command)'"
        case .unknownOption(let option):
            return "unknown option '\(option)'"
        case .missingValue(let option):
            return "option '\(option)' requires a value"
        case .unexpectedArgument(let argument):
            return "unexpected argument '\(argument)'"
        case .invalidValue(let option, let value, let expected):
            return "invalid value '\(value)' for \(option); expected \(expected)"
        case .conflictingOptions(let first, let second):
            return "options \(first) and \(second) cannot be used together"
        case .missingSubcommand(let command):
            return "command '\(command)' requires a subcommand"
        case .requiresOption(let option, let required):
            return "option '\(option)' requires \(required)"
        }
    }
}

public enum CLIOutputFormat: String, Sendable, Equatable {
    case plain
    case json
    case streamingJSON = "streaming-json"
    case streamingMessagesJSON = "streaming-messages-json"
}

public enum CLIRunMode: String, Sendable, Equatable {
    case interactive
    case minimal
    case headless
    case acp
    case serve
    case leader
}

/// Values accepted by `--permission-mode`, matching
/// `PermissionMode::VALID_VALUES` in the Rust shell (`cli.rs:665-673`).
public enum CLIPermissionMode: String, Sendable, Equatable, CaseIterable {
    case `default`
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions
    case plan
}

/// The permission and sandbox surface parsed from the root command line.
///
/// The parser's only job is to produce this faithfully; deciding what it means
/// belongs to the permission/sandbox resolution layer, which reads it off
/// `CLICommonOptions.permissions`.
///
/// Note the deliberate near-collision inherited from upstream: `--disallowedTools`
/// (camel case) is an alias for `--deny` and lands in `denyRules`, while
/// `--disallowed-tools` (kebab case) is the built-in tool filter and lands in
/// `CLIExecutionOptions.disallowedTools`. They are different features with
/// nearly identical spellings; see `cli.rs:458-464` versus `cli.rs:652-657`.
public struct CLIPermissionOptions: Sendable, Equatable {
    /// `--allow` / `--allowedTools`. Comma-delimited and repeatable; order preserved.
    public var allowRules: [String]
    /// `--deny` / `--disallowedTools`. Comma-delimited and repeatable; order preserved.
    public var denyRules: [String]
    /// `--permission-mode`. `nil` means unset, so config decides.
    public var mode: CLIPermissionMode?
    /// `--always-approve` / `--yolo` / `--dangerously-skip-permissions`.
    public var alwaysApprove: Bool
    /// `--trust` / `--trust-folder`.
    public var trustFolder: Bool
    /// `--sandbox`, falling back to `GROK_SANDBOX`. `nil` means unset.
    public var sandboxProfile: String?

    public init(
        allowRules: [String] = [],
        denyRules: [String] = [],
        mode: CLIPermissionMode? = nil,
        alwaysApprove: Bool = false,
        trustFolder: Bool = false,
        sandboxProfile: String? = nil
    ) {
        self.allowRules = allowRules
        self.denyRules = denyRules
        self.mode = mode
        self.alwaysApprove = alwaysApprove
        self.trustFolder = trustFolder
        self.sandboxProfile = sandboxProfile
    }
}

public struct CLICommonOptions: Sendable, Equatable {
    public var cwd: String?
    public var model: String?
    public var provider: String?
    public var profile: String?
    public var pluginDirectories: [String]
    public var mcpConfig: String?
    public var workflow: String?
    public var leader: Bool
    public var noLeader: Bool
    /// `--debug`, `--debug-file`, `--leader-socket`: global in clap, so they are
    /// accepted before or after a subcommand and ride along on every route.
    public var debug: Bool
    public var debugFile: String?
    public var leaderSocket: String?
    public var permissions: CLIPermissionOptions

    public init(
        cwd: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        profile: String? = nil,
        pluginDirectories: [String] = [],
        mcpConfig: String? = nil,
        workflow: String? = nil,
        leader: Bool = false,
        noLeader: Bool = false,
        debug: Bool = false,
        debugFile: String? = nil,
        leaderSocket: String? = nil,
        permissions: CLIPermissionOptions = CLIPermissionOptions()
    ) {
        self.cwd = cwd
        self.model = model
        self.provider = provider
        self.profile = profile
        self.pluginDirectories = pluginDirectories
        self.mcpConfig = mcpConfig
        self.workflow = workflow
        self.leader = leader
        self.noLeader = noLeader
        self.debug = debug
        self.debugFile = debugFile
        self.leaderSocket = leaderSocket
        self.permissions = permissions
    }
}

/// Agent-configuration flags that shape the run but are neither prompt sources
/// nor session selectors (`cli.rs:510-537`, `:634-676`).
public struct CLIAgentOptions: Sendable, Equatable {
    public var reasoningEffort: String?
    public var rules: String?
    public var systemPromptOverride: String?
    public var agent: String?
    public var agentsJSON: String?
    public var tools: String?
    public var disallowedTools: String?
    public var maxTurns: UInt32?
    public var noPlan: Bool
    public var noSubagents: Bool
    public var noAskUser: Bool
    public var experimentalMemory: Bool
    public var noMemory: Bool
    public var disableWebSearch: Bool

    public init(
        reasoningEffort: String? = nil,
        rules: String? = nil,
        systemPromptOverride: String? = nil,
        agent: String? = nil,
        agentsJSON: String? = nil,
        tools: String? = nil,
        disallowedTools: String? = nil,
        maxTurns: UInt32? = nil,
        noPlan: Bool = false,
        noSubagents: Bool = false,
        noAskUser: Bool = false,
        experimentalMemory: Bool = false,
        noMemory: Bool = false,
        disableWebSearch: Bool = false
    ) {
        self.reasoningEffort = reasoningEffort
        self.rules = rules
        self.systemPromptOverride = systemPromptOverride
        self.agent = agent
        self.agentsJSON = agentsJSON
        self.tools = tools
        self.disallowedTools = disallowedTools
        self.maxTurns = maxTurns
        self.noPlan = noPlan
        self.noSubagents = noSubagents
        self.noAskUser = noAskUser
        self.experimentalMemory = experimentalMemory
        self.noMemory = noMemory
        self.disableWebSearch = disableWebSearch
    }
}

/// Hidden operational flags (`cli.rs:522-530`, `:677-734`). They are parsed so
/// scripted callers are not rejected, and carried verbatim for whoever consumes
/// them.
public struct CLIAdvancedOptions: Sendable, Equatable {
    public var storageMode: String?
    public var clientIdentifier: String?
    public var hunkTrackerMode: String?
    public var installer: String?
    public var compactionMode: String?
    public var compactionDetail: String?
    public var terminal: Bool
    public var fsRead: Bool
    public var fsWrite: Bool
    public var noAutoUpdate: Bool
    public var todoGate: Bool
    public var logSampling: Bool
    public var noWaitForBackground: Bool
    public var backgroundWaitTimeoutSeconds: UInt64
    public var forceLogin: Bool
    /// `agent --reauth` / `--reauthenticate` (`cli.rs:239-245`).
    public var reauthenticate: Bool
    /// `agent --cli-chat-proxy-base-url` / `--xai-api-base-url`
    /// (`cli.rs:279-284`). These override `EndpointsConfig`, so pointing a run
    /// at the wrong host is exactly the kind of silent wrongness the refusal in
    /// `LiveComposition` exists to prevent.
    public var cliChatProxyBaseURL: String?
    public var xaiAPIBaseURL: String?

    public init(
        storageMode: String? = nil,
        clientIdentifier: String? = nil,
        hunkTrackerMode: String? = nil,
        installer: String? = nil,
        compactionMode: String? = nil,
        compactionDetail: String? = nil,
        terminal: Bool = false,
        fsRead: Bool = false,
        fsWrite: Bool = false,
        noAutoUpdate: Bool = false,
        todoGate: Bool = false,
        logSampling: Bool = false,
        noWaitForBackground: Bool = false,
        backgroundWaitTimeoutSeconds: UInt64 = 600,
        forceLogin: Bool = false,
        reauthenticate: Bool = false,
        cliChatProxyBaseURL: String? = nil,
        xaiAPIBaseURL: String? = nil
    ) {
        self.storageMode = storageMode
        self.clientIdentifier = clientIdentifier
        self.hunkTrackerMode = hunkTrackerMode
        self.installer = installer
        self.compactionMode = compactionMode
        self.compactionDetail = compactionDetail
        self.terminal = terminal
        self.fsRead = fsRead
        self.fsWrite = fsWrite
        self.noAutoUpdate = noAutoUpdate
        self.todoGate = todoGate
        self.logSampling = logSampling
        self.noWaitForBackground = noWaitForBackground
        self.backgroundWaitTimeoutSeconds = backgroundWaitTimeoutSeconds
        self.forceLogin = forceLogin
        self.reauthenticate = reauthenticate
        self.cliChatProxyBaseURL = cliChatProxyBaseURL
        self.xaiAPIBaseURL = xaiAPIBaseURL
    }
}

public struct CLIExecutionOptions: Sendable, Equatable {
    public var mode: CLIRunMode
    public var common: CLICommonOptions
    public var prompt: String?
    public var promptJSON: String?
    public var promptFile: String?
    public var outputFormat: CLIOutputFormat
    public var sessionID: String?
    public var resume: String?
    public var continueSession: Bool
    public var forkSession: Bool
    public var noAltScreen: Bool
    public var fullscreen: Bool
    /// `--load`, the hidden `--resume` alias (`cli.rs:552-558`). Kept distinct
    /// from `resume` so the two spellings stay distinguishable; use
    /// ``sessionToResume`` to read the effective target.
    public var loadSession: String?
    /// `--restore-code`, which clap requires be paired with `--resume`.
    public var restoreCode: Bool
    /// `-w`/`--worktree`, whose value is optional (empty string = unnamed).
    public var worktree: String?
    /// `--worktree-ref`/`--ref`, which clap requires be paired with `--worktree`.
    public var worktreeRef: String?
    /// `--verbatim`: send the prompt exactly as given.
    public var verbatim: Bool
    /// `--include-partial-messages`, meaningful only for streaming output.
    public var includePartialMessages: Bool
    /// `--json-schema`, which implies `--output-format json`.
    public var jsonSchema: String?
    /// Gateway chat frontend mode. The Swift release parses and validates this
    /// even when the proprietary gateway backend is unavailable.
    public var chat: Bool
    /// `--local-workspace[=CWD]`; `""` means own the current directory.
    public var localWorkspace: String?
    /// Existing local workspace server id to attach.
    public var localWorkspaceAttach: String?
    /// Explicit cwd override for either local-workspace mode.
    public var localWorkspaceCWD: String?
    /// Root `--minimal`: scrollback-native rendering for an *interactive*
    /// session. Distinct from ``CLIRunMode/minimal``, which is this port's
    /// one-shot mode word, so selecting the renderer never silently demands a
    /// prompt.
    public var minimalRendering: Bool
    /// `--oauth`: prefer OAuth when the welcome screen starts authentication.
    public var oauth: Bool
    public var agentOptions: CLIAgentOptions
    public var advanced: CLIAdvancedOptions

    public init(
        mode: CLIRunMode = .interactive,
        common: CLICommonOptions = CLICommonOptions(),
        prompt: String? = nil,
        promptJSON: String? = nil,
        promptFile: String? = nil,
        outputFormat: CLIOutputFormat = .plain,
        sessionID: String? = nil,
        resume: String? = nil,
        continueSession: Bool = false,
        forkSession: Bool = false,
        noAltScreen: Bool = false,
        fullscreen: Bool = false,
        loadSession: String? = nil,
        restoreCode: Bool = false,
        worktree: String? = nil,
        worktreeRef: String? = nil,
        verbatim: Bool = false,
        includePartialMessages: Bool = false,
        jsonSchema: String? = nil,
        chat: Bool = false,
        localWorkspace: String? = nil,
        localWorkspaceAttach: String? = nil,
        localWorkspaceCWD: String? = nil,
        minimalRendering: Bool = false,
        oauth: Bool = false,
        agentOptions: CLIAgentOptions = CLIAgentOptions(),
        advanced: CLIAdvancedOptions = CLIAdvancedOptions()
    ) {
        self.mode = mode
        self.common = common
        self.prompt = prompt
        self.promptJSON = promptJSON
        self.promptFile = promptFile
        self.outputFormat = outputFormat
        self.sessionID = sessionID
        self.resume = resume
        self.continueSession = continueSession
        self.forkSession = forkSession
        self.noAltScreen = noAltScreen
        self.fullscreen = fullscreen
        self.loadSession = loadSession
        self.restoreCode = restoreCode
        self.worktree = worktree
        self.worktreeRef = worktreeRef
        self.verbatim = verbatim
        self.includePartialMessages = includePartialMessages
        self.jsonSchema = jsonSchema
        self.chat = chat
        self.localWorkspace = localWorkspace
        self.localWorkspaceAttach = localWorkspaceAttach
        self.localWorkspaceCWD = localWorkspaceCWD
        self.minimalRendering = minimalRendering
        self.oauth = oauth
        self.agentOptions = agentOptions
        self.advanced = advanced
    }

    /// The effective resume target from `--resume` or `--load`, with the
    /// "" sentinel (resume most recent) filtered out — `session_to_resume()`
    /// at `cli.rs:876-882`.
    public var sessionToResume: String? {
        let candidate = resume ?? loadSession
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }

    /// Whether `--resume` was given with no value, meaning "the most recent
    /// session for this directory" (`cli.rs:884-886`).
    public var resumeMostRecent: Bool {
        resume == "" || loadSession == ""
    }
}

public struct CLIServeOptions: Sendable, Equatable {
    public var common: CLICommonOptions
    public var bind: String
    public var secret: String?
    public var remote: String?
    public var grokWSOrigin: String?
    public var grokWSURL: String?

    public init(
        common: CLICommonOptions = CLICommonOptions(),
        bind: String = "127.0.0.1:2419",
        secret: String? = nil,
        remote: String? = nil,
        grokWSOrigin: String? = nil,
        grokWSURL: String? = nil
    ) {
        self.common = common
        self.bind = bind
        self.secret = secret
        self.remote = remote
        self.grokWSOrigin = grokWSOrigin
        self.grokWSURL = grokWSURL
    }
}

public struct CLILeaderOptions: Sendable, Equatable {
    public var common: CLICommonOptions
    public var noExitOnDisconnect: Bool
    public var relayOnDemand: Bool
    public var noAutoUpdate: Bool
    public var grokWSOrigin: String?
    public var grokWSURL: String?

    public init(
        common: CLICommonOptions = CLICommonOptions(),
        noExitOnDisconnect: Bool = false,
        relayOnDemand: Bool = false,
        noAutoUpdate: Bool = false,
        grokWSOrigin: String? = nil,
        grokWSURL: String? = nil
    ) {
        self.common = common
        self.noExitOnDisconnect = noExitOnDisconnect
        self.relayOnDemand = relayOnDemand
        self.noAutoUpdate = noAutoUpdate
        self.grokWSOrigin = grokWSOrigin
        self.grokWSURL = grokWSURL
    }
}

public enum CLISessionAction: String, Sendable, Equatable {
    case list
    case search
    case show
    case delete
    case new
    case resume
    case restore
    case export
}

public struct CLISessionOptions: Sendable, Equatable {
    public var action: CLISessionAction
    public var identifier: String?
    public var output: String?
    public var json: Bool
    public var fork: Bool
    /// `-n`/`--limit`, defaulting to 20 as in `sessions_cmd.rs`.
    public var limit: Int
    /// The `sessions search` query.
    public var query: String?
    public var common: CLICommonOptions

    public init(
        action: CLISessionAction = .list,
        identifier: String? = nil,
        output: String? = nil,
        json: Bool = false,
        fork: Bool = false,
        limit: Int = 20,
        query: String? = nil,
        common: CLICommonOptions = CLICommonOptions()
    ) {
        self.action = action
        self.identifier = identifier
        self.output = output
        self.json = json
        self.fork = fork
        self.limit = limit
        self.query = query
        self.common = common
    }
}

public enum CLIModelAction: String, Sendable, Equatable {
    case list
    case `default`
}

public struct CLIModelsOptions: Sendable, Equatable {
    public var action: CLIModelAction
    public var json: Bool

    public init(action: CLIModelAction = .list, json: Bool = false) {
        self.action = action
        self.json = json
    }
}

public struct CLIDoctorOptions: Sendable, Equatable {
    public var json: Bool
    /// `doctor fix [ID]`.
    public var fix: Bool
    public var fixID: String?
    /// `-y`/`--yes`.
    public var assumeYes: Bool
    public var common: CLICommonOptions

    public init(
        json: Bool = false,
        fix: Bool = false,
        fixID: String? = nil,
        assumeYes: Bool = false,
        common: CLICommonOptions = CLICommonOptions()
    ) {
        self.json = json
        self.fix = fix
        self.fixID = fixID
        self.assumeYes = assumeYes
        self.common = common
    }
}

public struct CLIResourceOptions: Sendable, Equatable {
    public var action: String
    public var target: String?
    public var values: [String]
    public var options: [String: String]
    /// Repeatable options (`-e/--env`, `-H/--header`, `--argument`), which a
    /// flat dictionary cannot hold.
    public var repeatedOptions: [String: [String]]
    public var json: Bool
    public var force: Bool
    public var common: CLICommonOptions

    public init(
        action: String,
        target: String? = nil,
        values: [String] = [],
        options: [String: String] = [:],
        repeatedOptions: [String: [String]] = [:],
        json: Bool = false,
        force: Bool = false,
        common: CLICommonOptions = CLICommonOptions()
    ) {
        self.action = action
        self.target = target
        self.values = values
        self.options = options
        self.repeatedOptions = repeatedOptions
        self.json = json
        self.force = force
        self.common = common
    }
}

public struct CLIUtilityOptions: Sendable, Equatable {
    public var name: String
    public var values: [String]
    public var options: [String: String]
    public var flags: Set<String>
    public var json: Bool
    public var force: Bool
    public var common: CLICommonOptions

    public init(
        name: String,
        values: [String] = [],
        options: [String: String] = [:],
        flags: Set<String> = [],
        json: Bool = false,
        force: Bool = false,
        common: CLICommonOptions = CLICommonOptions()
    ) {
        self.name = name
        self.values = values
        self.options = options
        self.flags = flags
        self.json = json
        self.force = force
        self.common = common
    }

    /// Boolean flags are recorded twice — in ``flags`` and as `"true"` in
    /// ``options`` — so the pre-existing `options["--codex"] == "true"` readers
    /// in the auth composition keep working unchanged.
    public func isSet(_ flag: String) -> Bool {
        flags.contains(flag)
    }
}

public struct CLIReleaseValidationArtifact: Sendable, Equatable {
    public var name: String
    public var artifactPath: String
    public var sidecarPath: String

    public init(name: String, artifactPath: String, sidecarPath: String) {
        self.name = name
        self.artifactPath = artifactPath
        self.sidecarPath = sidecarPath
    }
}

public struct CLIReleaseValidationOptions: Sendable, Equatable {
    public var binaryPath: String
    public var expectedVersion: String
    public var expectedShortCommit: String?
    public var isolatedRoot: String
    public var artifacts: [CLIReleaseValidationArtifact]

    public init(
        binaryPath: String,
        expectedVersion: String,
        expectedShortCommit: String? = nil,
        isolatedRoot: String,
        artifacts: [CLIReleaseValidationArtifact] = []
    ) {
        self.binaryPath = binaryPath
        self.expectedVersion = expectedVersion
        self.expectedShortCommit = expectedShortCommit
        self.isolatedRoot = isolatedRoot
        self.artifacts = artifacts
    }
}

public enum CLICommand: Sendable, Equatable {
    case version(json: Bool)
    case help(topic: String?)
    case paths(json: Bool)
    case inspect(json: Bool)
    case doctor(CLIDoctorOptions)
    case completions(shell: String)
    case launch(CLIExecutionOptions)
    case serve(CLIServeOptions)
    case leader(CLILeaderOptions)
    case sessions(CLISessionOptions)
    case models(CLIModelsOptions)
    case plugin(CLIResourceOptions)
    case mcp(CLIResourceOptions)
    case workflow(CLIResourceOptions)
    case utility(CLIUtilityOptions)
    case releaseValidate(CLIReleaseValidationOptions)
    case invalid(CLIParseError)

    public var routeName: String {
        switch self {
        case .version: return "version"
        case .help: return "help"
        case .paths: return "paths"
        case .inspect: return "inspect"
        case .doctor: return "doctor"
        case .completions: return "completions"
        case .launch(let options): return options.mode.rawValue
        case .serve: return "serve"
        case .leader: return "leader"
        case .sessions: return "sessions"
        case .models: return "models"
        case .plugin: return "plugin"
        case .mcp: return "mcp"
        case .workflow: return "workflow"
        case .utility(let options): return options.name
        case .releaseValidate: return "release-validate"
        case .invalid: return "invalid"
        }
    }
}

public enum CLICommandParser {
    public static func parse(
        _ args: [String],
        environment: [String: String] = [:]
    ) -> CLICommand {
        do {
            return try parseOrThrow(args, environment: environment)
        } catch let error as CLIParseError {
            return .invalid(error)
        } catch {
            return .invalid(.unexpectedArgument(String(describing: error)))
        }
    }

    /// Every word that starts a subcommand. A bare token is only treated as a
    /// subcommand when it is the first non-option token on the line; anything
    /// else is the positional `PROMPT`, which is what makes
    /// `open-grok "fix the bug"` work.
    private static let subcommandNames: Set<String> = [
        "version", "v", "help", "paths", "path", "inspect", "doctor", "completions",
        "interactive", "minimal", "headless", "acp", "serve", "leader", "agent",
        "session", "sessions", "model", "models", "plugin", "mcp", "workflow",
        "release-validate",
        "login", "logout", "setup", "share", "wrap", "export", "trace", "update",
        "memory", "dashboard", "workspace", "worktree"
    ]

    public static func parseOrThrow(
        _ args: [String],
        environment: [String: String] = [:]
    ) throws -> CLICommand {
        guard !args.isEmpty else {
            return .launch(try parseLaunch([], mode: .interactive, environment: environment))
        }
        return try parseRoot(args, environment: environment)
    }

    /// The root parser. Unlike a switch on `args[0]`, this walks the line the
    /// way clap does: root options are consumed wherever they appear, the first
    /// bare token either names a subcommand or becomes the positional prompt,
    /// and root options collected before a subcommand are handed down to it.
    private static func parseRoot(
        _ args: [String],
        environment: [String: String]
    ) throws -> CLICommand {
        var state = LaunchState(mode: .interactive, enteredViaModeWord: false)
        var cursor = ArgumentCursor(args)
        while let token = cursor.pop() {
            if token == "--" {
                state.positional.append(contentsOf: cursor.remaining())
                break
            }
            guard let option = OptionToken(token) else {
                if state.positional.isEmpty, subcommandNames.contains(token) {
                    return try dispatchSubcommand(
                        token,
                        args: cursor.remaining(),
                        root: state,
                        environment: environment
                    )
                }
                state.positional.append(token)
                continue
            }
            try state.consume(option, cursor: &cursor)
        }
        if state.helpIntent { return .help(topic: nil) }
        if state.versionIntent { return .version(json: false) }
        return .launch(try state.finish(environment: environment))
    }

    private static func dispatchSubcommand(
        _ name: String,
        args: [String],
        root: LaunchState,
        environment: [String: String]
    ) throws -> CLICommand {
        // clap gives the early intents priority over the subcommand, and names
        // the subcommand as the help topic when both are present.
        if root.helpIntent { return .help(topic: name) }
        if root.versionIntent { return .version(json: false) }
        // `open-grok mcp --help` has to reach that subcommand's help rather
        // than its option grammar, where `--help` reads as a malformed action.
        // `wrap` is excluded because every one of its arguments belongs to the
        // child process, and tokens after `--` are values, not options.
        if name != "wrap" {
            let beforeSeparator = args.prefix { $0 != "--" }
            if beforeSeparator.contains("--help") || beforeSeparator.contains("-h") {
                return .help(topic: name)
            }
        }
        let common = root.common
        switch name {
        case "version", "v":
            return .version(json: try parseJSONFlag(args))
        case "help":
            return .help(topic: try parseHelpTopic(args))
        case "paths", "path":
            return .paths(json: try parseJSONFlag(args))
        case "inspect":
            return .inspect(json: try parseJSONFlag(args))
        case "doctor":
            return .doctor(try parseDoctor(args, common: common))
        case "completions":
            return try parseCompletions(args)
        case "interactive":
            return .launch(try parseLaunch(args, mode: .interactive, seed: common, environment: environment))
        case "minimal":
            return .launch(try parseLaunch(args, mode: .minimal, seed: common, environment: environment))
        case "headless":
            return .launch(try parseLaunch(args, mode: .headless, seed: common, environment: environment))
        case "acp":
            return .launch(try parseLaunch(args, mode: .acp, seed: common, environment: environment))
        case "serve":
            return .serve(try parseServe(args, seed: common, environment: environment))
        case "leader":
            return .leader(try parseLeader(args, seed: common))
        case "agent":
            return try parseAgent(args, seed: common, environment: environment)
        case "session", "sessions":
            return .sessions(try parseSessions(args, common: common))
        case "model", "models":
            return .models(try parseModels(args))
        case "plugin":
            return .plugin(try parseResource(args, command: "plugin", common: common))
        case "mcp":
            return .mcp(try parseResource(args, command: "mcp", common: common))
        case "workflow":
            return .workflow(try parseResource(args, command: "workflow", common: common))
        case "release-validate":
            return .releaseValidate(try parseReleaseValidation(args))
        default:
            return .utility(try parseUtility(args, name: name, common: common))
        }
    }

    private static func parseLaunch(
        _ args: [String],
        mode initialMode: CLIRunMode,
        seed: CLICommonOptions = CLICommonOptions(),
        environment: [String: String]
    ) throws -> CLIExecutionOptions {
        var state = LaunchState(mode: initialMode, enteredViaModeWord: true)
        state.common = seed
        var cursor = ArgumentCursor(args)
        while let token = cursor.pop() {
            if token == "--" {
                state.positional.append(contentsOf: cursor.remaining())
                break
            }
            guard let option = OptionToken(token) else {
                state.positional.append(token)
                continue
            }
            try state.consume(option, cursor: &cursor)
        }
        return try state.finish(environment: environment)
    }

    private static func parseServe(
        _ args: [String],
        seed: CLICommonOptions = CLICommonOptions(),
        environment: [String: String]
    ) throws -> CLIServeOptions {
        var cursor = ArgumentCursor(args)
        var common = seed
        var bind = "127.0.0.1:2419"
        var secret: String?
        var remote: String?
        var origin: String?
        var url: String?
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else { throw CLIParseError.unexpectedArgument(token) }
            if try consumeCommon(option, cursor: &cursor, common: &common, environment: environment) { continue }
            switch option.name {
            case "--bind": bind = try cursor.value(for: option)
            case "--secret": secret = try cursor.value(for: option)
            case "--remote": remote = try cursor.value(for: option)
            case "--grok-ws-origin": origin = try cursor.value(for: option)
            case "--grok-ws-url": url = try cursor.value(for: option)
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        // `#[arg(env = "GROK_AGENT_SECRET")]` upstream: the flag wins, the
        // environment fills in, and an empty value counts as unset.
        if secret == nil, let inherited = environment["GROK_AGENT_SECRET"], !inherited.isEmpty {
            secret = inherited
        }
        return CLIServeOptions(
            common: common, bind: bind, secret: secret, remote: remote,
            grokWSOrigin: origin, grokWSURL: url
        )
    }

    private static func parseLeader(
        _ args: [String],
        seed: CLICommonOptions = CLICommonOptions()
    ) throws -> CLILeaderOptions {
        var cursor = ArgumentCursor(args)
        var common = seed
        var noExit = false
        var relay = false
        var noAutoUpdate = false
        var origin: String?
        var url: String?
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else { throw CLIParseError.unexpectedArgument(token) }
            if try consumeCommon(option, cursor: &cursor, common: &common, environment: [:]) { continue }
            switch option.name {
            case "--no-exit-on-disconnect": noExit = true
            case "--relay-on-demand": relay = true
            case "--no-auto-update": noAutoUpdate = true
            case "--grok-ws-origin": origin = try cursor.value(for: option)
            case "--grok-ws-url": url = try cursor.value(for: option)
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        if common.leader && common.noLeader {
            throw CLIParseError.conflictingOptions("--leader", "--no-leader")
        }
        return CLILeaderOptions(
            common: common, noExitOnDisconnect: noExit, relayOnDemand: relay,
            noAutoUpdate: noAutoUpdate, grokWSOrigin: origin, grokWSURL: url
        )
    }

    private static func parseAgent(
        _ args: [String],
        seed: CLICommonOptions,
        environment: [String: String]
    ) throws -> CLICommand {
        guard let first = args.first else {
            return .launch(try parseLaunch([], mode: .interactive, seed: seed, environment: environment))
        }
        switch first {
        case "stdio", "acp":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .acp, seed: seed, environment: environment))
        case "headless":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .headless, seed: seed, environment: environment))
        case "serve":
            return .serve(try parseServe(Array(args.dropFirst()), seed: seed, environment: environment))
        case "leader":
            return .leader(try parseLeader(Array(args.dropFirst()), seed: seed))
        default:
            return .launch(try parseLaunch(args, mode: .interactive, seed: seed, environment: environment))
        }
    }

    private static func parseSessions(
        _ args: [String],
        common: CLICommonOptions
    ) throws -> CLISessionOptions {
        var cursor = ArgumentCursor(args)
        var action: CLISessionAction = .list
        var identifier: String?
        var output: String?
        var json = false
        var fork = false
        var limit = 20
        var query: String?
        if let first = cursor.peek, !first.hasPrefix("-") {
            _ = cursor.pop()
            guard let parsed = CLISessionAction(rawValue: first) else { throw CLIParseError.unknownCommand(first) }
            action = parsed
        }
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else {
                // `search` takes the query first, then an optional id; every
                // other action takes only an identifier.
                if action == .search, query == nil {
                    query = token
                } else if identifier == nil {
                    identifier = token
                } else {
                    throw CLIParseError.unexpectedArgument(token)
                }
                continue
            }
            switch option.name {
            case "--json": json = true
            case "--fork": fork = true
            case "--output", "-o": output = try cursor.value(for: option)
            case "--id", "--session-id": identifier = try cursor.value(for: option)
            case "--limit", "-n":
                let value = try cursor.numericValue(for: option)
                guard let parsed = Int(value), parsed >= 1 else {
                    throw CLIParseError.invalidValue(
                        option: option.name, value: value, expected: "a positive integer"
                    )
                }
                limit = parsed
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        if action == .list && fork {
            throw CLIParseError.invalidValue(
                option: "--fork", value: "true", expected: "a resume or restore action"
            )
        }
        if action == .search && (query?.isEmpty ?? true) {
            throw CLIParseError.missingValue("sessions search query")
        }
        return CLISessionOptions(
            action: action, identifier: identifier, output: output, json: json,
            fork: fork, limit: limit, query: query, common: common
        )
    }

    private static func parseModels(_ args: [String]) throws -> CLIModelsOptions {
        var cursor = ArgumentCursor(args)
        var action = CLIModelAction.list
        var json = false
        if let first = cursor.peek, !first.hasPrefix("-") {
            _ = cursor.pop()
            guard let parsed = CLIModelAction(rawValue: first) else { throw CLIParseError.unknownCommand(first) }
            action = parsed
        }
        while let token = cursor.pop() {
            guard let option = OptionToken(token), option.name == "--json" else {
                throw CLIParseError.unknownOption(token)
            }
            json = true
        }
        return CLIModelsOptions(action: action, json: json)
    }

    private static func parseDoctor(
        _ args: [String],
        common: CLICommonOptions
    ) throws -> CLIDoctorOptions {
        var cursor = ArgumentCursor(args)
        var json = false
        var fix = false
        var fixID: String?
        var assumeYes = false
        if cursor.peek == "fix" {
            _ = cursor.pop()
            fix = true
        }
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else {
                guard fix else { throw CLIParseError.unexpectedArgument(token) }
                guard fixID == nil else { throw CLIParseError.unexpectedArgument(token) }
                fixID = token
                continue
            }
            switch option.name {
            case "--json": json = true
            case "--yes", "-y": assumeYes = true
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        if assumeYes && !fix {
            throw CLIParseError.requiresOption("--yes", "the 'doctor fix' subcommand")
        }
        return CLIDoctorOptions(json: json, fix: fix, fixID: fixID, assumeYes: assumeYes, common: common)
    }

    /// Per-command option grammars. Keeping these explicit is what turns a
    /// misspelled flag into a usage error at parse time instead of an argument
    /// silently ignored by a route that later refuses anyway.
    private struct ResourceGrammar {
        /// Options taking a value, keyed by every accepted spelling.
        var valued: [String: String] = [:]
        /// Options taking a value that may be repeated.
        var repeated: [String: String] = [:]
        /// Boolean flags, keyed by every accepted spelling.
        var flags: [String: String] = [:]
        /// Whether trailing bare tokens beyond the target are allowed.
        var acceptsTrailingValues = false
    }

    private static func resourceGrammar(command: String, action: String) -> ResourceGrammar? {
        var grammar = ResourceGrammar()
        switch command {
        case "mcp":
            // `--config <path>` names the file every `mcp` action reads or
            // writes, so it belongs on all of them, not just `add`.
            // `LiveMCPComposition.editTarget` is the shared resolver and its own
            // doc comment records that this port uses `--config` where upstream
            // uses `--scope`. Restricting it to `add` broke `mcp remove …
            // --config <path>`, which is how the PTY harness isolates itself
            // from the developer's real config.
            let configFile = ["--config": "--config"]
            switch action {
            case "list":
                grammar.valued = configFile
                grammar.flags = ["--json": "--json"]
            case "get", "remove", "enable", "disable":
                grammar.valued = configFile.merging(
                    ["--scope": "--scope", "-s": "--scope"]
                ) { current, _ in current }
                grammar.flags = ["--json": "--json"]
            case "login":
                // The MCP OAuth trigger (LiveMCPComposition.runLogin) reads
                // config like `get`; it takes no flags beyond `--config`.
                grammar.valued = configFile
            case "doctor":
                grammar.valued = configFile
                grammar.flags = ["--json": "--json"]
            case "add":
                grammar.valued = [
                    "--transport": "--transport", "-t": "--transport",
                    "--scope": "--scope", "-s": "--scope",
                    // Retained from this port's earlier grammar so existing
                    // callers and tests keep working.
                    "--command": "--command", "--url": "--url", "--source": "--source",
                    "--config": "--config"
                ]
                grammar.repeated = [
                    "--env": "--env", "-e": "--env",
                    "--header": "--header", "-H": "--header"
                ]
                grammar.flags = ["--json": "--json", "--force": "--force"]
                grammar.acceptsTrailingValues = true
            default:
                return nil
            }
        case "plugin":
            switch action {
            case "list":
                grammar.flags = ["--json": "--json", "--available": "--available"]
            case "install":
                grammar.valued = ["--source": "--source"]
                grammar.flags = ["--trust": "--trust", "--json": "--json", "--force": "--force"]
            case "uninstall", "rm", "remove":
                grammar.flags = ["--confirm": "--confirm", "--keep-data": "--keep-data", "--force": "--force"]
            case "update", "enable", "disable", "details":
                grammar.flags = ["--json": "--json"]
            case "validate":
                grammar.flags = ["--json": "--json"]
            case "tag":
                grammar.flags = [
                    "--push": "--push", "--force": "--force", "-f": "--force",
                    "--dry-run": "--dry-run"
                ]
            case "marketplace":
                grammar.valued = ["--source": "--source", "--url": "--url"]
                grammar.flags = ["--json": "--json", "--force": "--force"]
                grammar.acceptsTrailingValues = true
            default:
                return nil
            }
        case "workflow":
            // Swift-only surface with no Rust counterpart; keep the permissive
            // grammar it shipped with rather than inventing restrictions.
            grammar.valued = [
                "--source": "--source", "--url": "--url", "--command": "--command",
                "--transport": "--transport", "--config": "--config",
                "--argument": "--argument",
                "--output": "--output", "-o": "--output"
            ]
            grammar.flags = ["--json": "--json", "--force": "--force"]
            grammar.acceptsTrailingValues = true
        default:
            return nil
        }
        return grammar
    }

    private static func parseResource(
        _ args: [String],
        command: String,
        common: CLICommonOptions
    ) throws -> CLIResourceOptions {
        var cursor = ArgumentCursor(args)
        guard let action = cursor.pop(), !action.hasPrefix("-") else {
            throw CLIParseError.missingSubcommand(command)
        }
        guard let grammar = resourceGrammar(command: command, action: action) else {
            throw CLIParseError.unknownCommand(action)
        }
        var target: String?
        var values: [String] = []
        var options: [String: String] = [:]
        var repeatedOptions: [String: [String]] = [:]
        var json = false
        var force = false
        while let token = cursor.pop() {
            // `mcp add NAME CMD -- ARGS…` hands everything after `--` to the
            // server process, so it must not be parsed as options here.
            if token == "--", grammar.acceptsTrailingValues {
                values.append(contentsOf: cursor.remaining())
                break
            }
            guard let option = OptionToken(token) else {
                if target == nil {
                    target = token
                } else if grammar.acceptsTrailingValues {
                    values.append(token)
                } else {
                    throw CLIParseError.unexpectedArgument(token)
                }
                continue
            }
            if let canonical = grammar.valued[option.name] {
                options[canonical] = try cursor.value(for: option)
            } else if let canonical = grammar.repeated[option.name] {
                repeatedOptions[canonical, default: []].append(try cursor.value(for: option))
            } else if let canonical = grammar.flags[option.name] {
                switch canonical {
                case "--json": json = true
                case "--force": force = true
                default: options[canonical] = "true"
                }
            } else {
                throw CLIParseError.unknownOption(option.name)
            }
        }
        if command == "plugin", action == "list", options["--available"] == "true", !json {
            throw CLIParseError.requiresOption("--available", "--json")
        }
        return CLIResourceOptions(
            action: action, target: target, values: values, options: options,
            repeatedOptions: repeatedOptions, json: json, force: force, common: common
        )
    }

    private struct UtilityGrammar {
        var valued: [String: String] = [:]
        var flags: [String: String] = [:]
        var conflicts: [(String, String)] = []
    }

    private static func utilityGrammar(_ name: String) -> UtilityGrammar {
        var grammar = UtilityGrammar()
        switch name {
        case "login":
            // `--json` is not in upstream's `login`, but this composition's auth
            // route already honors it to suppress its human-readable lines, so
            // rejecting it here would break a path that works.
            grammar.flags = [
                "--legacy": "--legacy", "--oauth": "--oauth", "--oidc": "--oauth",
                "--codex": "--codex", "--device-auth": "--device-auth",
                "--device-code": "--device-auth", "--json": "--json"
            ]
            grammar.conflicts = [("--oauth", "--device-auth"), ("--oauth", "--codex")]
        case "logout":
            grammar.flags = ["--codex": "--codex", "--all": "--all", "--json": "--json"]
            grammar.conflicts = [("--codex", "--all")]
        case "setup":
            grammar.flags = ["--json": "--json"]
        case "export":
            grammar.flags = ["--clipboard": "--clipboard", "-c": "--clipboard"]
        case "trace":
            grammar.valued = ["--output": "--output", "-o": "--output"]
            grammar.flags = ["--local": "--local", "--json": "--json"]
        case "update":
            grammar.valued = ["--version": "--version"]
            grammar.flags = [
                "--check": "--check", "--json": "--json",
                "--force-reinstall": "--force-reinstall", "--force": "--force",
                "--alpha": "--alpha", "--stable": "--stable", "--enterprise": "--enterprise"
            ]
            grammar.conflicts = [
                ("--alpha", "--stable"), ("--alpha", "--enterprise"), ("--stable", "--enterprise")
            ]
        case "memory":
            grammar.flags = [
                "--workspace": "--workspace", "--global": "--global", "--all": "--all",
                "--yes": "--yes", "-y": "--yes"
            ]
        case "workspace":
            grammar.valued = [
                "--hub-url": "--hub-url", "--cwd": "--cwd", "--pid": "--pid"
            ]
            grammar.flags = [
                "--leader": "--leader", "--no-leader": "--no-leader", "--json": "--json"
            ]
            grammar.conflicts = [("--leader", "--no-leader")]
        case "worktree":
            grammar.valued = [
                "--repo": "--repo", "--type": "--type", "--max-age": "--max-age"
            ]
            grammar.flags = [
                "--json": "--json", "--all": "--all", "--dry-run": "--dry-run",
                "--force": "--force", "-f": "--force"
            ]
        default:
            break
        }
        return grammar
    }

    /// Subcommand words each utility accepts, so `memory clean` is a usage
    /// error rather than a silently-dropped argument.
    private static let utilitySubcommands: [String: Set<String>] = [
        "memory": ["clear"],
        "workspace": ["start", "pause", "resume", "stop", "restart", "status", "list"],
        "worktree": ["list", "ls", "show", "rm", "gc", "prune", "db"]
    ]

    private static func parseUtility(
        _ args: [String],
        name: String,
        common: CLICommonOptions
    ) throws -> CLIUtilityOptions {
        // `wrap` is `trailing_var_arg` + `allow_hyphen_values`: everything after
        // the command word belongs to the child process, flags included.
        if name == "wrap" {
            guard !args.isEmpty else { throw CLIParseError.missingValue("wrap command") }
            return CLIUtilityOptions(name: name, values: args, common: common)
        }
        let grammar = utilityGrammar(name)
        var cursor = ArgumentCursor(args)
        var values: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var json = false
        var force = false
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else {
                if values.isEmpty, let allowed = utilitySubcommands[name], !allowed.contains(token) {
                    throw CLIParseError.unknownCommand(token)
                }
                values.append(token)
                continue
            }
            if let canonical = grammar.valued[option.name] {
                options[canonical] = try cursor.value(for: option)
            } else if let canonical = grammar.flags[option.name] {
                flags.insert(canonical)
                options[canonical] = "true"
                if canonical == "--json" { json = true }
                if canonical == "--force" { force = true }
            } else {
                throw CLIParseError.unknownOption(option.name)
            }
        }
        for (first, second) in grammar.conflicts where flags.contains(first) && flags.contains(second) {
            throw CLIParseError.conflictingOptions(first, second)
        }
        if utilitySubcommands[name] != nil, values.isEmpty {
            throw CLIParseError.missingSubcommand(name)
        }
        if name == "worktree" {
            try validateWorktreeGrammar(values: values, options: options, flags: flags)
        }
        return CLIUtilityOptions(
            name: name, values: values, options: options, flags: flags,
            json: json, force: force, common: common
        )
    }

    private static func validateWorktreeGrammar(
        values: [String],
        options: [String: String],
        flags: Set<String>
    ) throws {
        guard let action = values.first else { return }
        let allowedOptions: Set<String>
        let allowedFlags: Set<String>
        switch action {
        case "list", "ls":
            guard values.count == 1 else {
                throw CLIParseError.unexpectedArgument("worktree list accepts no positional targets")
            }
            allowedOptions = ["--repo", "--type"]
            allowedFlags = ["--json", "--all"]
        case "show":
            guard values.count == 2 else {
                throw CLIParseError.unexpectedArgument("worktree show requires one id or path")
            }
            allowedOptions = []
            allowedFlags = ["--json"]
        case "rm":
            guard values.count >= 2 else {
                throw CLIParseError.unexpectedArgument("worktree rm requires at least one id or path")
            }
            allowedOptions = []
            allowedFlags = ["--json", "--dry-run", "--force"]
        case "gc", "prune":
            guard values.count == 1 else {
                throw CLIParseError.unexpectedArgument("worktree gc accepts no positional targets")
            }
            allowedOptions = ["--max-age"]
            allowedFlags = ["--json", "--dry-run", "--force"]
        case "db":
            guard values.count == 2, ["rebuild", "stats", "path"].contains(values[1]) else {
                throw CLIParseError.unexpectedArgument(
                    "worktree db requires rebuild, stats, or path"
                )
            }
            allowedOptions = []
            allowedFlags = ["--json"]
        default:
            return
        }
        for key in options.keys where !allowedOptions.contains(key) && !allowedFlags.contains(key) {
            throw CLIParseError.unexpectedArgument(
                "worktree " + action + " does not accept " + key
            )
        }
        for flag in flags where !allowedFlags.contains(flag) {
            throw CLIParseError.unexpectedArgument(
                "worktree " + action + " does not accept " + flag
            )
        }
    }

    private static func parseCompletions(_ args: [String]) throws -> CLICommand {
        guard args.count == 1, let shell = args.first, !shell.hasPrefix("-") else {
            throw CLIParseError.invalidValue(
                option: "completions", value: args.joined(separator: " "), expected: "one shell name"
            )
        }
        let supported = ["bash", "zsh", "fish", "powershell", "elvish"]
        guard supported.contains(shell.lowercased()) else {
            throw CLIParseError.invalidValue(
                option: "completions", value: shell, expected: supported.joined(separator: ", ")
            )
        }
        return .completions(shell: shell.lowercased())
    }

    private static func parseReleaseValidation(
        _ args: [String]
    ) throws -> CLIReleaseValidationOptions {
        var cursor = ArgumentCursor(args)
        var binaryPath: String?
        var expectedVersion: String?
        var expectedShortCommit: String?
        var isolatedRoot: String?
        var artifacts: [CLIReleaseValidationArtifact] = []
        var pendingArtifact: (name: String, path: String)?

        while let token = cursor.pop() {
            guard let option = OptionToken(token) else {
                throw CLIParseError.unexpectedArgument(token)
            }
            switch option.name {
            case "--binary":
                binaryPath = try cursor.value(for: option)
            case "--expected-version":
                expectedVersion = try cursor.value(for: option)
            case "--expected-commit":
                expectedShortCommit = try cursor.value(for: option)
            case "--isolated-root":
                isolatedRoot = try cursor.value(for: option)
            case "--artifact":
                guard pendingArtifact == nil else {
                    throw CLIParseError.requiresOption("--artifact", "--sidecar")
                }
                let specification = try cursor.value(for: option)
                guard let separator = specification.firstIndex(of: "=") else {
                    throw CLIParseError.invalidValue(
                        option: option.name,
                        value: specification,
                        expected: "NAME=ARTIFACT_PATH"
                    )
                }
                let name = String(specification[..<separator])
                let path = String(specification[specification.index(after: separator)...])
                guard !name.isEmpty, !path.isEmpty else {
                    throw CLIParseError.invalidValue(
                        option: option.name,
                        value: specification,
                        expected: "NAME=ARTIFACT_PATH"
                    )
                }
                pendingArtifact = (name, path)
            case "--sidecar":
                guard let pair = pendingArtifact else {
                    throw CLIParseError.requiresOption("--sidecar", "--artifact")
                }
                artifacts.append(
                    CLIReleaseValidationArtifact(
                        name: pair.name,
                        artifactPath: pair.path,
                        sidecarPath: try cursor.value(for: option)
                    )
                )
                pendingArtifact = nil
            default:
                throw CLIParseError.unknownOption(option.name)
            }
        }

        if pendingArtifact != nil {
            throw CLIParseError.requiresOption("--artifact", "--sidecar")
        }
        guard let binaryPath else {
            throw CLIParseError.requiresOption("release-validate", "--binary")
        }
        guard let expectedVersion else {
            throw CLIParseError.requiresOption("release-validate", "--expected-version")
        }
        guard let isolatedRoot else {
            throw CLIParseError.requiresOption("release-validate", "--isolated-root")
        }
        return CLIReleaseValidationOptions(
            binaryPath: binaryPath,
            expectedVersion: expectedVersion,
            expectedShortCommit: expectedShortCommit,
            isolatedRoot: isolatedRoot,
            artifacts: artifacts
        )
    }

    fileprivate static func consumeCommon(
        _ option: OptionToken,
        cursor: inout ArgumentCursor,
        common: inout CLICommonOptions,
        environment: [String: String]
    ) throws -> Bool {
        switch option.name {
        case "--cwd": common.cwd = try cursor.value(for: option)
        case "--model", "-m": common.model = try cursor.value(for: option)
        case "--provider": common.provider = try cursor.value(for: option)
        case "--runinfra": common.provider = "runinfra"
        case "--gemini", "--google": common.provider = "gemini"
        case "--openrouter": common.provider = "openrouter"
        case "--profile", "--agent-profile": common.profile = try cursor.value(for: option)
        case "--plugin-dir": common.pluginDirectories.append(try cursor.value(for: option))
        case "--mcp-config": common.mcpConfig = try cursor.value(for: option)
        case "--workflow": common.workflow = try cursor.value(for: option)
        case "--leader": common.leader = true
        case "--no-leader": common.noLeader = true
        case "--debug": common.debug = true
        case "--debug-file": common.debugFile = try cursor.value(for: option)
        case "--leader-socket": common.leaderSocket = try cursor.value(for: option)
        case "--allow", "--allowedTools":
            common.permissions.allowRules.append(contentsOf: splitRules(try cursor.value(for: option)))
        case "--deny", "--disallowedTools":
            common.permissions.denyRules.append(contentsOf: splitRules(try cursor.value(for: option)))
        case "--permission-mode":
            let value = try cursor.value(for: option)
            guard let parsed = CLIPermissionMode(rawValue: value) else {
                throw CLIParseError.invalidValue(
                    option: option.name,
                    value: value,
                    expected: CLIPermissionMode.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            common.permissions.mode = parsed
        case "--always-approve", "--yolo", "--dangerously-skip-permissions":
            common.permissions.alwaysApprove = true
        case "--trust", "--trust-folder":
            common.permissions.trustFolder = true
        case "--sandbox":
            common.permissions.sandboxProfile = try cursor.value(for: option)
        default:
            return false
        }
        return true
    }

    /// clap's `value_delimiter = ','`: a single occurrence may carry several
    /// rules, and empty segments are dropped rather than becoming empty rules.
    private static func splitRules(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Applies the `GROK_SANDBOX` fallback once the whole line is parsed, so an
    /// explicit `--sandbox` always wins.
    fileprivate static func applySandboxEnvironment(
        _ common: inout CLICommonOptions,
        environment: [String: String]
    ) {
        guard common.permissions.sandboxProfile == nil else { return }
        guard let inherited = environment["GROK_SANDBOX"], !inherited.isEmpty else { return }
        common.permissions.sandboxProfile = inherited
    }

    private static func parseJSONFlag(_ args: [String]) throws -> Bool {
        guard args.count <= 1 else { throw CLIParseError.unexpectedArgument(args[1]) }
        guard let value = args.first else { return false }
        guard value == "--json" else { throw CLIParseError.unknownOption(value) }
        return true
    }

    private static func parseHelpTopic(_ args: [String]) throws -> String? {
        guard let first = args.first, !first.hasPrefix("-") else {
            if let first = args.first { throw CLIParseError.unknownOption(first) }
            return nil
        }
        if args.count > 1 { throw CLIParseError.unexpectedArgument(args[1]) }
        return first
    }
}

/// Accumulates a launch line. Shared by the root parser and the mode-word
/// parsers so both accept exactly the same option set.
fileprivate struct LaunchState {
    var common = CLICommonOptions()
    var mode: CLIRunMode
    /// `true` when this port's `interactive`/`minimal`/`headless`/`acp` word
    /// selected the mode. At the root there is no such word, so a prompt source
    /// is what makes the run headless — which is how `open-grok -p "…"` works.
    let enteredViaModeWord: Bool
    var single: String?
    var promptJSON: String?
    var promptFile: String?
    var outputFormat = CLIOutputFormat.plain
    var sessionID: String?
    var resume: String?
    var loadSession: String?
    var continueSession = false
    var forkSession = false
    var noAltScreen = false
    var fullscreen = false
    var minimalRendering = false
    var restoreCode = false
    var worktree: String?
    var worktreeRef: String?
    var verbatim = false
    var includePartialMessages = false
    var jsonSchema: String?
    var chat = false
    var localWorkspace: String?
    var localWorkspaceAttach: String?
    var localWorkspaceCWD: String?
    var oauth = false
    var agentOptions = CLIAgentOptions()
    var advanced = CLIAdvancedOptions()
    var positional: [String] = []
    var helpIntent = false
    var versionIntent = false

    init(mode: CLIRunMode, enteredViaModeWord: Bool) {
        self.mode = mode
        self.enteredViaModeWord = enteredViaModeWord
    }

    mutating func consume(_ option: OptionToken, cursor: inout ArgumentCursor) throws {
        if try CLICommandParser.consumeCommon(option, cursor: &cursor, common: &common, environment: [:]) {
            return
        }
        switch option.name {
        case "--help", "-h":
            helpIntent = true
        case "--version", "-v", "-V":
            versionIntent = true
        case "--minimal":
            // Under a mode word this selects this port's one-shot minimal mode,
            // the behavior that shipped. At the root it selects upstream's
            // scrollback-native renderer and the session stays interactive.
            if enteredViaModeWord { mode = .minimal } else { minimalRendering = true }
        case "--fullscreen":
            fullscreen = true
        case "--headless":
            mode = .headless
        case "--acp":
            mode = .acp
        case "--prompt", "-p", "--single", "--print":
            single = try cursor.value(for: option)
        case "--prompt-json":
            promptJSON = try cursor.value(for: option)
        case "--prompt-file":
            promptFile = try cursor.value(for: option)
        case "--verbatim":
            verbatim = true
        case "--include-partial-messages":
            includePartialMessages = true
        case "--json-schema":
            jsonSchema = try cursor.value(for: option)
        case "--chat":
            chat = true
        case "--local-workspace":
            localWorkspace = cursor.optionalValue(for: option)
        case "--local-workspace-attach":
            localWorkspaceAttach = try cursor.valueAllowingEmpty(for: option)
        case "--local-workspace-cwd":
            localWorkspaceCWD = try cursor.value(for: option)
        case "--output-format":
            let value = try cursor.value(for: option)
            guard let parsed = CLIOutputFormat(rawValue: value) else {
                throw CLIParseError.invalidValue(
                    option: option.name,
                    value: value,
                    expected: CLIOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            outputFormat = parsed
        case "--session-id", "-s":
            sessionID = try cursor.value(for: option)
        case "--resume", "-r":
            resume = cursor.optionalValue(for: option)
        case "--load":
            loadSession = try cursor.value(for: option)
        case "--continue", "-c":
            continueSession = true
        case "--fork-session":
            forkSession = true
        case "--restore-code":
            restoreCode = true
        case "--worktree", "-w":
            worktree = cursor.optionalValue(for: option)
        case "--worktree-ref", "--ref":
            worktreeRef = try cursor.value(for: option)
        case "--no-alt-screen":
            noAltScreen = true
        case "--oauth":
            oauth = true
        case "--serve":
            mode = .serve
        case "--leader-mode":
            mode = .leader
        case "--reasoning-effort", "--effort":
            agentOptions.reasoningEffort = try cursor.value(for: option)
        case "--rules", "--append-system-prompt":
            agentOptions.rules = try cursor.value(for: option)
        case "--system-prompt-override", "--system-prompt":
            agentOptions.systemPromptOverride = try cursor.value(for: option)
        case "--agent":
            agentOptions.agent = try cursor.value(for: option)
        case "--agents":
            agentOptions.agentsJSON = try cursor.value(for: option)
        case "--tools":
            agentOptions.tools = try cursor.value(for: option)
        case "--disallowed-tools":
            agentOptions.disallowedTools = try cursor.value(for: option)
        case "--max-turns":
            let value = try cursor.numericValue(for: option)
            guard let parsed = UInt32(value), parsed >= 1 else {
                throw CLIParseError.invalidValue(
                    option: option.name, value: value, expected: "an integer of at least 1"
                )
            }
            agentOptions.maxTurns = parsed
        case "--no-plan":
            agentOptions.noPlan = true
        case "--no-subagents":
            agentOptions.noSubagents = true
        case "--no-ask-user":
            agentOptions.noAskUser = true
        case "--experimental-memory":
            agentOptions.experimentalMemory = true
        case "--no-memory":
            agentOptions.noMemory = true
        case "--disable-web-search":
            agentOptions.disableWebSearch = true
        case "--storage-mode":
            advanced.storageMode = try cursor.value(for: option)
        case "--client-identifier":
            advanced.clientIdentifier = try cursor.value(for: option)
        case "--hunk-tracker-mode":
            advanced.hunkTrackerMode = try cursor.value(for: option)
        case "--installer":
            advanced.installer = try cursor.value(for: option)
        case "--compaction-mode":
            advanced.compactionMode = try cursor.value(for: option)
        case "--compaction-detail":
            advanced.compactionDetail = try cursor.value(for: option)
        case "--terminal":
            advanced.terminal = true
        case "--fs-read":
            advanced.fsRead = true
        case "--fs-write":
            advanced.fsWrite = true
        case "--no-auto-update":
            advanced.noAutoUpdate = true
        case "--todo-gate":
            advanced.todoGate = true
        case "--log-sampling":
            advanced.logSampling = true
        case "--force-login":
            advanced.forceLogin = true
        case "--reauth", "--reauthenticate":
            advanced.reauthenticate = true
        case "--cli-chat-proxy-base-url":
            advanced.cliChatProxyBaseURL = try cursor.value(for: option)
        case "--xai-api-base-url":
            advanced.xaiAPIBaseURL = try cursor.value(for: option)
        case "--no-wait-for-background":
            advanced.noWaitForBackground = true
        case "--background-wait-timeout":
            let value = try cursor.numericValue(for: option)
            guard let parsed = UInt64(value), parsed >= 1 else {
                throw CLIParseError.invalidValue(
                    option: option.name, value: value, expected: "an integer of at least 1"
                )
            }
            advanced.backgroundWaitTimeoutSeconds = parsed
        default:
            throw CLIParseError.unknownOption(option.name)
        }
    }

    func finish(environment: [String: String]) throws -> CLIExecutionOptions {
        var common = self.common
        CLICommandParser.applySandboxEnvironment(&common, environment: environment)
        var mode = self.mode
        var prompt = single

        if positional.count > 1 {
            throw CLIParseError.unexpectedArgument(positional[1])
        }
        if let value = positional.first {
            // clap declares the positional PROMPT in conflict with every
            // explicit prompt source, so this is a usage error rather than a
            // silent precedence rule.
            if single != nil || promptJSON != nil || promptFile != nil {
                throw CLIParseError.conflictingOptions("PROMPT", "--prompt/--prompt-json/--prompt-file")
            }
            prompt = value
        }

        let promptSources = [single != nil, promptJSON != nil, promptFile != nil].filter { $0 }.count
        if promptSources > 1 {
            throw CLIParseError.conflictingOptions("--prompt", "--prompt-json/--prompt-file")
        }
        // At the root, an explicit prompt source is what selects the
        // single-turn headless run; the bare positional stays interactive.
        if !enteredViaModeWord, mode == .interactive, promptSources > 0 {
            mode = .headless
        }
        if common.leader && common.noLeader {
            throw CLIParseError.conflictingOptions("--leader", "--no-leader")
        }
        if (mode == .minimal || minimalRendering) && fullscreen {
            throw CLIParseError.conflictingOptions("--minimal", "--fullscreen")
        }
        if mode == .acp && (promptSources > 0 || positional.first != nil) {
            throw CLIParseError.conflictingOptions("ACP", "prompt source")
        }
        if resume != nil && continueSession {
            throw CLIParseError.conflictingOptions("--resume", "--continue")
        }
        if loadSession != nil && continueSession {
            throw CLIParseError.conflictingOptions("--load", "--continue")
        }
        if restoreCode && resume == nil {
            throw CLIParseError.requiresOption("--restore-code", "--resume")
        }
        if worktreeRef != nil && worktree == nil {
            throw CLIParseError.requiresOption("--worktree-ref", "--worktree")
        }
        if forkSession && worktree != nil {
            throw CLIParseError.conflictingOptions("--fork-session", "--worktree")
        }
        if localWorkspace != nil && localWorkspaceAttach != nil {
            throw CLIParseError.conflictingOptions(
                "--local-workspace",
                "--local-workspace-attach"
            )
        }
        if (localWorkspace != nil || localWorkspaceAttach != nil || localWorkspaceCWD != nil), !chat {
            throw CLIParseError.requiresOption("local-workspace flags", "--chat")
        }
        if agentOptions.experimentalMemory && agentOptions.noMemory {
            throw CLIParseError.conflictingOptions("--experimental-memory", "--no-memory")
        }
        // A resumed or continued session already has an id; naming a new one
        // only makes sense when `--fork-session` says the id names the fork.
        if sessionID != nil, resume != nil || loadSession != nil || continueSession, !forkSession {
            throw CLIParseError.requiresOption("--session-id with --resume/--continue", "--fork-session")
        }
        var outputFormat = self.outputFormat
        if jsonSchema != nil {
            // `--json-schema` implies `--output-format json` upstream, and
            // contradicting it explicitly is a usage error rather than a
            // silently overridden choice.
            if self.outputFormat != .plain && self.outputFormat != .json {
                throw CLIParseError.conflictingOptions("--json-schema", "--output-format \(self.outputFormat.rawValue)")
            }
            outputFormat = .json
        }

        return CLIExecutionOptions(
            mode: mode,
            common: common,
            prompt: prompt,
            promptJSON: promptJSON,
            promptFile: promptFile,
            outputFormat: outputFormat,
            sessionID: sessionID,
            resume: resume,
            continueSession: continueSession,
            forkSession: forkSession,
            noAltScreen: noAltScreen,
            fullscreen: fullscreen,
            loadSession: loadSession,
            restoreCode: restoreCode,
            worktree: worktree,
            worktreeRef: worktreeRef,
            verbatim: verbatim,
            includePartialMessages: includePartialMessages,
            jsonSchema: jsonSchema,
            chat: chat,
            localWorkspace: localWorkspace,
            localWorkspaceAttach: localWorkspaceAttach,
            localWorkspaceCWD: localWorkspaceCWD,
            minimalRendering: minimalRendering,
            oauth: oauth,
            agentOptions: agentOptions,
            advanced: advanced
        )
    }
}

fileprivate struct OptionToken: Sendable, Equatable {
    var name: String
    var inlineValue: String?

    init?(_ token: String) {
        guard token.hasPrefix("-"), token != "-" else { return nil }
        if let separator = token.firstIndex(of: "=") {
            name = String(token[..<separator])
            inlineValue = String(token[token.index(after: separator)...])
        } else {
            name = token
            inlineValue = nil
        }
    }
}

fileprivate struct ArgumentCursor: Sendable {
    private var arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    var peek: String? {
        guard index < arguments.count else { return nil }
        return arguments[index]
    }

    mutating func pop() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func value(for option: OptionToken) throws -> String {
        if let inlineValue = option.inlineValue, !inlineValue.isEmpty { return inlineValue }
        guard let value = pop(), !value.isEmpty, !value.hasPrefix("-") else {
            throw CLIParseError.missingValue(option.name)
        }
        return value
    }

    mutating func valueAllowingEmpty(for option: OptionToken) throws -> String {
        if let inlineValue = option.inlineValue { return inlineValue }
        guard let value = pop(), !value.hasPrefix("-") else {
            throw CLIParseError.missingValue(option.name)
        }
        return value
    }

    /// A value for a numeric option, where a leading `-` is a negative number
    /// rather than the next flag. Without this, `--max-turns -1` reports
    /// "requires a value", which sends the reader looking for a missing
    /// argument that is right there.
    mutating func numericValue(for option: OptionToken) throws -> String {
        if let inlineValue = option.inlineValue, !inlineValue.isEmpty { return inlineValue }
        guard let value = peek, !value.isEmpty, Int(value) != nil else {
            return try self.value(for: option)
        }
        _ = pop()
        return value
    }

    /// A value for an option whose value is optional (`num_args = 0..=1`).
    /// An absent value — end of line, or the next token being a flag — is the
    /// empty-string sentinel clap's `default_missing_value` produces, which is
    /// what distinguishes `--resume` (most recent) from `--resume ID`.
    mutating func optionalValue(for option: OptionToken) -> String {
        if let inlineValue = option.inlineValue { return inlineValue }
        guard let next = peek, !next.hasPrefix("-") else { return "" }
        return pop() ?? ""
    }

    mutating func remaining() -> [String] {
        let result = Array(arguments[index...])
        index = arguments.count
        return result
    }
}

private extension CLIOutputFormat {
    static var allCases: [CLIOutputFormat] {
        [.plain, .json, .streamingJSON, .streamingMessagesJSON]
    }
}
