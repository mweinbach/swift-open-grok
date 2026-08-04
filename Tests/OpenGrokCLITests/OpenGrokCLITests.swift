import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("OpenGrokCLI parser")
struct OpenGrokCLITests {
    @Test("no arguments select the interactive composition route")
    func defaultRoute() throws {
        let command = try CLICommandParser.parseOrThrow([])
        guard case .launch(let options) = command else {
            Issue.record("expected an interactive launch route")
            return
        }
        #expect(options.mode == .interactive)
        #expect(options.prompt == nil)
    }

    @Test("interactive options preserve provider, profile, plugins, MCP, and workflow")
    func interactiveOptions() throws {
        let command = try CLICommandParser.parseOrThrow([
            "interactive",
            "--cwd", "/tmp/project",
            "--model", "grok-test",
            "--provider", "xai",
            "--agent-profile", "coding",
            "--plugin-dir", "/tmp/plugin-a",
            "--plugin-dir=/tmp/plugin-b",
            "--mcp-config", "/tmp/mcp.json",
            "--workflow", "review"
        ])
        guard case .launch(let options) = command else {
            Issue.record("expected launch route")
            return
        }
        #expect(options.mode == .interactive)
        #expect(options.common.cwd == "/tmp/project")
        #expect(options.common.model == "grok-test")
        #expect(options.common.provider == "xai")
        #expect(options.common.profile == "coding")
        #expect(options.common.pluginDirectories == ["/tmp/plugin-a", "/tmp/plugin-b"])
        #expect(options.common.mcpConfig == "/tmp/mcp.json")
        #expect(options.common.workflow == "review")
    }

    @Test("minimal and fullscreen are mutually exclusive")
    func minimalFullscreenConflict() {
        do {
            _ = try CLICommandParser.parseOrThrow(["minimal", "--fullscreen"])
            Issue.record("expected conflicting options error")
        } catch let error as CLIParseError {
            #expect(error == .conflictingOptions("--minimal", "--fullscreen"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("headless parsing supports prompt sources, output format, and session controls")
    func headlessOptions() throws {
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "summarize the change",
            "--output-format", "streaming-json",
            "--model", "grok-test",
            "--resume", "session-123",
            "--fork-session",
            "--session-id", "session-456"
        ])
        guard case .launch(let options) = command else {
            Issue.record("expected launch route")
            return
        }
        #expect(options.mode == .headless)
        #expect(options.prompt == "summarize the change")
        #expect(options.outputFormat == .streamingJSON)
        #expect(options.common.model == "grok-test")
        #expect(options.resume == "session-123")
        #expect(options.forkSession)
        #expect(options.sessionID == "session-456")
    }

    @Test("ACP agent and serve grammar map to transport-specific routes")
    func agentTransportRoutes() throws {
        let acp = try CLICommandParser.parseOrThrow(["agent", "stdio"])
        guard case .launch(let acpOptions) = acp else {
            Issue.record("expected ACP launch route")
            return
        }
        #expect(acpOptions.mode == .acp)

        let serve = try CLICommandParser.parseOrThrow([
            "agent", "serve", "--bind", "0.0.0.0:2419", "--secret", "test-secret", "--remote", "wss://relay"
        ])
        guard case .serve(let serveOptions) = serve else {
            Issue.record("expected serve route")
            return
        }
        #expect(serveOptions.bind == "0.0.0.0:2419")
        #expect(serveOptions.secret == "test-secret")
        #expect(serveOptions.remote == "wss://relay")
    }

    @Test("leader grammar preserves lifecycle policy options")
    func leaderOptions() throws {
        let command = try CLICommandParser.parseOrThrow([
            "leader", "--no-exit-on-disconnect", "--relay-on-demand", "--no-auto-update", "--no-leader"
        ])
        guard case .leader(let options) = command else {
            Issue.record("expected leader route")
            return
        }
        #expect(options.noExitOnDisconnect)
        #expect(options.relayOnDemand)
        #expect(options.noAutoUpdate)
        #expect(options.common.noLeader)
    }

