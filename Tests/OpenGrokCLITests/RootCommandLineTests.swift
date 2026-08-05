import Foundation
import Testing
@testable import OpenGrokCLI

/// The root command line: everything upstream accepts before a subcommand.
///
/// Before this suite existed the parser was a switch on `args[0]`, so every
/// form here failed as `unknown command`. These tests are the contract that
/// keeps the primary invocations — `open-grok "prompt"`, `-p`, `-c`, `-r`,
/// `-m` — from regressing back into that shape.
@Suite("Root command line")
struct RootCommandLineTests {
    private func launch(
        _ args: [String],
        environment: [String: String] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(args, environment: environment)
        guard case .launch(let options) = command else {
            Issue.record("expected a launch route, got \(command.routeName)", sourceLocation: sourceLocation)
            throw CLIParseError.unknownCommand(args.first ?? "")
        }
        return options
    }

    private func parseError(_ args: [String], environment: [String: String] = [:]) -> CLIParseError? {
        guard case .invalid(let error) = CLICommandParser.parse(args, environment: environment) else {
            return nil
        }
        return error
    }

    // MARK: - The positional prompt

    @Test("a bare argument is the initial prompt for an interactive session")
    func positionalPrompt() throws {
        let options = try launch(["fix the bug"])
        #expect(options.mode == .interactive)
        #expect(options.prompt == "fix the bug")
    }

    @Test("a positional prompt still parses after root options")
    func positionalPromptAfterOptions() throws {
        let options = try launch(["--cwd", "/tmp/project", "-m", "grok-4.5", "fix the bug"])
        #expect(options.prompt == "fix the bug")
        #expect(options.common.cwd == "/tmp/project")
        #expect(options.common.model == "grok-4.5")
    }

    @Test("a second positional is a usage error, not a silently dropped argument")
    func secondPositionalRejected() {
        #expect(parseError(["first", "second"]) == .unexpectedArgument("second"))
    }

    @Test("the positional prompt conflicts with every explicit prompt source")
    func positionalConflictsWithPromptSources() {
        for source in [["-p", "explicit"], ["--prompt-json", "{}"], ["--prompt-file", "/tmp/p"]] {
            let error = parseError(source + ["positional"])
            guard case .conflictingOptions(let first, _) = error else {
                Issue.record("expected a conflict for \(source), got \(String(describing: error))")
                continue
            }
            #expect(first == "PROMPT")
        }
    }

    // MARK: - Prompt sources select the headless run

    @Test("-p, --single and --print all start a single-turn headless run")
    func singleTurnSpellings() throws {
        for flag in ["-p", "--prompt", "--single", "--print"] {
            let options = try launch([flag, "summarize"])
            #expect(options.mode == .headless, "\(flag) must select headless")
            #expect(options.prompt == "summarize")
        }
    }

    @Test("--prompt-json and --prompt-file also select headless at the root")
    func structuredPromptSourcesAreHeadless() throws {
        let json = try launch(["--prompt-json", "{\"prompt\":\"hi\"}"])
        #expect(json.mode == .headless)
        #expect(json.promptJSON == "{\"prompt\":\"hi\"}")

        let file = try launch(["--prompt-file", "/tmp/prompt.md"])
        #expect(file.mode == .headless)
        #expect(file.promptFile == "/tmp/prompt.md")
    }

    @Test("--json-schema implies JSON output and rejects a contradicting format")
    func jsonSchemaImpliesJSONOutput() throws {
        let options = try launch(["-p", "extract", "--json-schema", "{\"type\":\"object\"}"])
        #expect(options.outputFormat == .json)
        #expect(options.jsonSchema == "{\"type\":\"object\"}")

        let error = parseError(["-p", "x", "--json-schema", "{}", "--output-format", "streaming-json"])
        guard case .conflictingOptions(let first, _) = error else {
            Issue.record("expected a conflict, got \(String(describing: error))")
            return
        }
        #expect(first == "--json-schema")
    }

    @Test("--verbatim and --include-partial-messages are accepted and retained")
    func streamingModifiers() throws {
        let options = try launch([
            "-p", "go", "--verbatim", "--include-partial-messages",
            "--output-format", "streaming-messages-json"
        ])
        #expect(options.verbatim)
        #expect(options.includePartialMessages)
        #expect(options.outputFormat == .streamingMessagesJSON)
    }

    // MARK: - Session selection

    @Test("-c and --continue select the most recent session for this directory")
    func continueFlag() throws {
        for flag in ["-c", "--continue"] {
            let options = try launch([flag])
            #expect(options.continueSession, "\(flag) must set continue")
        }
    }

