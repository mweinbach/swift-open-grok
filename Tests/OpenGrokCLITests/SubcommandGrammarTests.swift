import Foundation
import Testing
@testable import OpenGrokCLI

/// Per-subcommand option grammars.
///
/// The audit's finding was that `parseResource`/`parseUtility` accepted
/// arbitrary action words and a fixed grab-bag of flags, so a misspelled
/// subcommand or an unsupported flag reached the route and produced a runtime
/// refusal instead of a usage error. These tests pin the grammars that replaced
/// that, and in particular pin the two failure modes apart: an action outside
/// the grammar is exit 2, an action inside it that this composition has not
/// implemented is exit 3 (or the route's own exit 1).
@Suite("Subcommand grammars")
struct SubcommandGrammarTests {
    private func parseError(_ args: [String]) -> CLIParseError? {
        guard case .invalid(let error) = CLICommandParser.parse(args) else { return nil }
        return error
    }

    // MARK: - mcp

    @Test("mcp add accepts the full upstream grammar")
    func mcpAddGrammar() throws {
        let command = try CLICommandParser.parseOrThrow([
            "mcp", "add", "server", "--transport", "http", "-s", "project",
            "-e", "TOKEN=1", "-e", "REGION=eu", "-H", "Authorization: Bearer x",
            "--", "--server-flag", "value"
        ])
        guard case .mcp(let options) = command else {
            Issue.record("expected the mcp route")
            return
        }
        #expect(options.action == "add")
        #expect(options.target == "server")
        #expect(options.options["--transport"] == "http")
        #expect(options.options["--scope"] == "project")
        // Repeatable options need a list; a flat dictionary silently kept only
        // the last `-e`, which is how an authenticated server lost its token.
        #expect(options.repeatedOptions["--env"] == ["TOKEN=1", "REGION=eu"])
        #expect(options.repeatedOptions["--header"] == ["Authorization: Bearer x"])
        // Everything after `--` belongs to the server process.
        #expect(options.values == ["--server-flag", "value"])
    }

    @Test("short -t and -s reach the same keys as their long spellings")
    func mcpShortFlags() throws {
        let command = try CLICommandParser.parseOrThrow(["mcp", "add", "s", "-t", "sse", "-s", "user"])
        guard case .mcp(let options) = command else {
            Issue.record("expected the mcp route")
            return
        }
        #expect(options.options["--transport"] == "sse")
        #expect(options.options["--scope"] == "user")
    }

    @Test("an mcp action outside the grammar is a usage error")
    func mcpUnknownAction() {
        #expect(parseError(["mcp", "nonsense"]) == .unknownCommand("nonsense"))
    }

    @Test("mcp enable, disable and doctor parse even though the route lacks them")
    func mcpUnimplementedActionsStillParse() throws {
        for action in ["enable", "disable", "doctor"] {
            let command = try CLICommandParser.parseOrThrow(["mcp", action, "demo"])
            guard case .mcp(let options) = command else {
                Issue.record("expected the mcp route for \(action)")
                continue
            }
            #expect(options.action == action)
        }
    }

    // MARK: - plugin

    @Test("plugin actions and their flags parse, including marketplace")
    func pluginGrammar() throws {
        let install = try CLICommandParser.parseOrThrow(["plugin", "install", "user/repo", "--trust"])
        guard case .plugin(let installOptions) = install else {
            Issue.record("expected the plugin route")
            return
        }
        #expect(installOptions.action == "install")
        #expect(installOptions.target == "user/repo")
        #expect(installOptions.options["--trust"] == "true")

        let tag = try CLICommandParser.parseOrThrow(["plugin", "tag", ".", "--push", "-f", "--dry-run"])
        guard case .plugin(let tagOptions) = tag else {
            Issue.record("expected the plugin route")
            return
        }
        #expect(tagOptions.force)
        #expect(tagOptions.options["--push"] == "true")
        #expect(tagOptions.options["--dry-run"] == "true")

        let marketplace = try CLICommandParser.parseOrThrow(["plugin", "marketplace", "list"])
        guard case .plugin(let marketplaceOptions) = marketplace else {
            Issue.record("expected the plugin route")
            return
        }
        #expect(marketplaceOptions.action == "marketplace")
        #expect(marketplaceOptions.target == "list")
    }