    @Test("session, model, plugin, MCP, and workflow subcommands parse typed payloads")
    func resourceCommands() throws {
        let session = try CLICommandParser.parseOrThrow(["session", "resume", "abc", "--fork", "--json"])
        guard case .sessions(let sessionOptions) = session else {
            Issue.record("expected session route")
            return
        }
        #expect(sessionOptions.action == .resume)
        #expect(sessionOptions.identifier == "abc")
        #expect(sessionOptions.fork)
        #expect(sessionOptions.json)

        let models = try CLICommandParser.parseOrThrow(["models", "default", "--json"])
        guard case .models(let modelOptions) = models else {
            Issue.record("expected models route")
            return
        }
        #expect(modelOptions.action == .default)
        #expect(modelOptions.json)

        let plugin = try CLICommandParser.parseOrThrow(["plugin", "install", "demo", "--source", "/tmp/demo", "--force"])
        guard case .plugin(let pluginOptions) = plugin else {
            Issue.record("expected plugin route")
            return
        }
        #expect(pluginOptions.action == "install")
        #expect(pluginOptions.target == "demo")
        #expect(pluginOptions.options["--source"] == "/tmp/demo")
        #expect(pluginOptions.force)

        let mcp = try CLICommandParser.parseOrThrow(["mcp", "add", "local", "--command", "tool-server"])
        guard case .mcp(let mcpOptions) = mcp else {
            Issue.record("expected MCP route")
            return
        }
        #expect(mcpOptions.action == "add")
        #expect(mcpOptions.target == "local")
        #expect(mcpOptions.options["--command"] == "tool-server")

        let workflow = try CLICommandParser.parseOrThrow(["workflow", "run", "review", "--argument", "depth=2"])
        guard case .workflow(let workflowOptions) = workflow else {
            Issue.record("expected workflow route")
            return
        }
        #expect(workflowOptions.action == "run")
        #expect(workflowOptions.target == "review")
        #expect(workflowOptions.options["--argument"] == "depth=2")
    }

    @Test("utility parsing retains wrap trailing arguments")
    func utilityCommands() throws {
        let command = try CLICommandParser.parseOrThrow(["wrap", "docker", "exec", "-it", "container", "bash"])
        guard case .utility(let options) = command else {
            Issue.record("expected utility route")
            return
        }
        #expect(options.name == "wrap")
        #expect(options.values == ["docker", "exec", "-it", "container", "bash"])
    }

    @Test("invalid grammar is explicit and maps to usage failure")
    func invalidGrammar() {
        let command = CLICommandParser.parse(["headless", "--output-format", "not-a-format"])
        guard case .invalid(let error) = command else {
            Issue.record("expected invalid command")
            return
        }
        guard case .invalidValue(let option, _, _) = error else {
            Issue.record("expected invalid output format")
            return
        }
        #expect(option == "--output-format")

        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["headless", "--output-format", "not-a-format"], streams: streams)
        #expect(code == CLIRunner.ExitCode.usage.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("invalid value"))
    }

    @Test("version, paths, and embedded model listing are supported built-ins")
    func supportedBuiltIns() {
        let (versionStreams, versionOut, versionErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(["--version"], environment: [:], streams: versionStreams) == 0)
        #expect(versionOut.contents.contains("Open Grok"))
        #expect(versionErr.contents.isEmpty)

        let (pathStreams, pathOut, pathErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(["paths", "--json"], environment: ["HOME": "/tmp/home"], streams: pathStreams) == 0)
        #expect(pathOut.contents.contains("opengrok_home"))
        #expect(pathOut.contents.contains("/tmp/home/.opengrok"))
        #expect(pathErr.contents.isEmpty)

        let (modelStreams, modelOut, modelErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(["models", "--json"], environment: [:], streams: modelStreams) == 0)
        #expect(modelOut.contents.contains("\"default\""))
        #expect(modelErr.contents.isEmpty)
    }

    @Test("recognized runtime routes fail explicitly without a launcher")
    func unsupportedRoutesFailClosed() {
        for args in [["interactive"], ["minimal"], ["acp"], ["serve"], ["session", "list"], ["plugin", "list"], ["mcp", "list"], ["workflow", "list"]] {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main(args, environment: [:], streams: streams)
            #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
            #expect(out.contents.isEmpty)
            #expect(err.contents.contains("unavailable"))
        }
    }
}