    @Test("-r and --resume take an optional value in every spelling")
    func resumeSpellings() throws {
        #expect(try launch(["-r"]).resumeMostRecent)
        #expect(try launch(["--resume"]).resumeMostRecent)
        #expect(try launch(["--resume=abc"]).sessionToResume == "abc")
        #expect(try launch(["-r", "abc"]).sessionToResume == "abc")
        // A non-UUID value is a title, and the parser must carry it through
        // untouched for the resolver rather than rejecting it.
        #expect(try launch(["-r", "my session title"]).sessionToResume == "my session title")
    }

    @Test("--load is a resume alias and reads back through sessionToResume")
    func loadAlias() throws {
        let options = try launch(["--load", "abc"])
        #expect(options.loadSession == "abc")
        #expect(options.resume == nil)
        #expect(options.sessionToResume == "abc")
    }

    @Test("--resume and --load both conflict with --continue")
    func resumeContinueConflict() {
        #expect(parseError(["-r", "abc", "-c"]) == .conflictingOptions("--resume", "--continue"))
        #expect(parseError(["--load", "abc", "-c"]) == .conflictingOptions("--load", "--continue"))
    }

    @Test("--restore-code requires --resume")
    func restoreCodeRequiresResume() throws {
        #expect(parseError(["--restore-code"]) == .requiresOption("--restore-code", "--resume"))
        #expect(try launch(["-r", "abc", "--restore-code"]).restoreCode)
    }

    @Test("--session-id with a resume or continue requires --fork-session")
    func sessionIDRequiresForkWhenResuming() throws {
        for selector in [["-r", "abc"], ["--load", "abc"], ["-c"]] {
            let error = parseError(selector + ["--session-id", "new-id"])
            guard case .requiresOption(_, let required) = error else {
                Issue.record("expected a requirement for \(selector), got \(String(describing: error))")
                continue
            }
            #expect(required == "--fork-session")
        }
        // With --fork-session the id names the fork, which is legal.
        let forked = try launch(["-r", "abc", "--session-id", "new-id", "--fork-session"])
        #expect(forked.sessionID == "new-id")
        #expect(forked.forkSession)
        // A brand-new session may always name its own id.
        #expect(try launch(["-s", "new-id"]).sessionID == "new-id")
    }

    @Test("-w and --worktree take an optional name; --ref requires one")
    func worktreeFlags() throws {
        #expect(try launch(["-w"]).worktree == "")
        #expect(try launch(["--worktree=feat"]).worktree == "feat")
        #expect(try launch(["--worktree", "feat", "--ref", "main"]).worktreeRef == "main")
        #expect(try launch(["-w", "feat", "--worktree-ref", "main"]).worktreeRef == "main")
        #expect(parseError(["--ref", "main"]) == .requiresOption("--worktree-ref", "--worktree"))
    }

    // MARK: - Permissions and sandbox

    @Test("--allow and --deny split on commas, repeat, and preserve order")
    func permissionRules() throws {
        let options = try launch([
            "--allow", "Read,Write", "--allow", "Bash(ls:*)",
            "--deny", "Bash(rm:*)", "--deny", "WebFetch,WebSearch"
        ])
        #expect(options.common.permissions.allowRules == ["Read", "Write", "Bash(ls:*)"])
        #expect(options.common.permissions.denyRules == ["Bash(rm:*)", "WebFetch", "WebSearch"])
    }

    @Test("--allowedTools and --disallowedTools are the camel-case rule aliases")
    func permissionRuleAliases() throws {
        let options = try launch(["--allowedTools", "Read", "--disallowedTools", "Bash"])
        #expect(options.common.permissions.allowRules == ["Read"])
        #expect(options.common.permissions.denyRules == ["Bash"])
    }

    /// The near-collision upstream inherited: `--disallowed-tools` (kebab) is
    /// the built-in tool filter, `--disallowedTools` (camel) is a deny rule.
    /// A parser that conflated them would silently move a user's tool filter
    /// into the permission engine.
    @Test("--disallowed-tools is the tool filter, not a deny rule")
    func disallowedToolsIsNotADenyRule() throws {
        let options = try launch(["--tools", "Read,Write", "--disallowed-tools", "Bash"])
        #expect(options.agentOptions.tools == "Read,Write")
        #expect(options.agentOptions.disallowedTools == "Bash")
        #expect(options.common.permissions.denyRules.isEmpty)
    }