    @Test("plugin list --available requires --json, as clap declares")
    func pluginAvailableRequiresJSON() throws {
        #expect(parseError(["plugin", "list", "--available"]) == .requiresOption("--available", "--json"))
        guard case .plugin = try CLICommandParser.parseOrThrow(["plugin", "list", "--available", "--json"]) else {
            Issue.record("expected the plugin route")
            return
        }
    }

    @Test("a plugin action outside the grammar is a usage error")
    func pluginUnknownAction() {
        #expect(parseError(["plugin", "frobnicate"]) == .unknownCommand("frobnicate"))
    }

    // MARK: - sessions

    @Test("sessions search takes a query and a limit")
    func sessionsSearch() throws {
        let command = try CLICommandParser.parseOrThrow(["sessions", "search", "parser", "-n", "5"])
        guard case .sessions(let options) = command else {
            Issue.record("expected the sessions route")
            return
        }
        #expect(options.action == .search)
        #expect(options.query == "parser")
        #expect(options.limit == 5)
    }

    @Test("sessions list defaults to a limit of 20 and rejects a non-positive one")
    func sessionsLimit() throws {
        let command = try CLICommandParser.parseOrThrow(["sessions", "list"])
        guard case .sessions(let options) = command else {
            Issue.record("expected the sessions route")
            return
        }
        #expect(options.limit == 20)

        for spelling in ["--limit", "-n"] {
            guard case .invalidValue(let option, _, _) = parseError(["sessions", "list", spelling, "0"]) else {
                Issue.record("expected an invalid value for \(spelling) 0")
                continue
            }
            #expect(option == spelling)
        }
    }

    @Test("sessions search without a query is a usage error")
    func sessionsSearchNeedsQuery() {
        #expect(parseError(["sessions", "search"]) == .missingValue("sessions search query"))
    }

    // MARK: - utilities

    @Test("memory requires a subcommand and rejects an unknown one")
    func memoryGrammar() throws {
        #expect(parseError(["memory"]) == .missingSubcommand("memory"))
        #expect(parseError(["memory", "clean"]) == .unknownCommand("clean"))

        let command = try CLICommandParser.parseOrThrow(["memory", "clear", "--workspace", "--all", "-y"])
        guard case .utility(let options) = command else {
            Issue.record("expected the utility route")
            return
        }
        #expect(options.values == ["clear"])
        #expect(options.isSet("--workspace"))
        #expect(options.isSet("--all"))
        #expect(options.isSet("--yes"))
    }

    @Test("update accepts every upstream flag and conflicts its three channels")
    func updateGrammar() throws {
        let command = try CLICommandParser.parseOrThrow([
            "update", "--check", "--json", "--force-reinstall", "--version", "0.1.150"
        ])
        guard case .utility(let options) = command else {
            Issue.record("expected the utility route")
            return
        }
        #expect(options.isSet("--check"))
        #expect(options.json)
        #expect(options.isSet("--force-reinstall"))
        #expect(options.options["--version"] == "0.1.150")

        #expect(parseError(["update", "--alpha", "--stable"]) == .conflictingOptions("--alpha", "--stable"))
        #expect(parseError(["update", "--alpha", "--enterprise"]) == .conflictingOptions("--alpha", "--enterprise"))
        #expect(parseError(["update", "--stable", "--enterprise"]) == .conflictingOptions("--stable", "--enterprise"))
    }

    @Test("login and logout enforce their mutually exclusive flags at parse time")
    func authConflicts() throws {
        #expect(parseError(["logout", "--codex", "--all"]) == .conflictingOptions("--codex", "--all"))
        #expect(parseError(["login", "--oauth", "--device-auth"]) == .conflictingOptions("--oauth", "--device-auth"))
        #expect(parseError(["login", "--oauth", "--codex"]) == .conflictingOptions("--oauth", "--codex"))
    }

    /// The auth composition reads `options["--device-auth"]` and
    /// `options["--device-code"]`, so the alias has to land on a key it checks.
    @Test("login --device-code canonicalizes onto --device-auth")
    func deviceAuthAlias() throws {
        guard case .utility(let options) = try CLICommandParser.parseOrThrow(["login", "--device-code"]) else {
            Issue.record("expected the utility route")
            return
        }
        #expect(options.options["--device-auth"] == "true")
    }

    @Test("export, trace and worktree accept the flags upstream defines")
    func utilityFlagSets() throws {
        guard case .utility(let export) = try CLICommandParser.parseOrThrow(["export", "abc", "-c"]) else {
            Issue.record("expected the export route")
            return
        }
        #expect(export.values == ["abc"])
        #expect(export.isSet("--clipboard"))

        guard case .utility(let trace) = try CLICommandParser.parseOrThrow(
            ["trace", "abc", "--local", "-o", "/tmp/t.tar.gz"]
        ) else {
            Issue.record("expected the trace route")
            return
        }
        #expect(trace.isSet("--local"))
        #expect(trace.options["--output"] == "/tmp/t.tar.gz")

        guard case .utility(let worktree) = try CLICommandParser.parseOrThrow(
            ["worktree", "gc", "--dry-run", "--max-age", "7d", "-f"]
        ) else {
            Issue.record("expected the worktree route")
            return
        }
        #expect(worktree.values == ["gc"])
        #expect(worktree.isSet("--dry-run"))
        #expect(worktree.options["--max-age"] == "7d")
        #expect(worktree.force)

        #expect(parseError(["worktree", "frobnicate"]) == .unknownCommand("frobnicate"))
        #expect(
            parseError(["workspace", "start", "--leader", "--no-leader"])
                == .conflictingOptions("--leader", "--no-leader")
        )
    }

    /// `wrap` is `trailing_var_arg` + `allow_hyphen_values`: the child's own
    /// flags must survive, which is exactly what a normal option loop destroys.
    @Test("wrap hands every trailing argument to the child, hyphens included")
    func wrapTrailingArguments() throws {
        guard case .utility(let options) = try CLICommandParser.parseOrThrow(
            ["wrap", "sh", "-c", "exit 7", "--json"]
        ) else {
            Issue.record("expected the wrap route")
            return
        }
        #expect(options.values == ["sh", "-c", "exit 7", "--json"])
        #expect(!options.json)
        #expect(parseError(["wrap"]) == .missingValue("wrap command"))
    }

    // MARK: - doctor

    @Test("doctor parses --json and the fix subcommand")
    func doctorGrammar() throws {
        guard case .doctor(let plain) = try CLICommandParser.parseOrThrow(["doctor", "--json"]) else {
            Issue.record("expected the doctor route")
            return
        }
        #expect(plain.json)
        #expect(!plain.fix)

        guard case .doctor(let fix) = try CLICommandParser.parseOrThrow(
            ["doctor", "fix", "tmux-clipboard", "-y"]
        ) else {
            Issue.record("expected the doctor route")
            return
        }
        #expect(fix.fix)
        #expect(fix.fixID == "tmux-clipboard")
        #expect(fix.assumeYes)

        #expect(parseError(["doctor", "-y"]) == .requiresOption("--yes", "the 'doctor fix' subcommand"))
    }

    // MARK: - completions and help

    @Test("completions emits a real script for every supported shell")
    func completionScripts() {
        for shell in ["bash", "zsh", "fish", "powershell", "elvish"] {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main(["completions", shell], environment: [:], streams: streams)
            #expect(code == CLIRunner.ExitCode.success.rawValue, "\(shell) must succeed")
            #expect(err.contents.isEmpty)
            // Every script has to mention the binary and at least one command,
            // or it is a stub that would silently complete nothing.
            #expect(out.contents.contains("open-grok"), "\(shell) script must name the binary")
            #expect(out.contents.contains("sessions"), "\(shell) script must list commands")
        }
    }

    @Test("an unsupported shell is a usage error")
    func completionsRejectsUnknownShell() {
        let (streams, out, _) = CLIStreams.buffered()
        #expect(CLIRunner.main(["completions", "tcsh"], environment: [:], streams: streams)
            == CLIRunner.ExitCode.usage.rawValue)
        #expect(out.contents.isEmpty)
    }

    /// `help <topic>` used to ignore its argument entirely and print the same
    /// blob, which turns a typo into a silently wrong answer.
    @Test("help prints the named topic and rejects an unknown one")
    func helpTopics() {
        let (streams, out, _) = CLIStreams.buffered()
        #expect(CLIRunner.main(["help", "mcp"], environment: [:], streams: streams) == 0)
        #expect(out.contents.contains("--transport"))
        #expect(!out.contents.contains("PERMISSIONS AND SANDBOX"))

        let (bad, badOut, badErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(["help", "nonsense"], environment: [:], streams: bad)
            == CLIRunner.ExitCode.usage.rawValue)
        #expect(badOut.contents.isEmpty)
        #expect(badErr.contents.contains("no help topic"))

        for topic in OpenGrokHelp.topics {
            #expect(OpenGrokHelp.topic(topic) != nil, "\(topic) is advertised but has no text")
        }
    }

    /// `open-grok mcp --help` used to reach `mcp`'s option grammar, where
    /// `--help` reads as a malformed action word.
    @Test("every subcommand answers --help and -h with its own topic")
    func perSubcommandHelp() {
        let commands = [
            "agent", "completions", "dashboard", "doctor", "export", "inspect",
            "leader", "login", "logout", "mcp", "memory", "models", "paths",
            "plugin", "serve", "sessions", "setup", "share", "trace", "update",
            "version", "workflow", "workspace", "worktree"
        ]
        for command in commands {
            guard case .help(let topic) = CLICommandParser.parse([command, "--help"]) else {
                Issue.record("\(command) --help must reach the help route")
                continue
            }
            #expect(topic == command)
            #expect(OpenGrokHelp.topic(command) != nil, "\(command) --help must have text to print")
        }
        guard case .help("mcp") = CLICommandParser.parse(["mcp", "-h"]) else {
            Issue.record("-h must work as well as --help")
            return
        }
    }

    /// The two places `--help` must *not* be intercepted: it belongs to the
    /// wrapped child, and to the MCP server behind `--`.
    @Test("wrap and mcp passthrough keep --help for the child process")
    func helpIsNotStolenFromChildren() throws {
        guard case .utility(let wrap) = try CLICommandParser.parseOrThrow(["wrap", "sh", "--help"]) else {
            Issue.record("expected the wrap route")
            return
        }
        #expect(wrap.values == ["sh", "--help"])

        guard case .mcp(let mcp) = try CLICommandParser.parseOrThrow(
            ["mcp", "add", "server", "--", "--help"]
        ) else {
            Issue.record("expected the mcp route")
            return
        }
        #expect(mcp.values == ["--help"])
    }

    // MARK: - refusals

    /// A route that parses and then refuses is only defensible if the refusal
    /// says which capability is missing.
    @Test("refusals name the missing capability instead of a generic message")
    func refusalsAreSpecific() {
        let cases: [(args: [String], needle: String)] = [
            (["wrap", "sh"], "clipboard"),
            (["export", "abc"], "sessions show"),
            (["inspect"], "paths"),
            (["worktree", "list"], "git worktree"),
            (["session", "new"], "list")
        ]
        for (args, needle) in cases {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main(args, environment: [:], streams: streams)
            #expect(code == CLIRunner.ExitCode.notImplemented.rawValue, "\(args) must refuse")
            #expect(out.contents.isEmpty)
            #expect(err.contents.contains(needle), "\(args) refusal must mention '\(needle)'")
        }
    }

    /// The `serve` secret is `#[arg(env = "GROK_AGENT_SECRET")]` upstream.
    @Test("agent serve takes its secret from the environment when the flag is absent")
    func serveSecretFromEnvironment() throws {
        let fromEnvironment = try CLICommandParser.parseOrThrow(
            ["agent", "serve"], environment: ["GROK_AGENT_SECRET": "env-secret"]
        )
        guard case .serve(let options) = fromEnvironment else {
            Issue.record("expected the serve route")
            return
        }
        #expect(options.secret == "env-secret")

        let explicit = try CLICommandParser.parseOrThrow(
            ["agent", "serve", "--secret", "flag-secret"],
            environment: ["GROK_AGENT_SECRET": "env-secret"]
        )
        guard case .serve(let explicitOptions) = explicit else {
            Issue.record("expected the serve route")
            return
        }
        #expect(explicitOptions.secret == "flag-secret")
    }
}