    @Test("--always-approve, --yolo and --dangerously-skip-permissions are one flag")
    func alwaysApproveSpellings() throws {
        for flag in ["--always-approve", "--yolo", "--dangerously-skip-permissions"] {
            #expect(try launch([flag]).common.permissions.alwaysApprove, "\(flag) must set alwaysApprove")
        }
    }

    @Test("--permission-mode accepts the six upstream values and rejects others")
    func permissionModeValues() throws {
        for mode in CLIPermissionMode.allCases {
            let options = try launch(["--permission-mode", mode.rawValue])
            #expect(options.common.permissions.mode == mode)
        }
        let error = parseError(["--permission-mode", "yolo"])
        guard case .invalidValue(let option, let value, _) = error else {
            Issue.record("expected an invalid value, got \(String(describing: error))")
            return
        }
        #expect(option == "--permission-mode")
        #expect(value == "yolo")
    }

    @Test("--trust and --trust-folder set the trust decision")
    func trustFlags() throws {
        #expect(try launch(["--trust"]).common.permissions.trustFolder)
        #expect(try launch(["--trust-folder"]).common.permissions.trustFolder)
    }

    @Test("--sandbox wins over GROK_SANDBOX, which fills in when the flag is absent")
    func sandboxProfileResolution() throws {
        let environment = ["GROK_SANDBOX": "strict"]
        #expect(try launch([], environment: environment).common.permissions.sandboxProfile == "strict")
        #expect(
            try launch(["--sandbox", "permissive"], environment: environment)
                .common.permissions.sandboxProfile == "permissive"
        )
        #expect(try launch([], environment: [:]).common.permissions.sandboxProfile == nil)
        // An empty environment value counts as unset, matching clap's `env`.
        #expect(
            try launch([], environment: ["GROK_SANDBOX": ""]).common.permissions.sandboxProfile == nil
        )
    }

    // MARK: - Agent configuration

    @Test("agent configuration flags parse with their upstream aliases")
    func agentConfigurationFlags() throws {
        let options = try launch([
            "--agent", "reviewer",
            "--agents", "{\"a\":{}}",
            "--effort", "high",
            "--append-system-prompt", "be terse",
            "--system-prompt", "you are a reviewer",
            "--max-turns", "12",
            "--no-plan", "--no-subagents", "--no-ask-user", "--disable-web-search",
            "--experimental-memory"
        ])
        #expect(options.agentOptions.agent == "reviewer")
        #expect(options.agentOptions.agentsJSON == "{\"a\":{}}")
        #expect(options.agentOptions.reasoningEffort == "high")
        #expect(options.agentOptions.rules == "be terse")
        #expect(options.agentOptions.systemPromptOverride == "you are a reviewer")
        #expect(options.agentOptions.maxTurns == 12)
        #expect(options.agentOptions.noPlan)
        #expect(options.agentOptions.noSubagents)
        #expect(options.agentOptions.noAskUser)
        #expect(options.agentOptions.disableWebSearch)
        #expect(options.agentOptions.experimentalMemory)
    }

    @Test("--reasoning-effort is last-wins, matching clap's overrides_with")
    func reasoningEffortLastWins() throws {
        #expect(try launch(["--effort", "low", "--reasoning-effort", "high"]).agentOptions.reasoningEffort == "high")
    }

    @Test("--max-turns rejects zero and non-numeric values")
    func maxTurnsValidation() {
        for value in ["0", "-1", "many"] {
            guard case .invalidValue(let option, _, _) = parseError(["--max-turns", value]) else {
                Issue.record("expected an invalid value for --max-turns \(value)")
                continue
            }
            #expect(option == "--max-turns")
        }
    }

    @Test("--experimental-memory and --no-memory conflict")
    func memoryConflict() {
        #expect(
            parseError(["--experimental-memory", "--no-memory"])
                == .conflictingOptions("--experimental-memory", "--no-memory")
        )
    }

    // MARK: - Interface and globals

    /// Upstream's `--minimal` is a scrollback-native *interactive* renderer.
    /// This port's `minimal` mode word is a one-shot run that demands a prompt,
    /// so the two must not be the same switch — otherwise `open-grok --minimal`
    /// errors with "minimal mode requires a prompt".
    @Test("root --minimal selects the renderer and stays interactive")
    func minimalIsARendererAtTheRoot() throws {
        let options = try launch(["--minimal"])
        #expect(options.mode == .interactive)
        #expect(options.minimalRendering)

        // The mode word keeps its own meaning.
        let word = try launch(["minimal", "-p", "go"])
        #expect(word.mode == .minimal)
        #expect(!word.minimalRendering)
    }

    @Test("--minimal conflicts with --fullscreen at the root too")
    func minimalFullscreenConflictAtRoot() {
        #expect(parseError(["--minimal", "--fullscreen"]) == .conflictingOptions("--minimal", "--fullscreen"))
    }

    @Test("global --debug, --debug-file and --leader-socket parse before a subcommand")
    func globalsBeforeSubcommand() throws {
        let command = try CLICommandParser.parseOrThrow([
            "--debug", "--debug-file", "/tmp/d.log", "--leader-socket", "/tmp/l.sock", "mcp", "list"
        ])
        guard case .mcp(let options) = command else {
            Issue.record("expected the mcp route, got \(command.routeName)")
            return
        }
        #expect(options.action == "list")
        #expect(options.common.debug)
        #expect(options.common.debugFile == "/tmp/d.log")
        #expect(options.common.leaderSocket == "/tmp/l.sock")
    }

    @Test("root options collected before a mode word are handed down to it")
    func rootOptionsSeedModeWords() throws {
        let options = try launch(["-m", "grok-4.5", "--sandbox", "strict", "headless", "-p", "go"])
        #expect(options.mode == .headless)
        #expect(options.common.model == "grok-4.5")
        #expect(options.common.permissions.sandboxProfile == "strict")
        #expect(options.prompt == "go")
    }

    @Test("hidden operational flags are accepted rather than rejected")
    func hiddenFlags() throws {
        let options = try launch([
            "--storage-mode", "writeback", "--client-identifier", "ci",
            "--hunk-tracker-mode", "off", "--installer", "brew",
            "--compaction-mode", "segments", "--compaction-detail", "minimal",
            "--terminal", "--fs-read", "--fs-write", "--no-auto-update",
            "--todo-gate", "--log-sampling", "--force-login",
            "--background-wait-timeout", "30"
        ])
        #expect(options.advanced.storageMode == "writeback")
        #expect(options.advanced.clientIdentifier == "ci")
        #expect(options.advanced.hunkTrackerMode == "off")
        #expect(options.advanced.installer == "brew")
        #expect(options.advanced.compactionMode == "segments")
        #expect(options.advanced.compactionDetail == "minimal")
        #expect(options.advanced.terminal)
        #expect(options.advanced.fsRead)
        #expect(options.advanced.fsWrite)
        #expect(options.advanced.noAutoUpdate)
        #expect(options.advanced.todoGate)
        #expect(options.advanced.logSampling)
        #expect(options.advanced.forceLogin)
        #expect(options.advanced.backgroundWaitTimeoutSeconds == 30)
    }

    @Test("--oauth is accepted at the root, not only on login")
    func rootOAuth() throws {
        #expect(try launch(["--oauth"]).oauth)
    }

    @Test("the agent-tree flags parse at the root and after the agent word")
    func agentTreeFlags() throws {
        #expect(try launch(["--reauth"]).advanced.reauthenticate)
        #expect(try launch(["--reauthenticate"]).advanced.reauthenticate)
        #expect(try launch(["agent", "--reauth"]).advanced.reauthenticate)
        #expect(
            try launch(["--cli-chat-proxy-base-url", "https://proxy.example/v1"])
                .advanced.cliChatProxyBaseURL == "https://proxy.example/v1"
        )
        #expect(
            try launch(["--xai-api-base-url", "https://api.example/v1"])
                .advanced.xaiAPIBaseURL == "https://api.example/v1"
        )
    }

    @Test("an unknown root option is a usage error, not an unknown command")
    func unknownRootOption() {
        #expect(parseError(["--not-a-flag"]) == .unknownOption("--not-a-flag"))
    }

    @Test("version and help intents win wherever they appear on the root line")
    func earlyIntents() throws {
        for flag in ["-v", "-V", "--version"] {
            guard case .version = try CLICommandParser.parseOrThrow([flag]) else {
                Issue.record("\(flag) must be a version intent")
                continue
            }
        }
        guard case .version = try CLICommandParser.parseOrThrow(["--cwd", "/tmp", "--version"]) else {
            Issue.record("--version must win after other root options")
            return
        }
        guard case .help(let topic) = try CLICommandParser.parseOrThrow(["--help"]) else {
            Issue.record("--help must be a help intent")
            return
        }
        #expect(topic == nil)
    }

    @Test("the v alias reaches the version route")
    func versionAlias() throws {
        guard case .version(let json) = try CLICommandParser.parseOrThrow(["v", "--json"]) else {
            Issue.record("expected the version route")
            return
        }
        #expect(json)
    }
}
