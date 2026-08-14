// CLIRunnerE2ETests.swift
//
// End-to-end CLI Runner and Parity Ledger test suite (Feature 7).
// Ported and verified against the upstream Rust reference at pin b849ec76:
// `crates/codegen/xai-grok-pager-bin/src/main.rs`,
// `crates/codegen/xai-grok-pager/src/dispatch/cli.rs`.
//
// Key Contracts & Invariants:
// 1. Deterministic Exit Codes:
//    - 0: success
//    - 1: runtime failure / error
//    - 2: usage / CLI argument error
//    - 3: not implemented / unsupported route in sync runner
//    - 130: cancelled (SIGINT / Task cancellation)
// 2. Stream Separation:
//    - Pure structured JSON / output goes to stdout.
//    - Logs, warnings, errors, and diagnostics go to stderr.
// 3. Hermetic State:
//    - Custom OPENGROK_HOME and HOME paths are strictly honored without leaking into ~/.opengrok.
// 4. Built-in Commands:
//    - version, paths, help, models, completions, doctor, mcp, sessions all operate reliably.

import Foundation
import OpenGrokModels
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private struct CLIFixture {
    let root: URL
    let home: URL
    let environment: [String: String]

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("og-cli-e2e-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Test Suite

@Suite("CLI Runner E2E Tests", .serialized)
struct CLIRunnerE2ETests {

    // MARK: - Tier 1: Feature Coverage Tests (5+ tests)

    @Test("version plain and json exit codes and output formatting")
    func versionPlainAndJSON() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        // Plain version: open-grok --version
        let (plainStreams, plainOut, plainErr) = CLIStreams.buffered()
        let plainCode = CLIRunner.main(["--version"], environment: fixture.environment, streams: plainStreams)
        #expect(plainCode == CLIRunner.ExitCode.success.rawValue)
        #expect(plainOut.contents.hasPrefix("Open Grok "))
        #expect(plainErr.contents.isEmpty)

        // JSON version: open-grok version --json
        let (jsonStreams, jsonOut, jsonErr) = CLIStreams.buffered()
        let jsonCode = CLIRunner.main(["version", "--json"], environment: fixture.environment, streams: jsonStreams)
        #expect(jsonCode == CLIRunner.ExitCode.success.rawValue)
        #expect(jsonOut.contents.contains("\"version\""))
        #expect(jsonErr.contents.isEmpty)

        // Verify valid JSON decoding
        let parsed = try JSONDecoder().decode([String: String].self, from: Data(jsonOut.contents.utf8))
        #expect(parsed["version"] != nil)
    }

    @Test("paths plain and json reflect isolated OPENGROK_HOME environment")
    func pathsPlainAndJSON() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        // Plain paths
        let (plainStreams, plainOut, plainErr) = CLIStreams.buffered()
        let plainCode = CLIRunner.main(["paths"], environment: fixture.environment, streams: plainStreams)
        #expect(plainCode == CLIRunner.ExitCode.success.rawValue)
        #expect(plainOut.contents.contains("OPENGROK_HOME: \(fixture.home.path)"))
        #expect(plainOut.contents.contains("project state: .opengrok"))
        #expect(plainErr.contents.isEmpty)

        // JSON paths
        let (jsonStreams, jsonOut, jsonErr) = CLIStreams.buffered()
        let jsonCode = CLIRunner.main(["paths", "--json"], environment: fixture.environment, streams: jsonStreams)
        #expect(jsonCode == CLIRunner.ExitCode.success.rawValue)
        #expect(jsonErr.contents.isEmpty)

        let parsed = try JSONDecoder().decode([String: String].self, from: Data(jsonOut.contents.utf8))
        #expect(parsed["opengrok_home"] == fixture.home.path)
        #expect(parsed["project_state"] == ".opengrok")
        #expect(parsed["managed_binary"] != nil)
    }

    @Test("help prints full usage for root and topics, and exit code 2 for unknown topic")
    func helpTopicsAndErrors() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        // Root help: open-grok help
        let (rootStreams, rootOut, rootErr) = CLIStreams.buffered()
        let rootCode = CLIRunner.main(["help"], environment: fixture.environment, streams: rootStreams)
        #expect(rootCode == CLIRunner.ExitCode.success.rawValue)
        #expect(rootOut.contents.contains("Open Grok — command line"))
        #expect(rootOut.contents.contains("USAGE"))
        #expect(rootErr.contents.isEmpty)

        // Topic help: open-grok help doctor
        let (topicStreams, topicOut, topicErr) = CLIStreams.buffered()
        let topicCode = CLIRunner.main(["help", "doctor"], environment: fixture.environment, streams: topicStreams)
        #expect(topicCode == CLIRunner.ExitCode.success.rawValue)
        #expect(topicOut.contents.contains("doctor"))
        #expect(topicErr.contents.isEmpty)

        // Unknown topic: open-grok help non_existent_topic
        let (badStreams, badOut, badErr) = CLIStreams.buffered()
        let badCode = CLIRunner.main(["help", "non_existent_topic"], environment: fixture.environment, streams: badStreams)
        #expect(badCode == CLIRunner.ExitCode.usage.rawValue)
        #expect(badOut.contents.isEmpty)
        #expect(badErr.contents.contains("open-grok: no help topic named 'non_existent_topic'."))
        #expect(badErr.contents.contains("Topics:"))
    }

    @Test("models default and list commands in plain text and JSON")
    func modelsDefaultAndList() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        // Default model plain
        let (defStreams, defOut, defErr) = CLIStreams.buffered()
        let defCode = CLIRunner.main(["models"], environment: fixture.environment, streams: defStreams)
        #expect(defCode == CLIRunner.ExitCode.success.rawValue)
        #expect(!defOut.contents.isEmpty)
        #expect(defErr.contents.isEmpty)

        // Default model JSON
        let (defJSONStreams, defJSONOut, defJSONErr) = CLIStreams.buffered()
        let defJSONCode = CLIRunner.main(["models", "--json"], environment: fixture.environment, streams: defJSONStreams)
        #expect(defJSONCode == CLIRunner.ExitCode.success.rawValue)
        #expect(defJSONOut.contents.contains("\"default\""))
        #expect(defJSONErr.contents.isEmpty)

        // Models list plain
        let (listStreams, listOut, listErr) = CLIStreams.buffered()
        let listCode = CLIRunner.main(["models", "list"], environment: fixture.environment, streams: listStreams)
        #expect(listCode == CLIRunner.ExitCode.success.rawValue)
        #expect(listOut.contents.contains("Default:"))
        #expect(listErr.contents.isEmpty)

        // Models list JSON
        let (listJSONStreams, listJSONOut, listJSONErr) = CLIStreams.buffered()
        let listJSONCode = CLIRunner.main(["models", "list", "--json"], environment: fixture.environment, streams: listJSONStreams)
        #expect(listJSONCode == CLIRunner.ExitCode.success.rawValue)
        #expect(listJSONOut.contents.contains("\"default\""))
        #expect(listJSONOut.contents.contains("\"models\""))
        #expect(listJSONErr.contents.isEmpty)
    }

    @Test("completions scripts generation for bash, zsh, and fish")
    func completionsScripts() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        for shell in ["bash", "zsh", "fish"] {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main(["completions", shell], environment: fixture.environment, streams: streams)
            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(!out.contents.isEmpty)
            #expect(out.contents.contains("open-grok"))
            #expect(err.contents.isEmpty)
        }
    }

    @Test("doctor diagnostics plain and JSON reports")
    func doctorDiagnostics() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        // Plain doctor
        let (docStreams, docOut, docErr) = CLIStreams.buffered()
        let docCode = CLIRunner.main(["doctor"], environment: fixture.environment, streams: docStreams)
        #expect(docCode == CLIRunner.ExitCode.success.rawValue)
        #expect(!docOut.contents.isEmpty || !docErr.contents.isEmpty)

        // JSON doctor
        let (jsonStreams, jsonOut, _) = CLIStreams.buffered()
        let jsonCode = CLIRunner.main(["doctor", "--json"], environment: fixture.environment, streams: jsonStreams)
        #expect(jsonCode == CLIRunner.ExitCode.success.rawValue)
        #expect(!jsonOut.contents.isEmpty)

        // Fix mode
        let (fixStreams, _, _) = CLIStreams.buffered()
        let fixCode = CLIRunner.main(["doctor", "fix"], environment: fixture.environment, streams: fixStreams)
        #expect(fixCode == CLIRunner.ExitCode.success.rawValue)
    }

    // MARK: - Tier 2: Boundary & Corner Cases Tests (5+ tests)

    @Test("invalid flags and options return usage ExitCode 2")
    func invalidOptionsReturnExitCode2() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        // Unknown top-level option
        let (badOptStreams, badOptOut, badOptErr) = CLIStreams.buffered()
        let badOptCode = CLIRunner.main(["--unknown-invalid-option"], environment: fixture.environment, streams: badOptStreams)
        #expect(badOptCode == CLIRunner.ExitCode.usage.rawValue)
        #expect(badOptOut.contents.isEmpty)
        #expect(badOptErr.contents.contains("unknown option"))
        #expect(badOptErr.contents.contains("Run 'open-grok help' for usage."))

        // Bad enum value for option
        let (badValStreams, badValOut, badValErr) = CLIStreams.buffered()
        let badValCode = CLIRunner.main(["headless", "--output-format", "unsupported_fmt"], environment: fixture.environment, streams: badValStreams)
        #expect(badValCode == CLIRunner.ExitCode.usage.rawValue)
        #expect(badValOut.contents.isEmpty)
        #expect(badValErr.contents.contains("invalid value"))
    }

    @Test("unsupported async routes fail closed with ExitCode 3 in synchronous main")
    func unsupportedRoutesFailClosedExitCode3() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        let unbackedRoutes = [
            ["interactive"],
            ["minimal"],
            ["acp"],
            ["serve"],
            ["session", "new"],
            ["plugin", "list"],
            ["workflow", "list"],
            ["wrap", "echo", "test"],
            ["export", "session-1"],
            ["trace", "session-1"]
        ]

        for args in unbackedRoutes {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main(args, environment: fixture.environment, streams: streams)
            #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
            #expect(out.contents.isEmpty)
            #expect(err.contents.contains("unavailable in this Swift composition"))
        }
    }

    @Test("async cancellation propagates as ExitCode 130")
    func asyncCancellationExitCode130() async throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        let cancellingLauncher = CLIApplicationLauncher { _, _ in
            throw CancellationError()
        }
        let app = OpenGrokApplication(launcher: cancellingLauncher)

        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "-p", "test cancellation"],
            environment: fixture.environment,
            streams: streams,
            application: app
        )

        #expect(code == CLIRunner.ExitCode.cancelled.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("open-grok: operation cancelled."))
    }

    @Test("version policy gate blocks execution when minimum version is not met")
    func versionPolicyGateRejection() async throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        var blockedEnv = fixture.environment
        blockedEnv["GROK_REQUIRED_MINIMUM_VERSION"] = "999.0.0"

        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "-p", "should be blocked by policy"],
            environment: blockedEnv,
            streams: streams,
            application: .unavailable
        )

        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("is older than the minimum required by your organization"))
    }

    @Test("stream separation guarantees pure JSON on stdout with no log pollution")
    func streamSeparation() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        let commandsWithJSON: [[String]] = [
            ["version", "--json"],
            ["paths", "--json"],
            ["models", "--json"],
            ["models", "list", "--json"]
        ]

        for cmd in commandsWithJSON {
            let (streams, out, err) = CLIStreams.buffered()
            let code = CLIRunner.main(cmd, environment: fixture.environment, streams: streams)
            #expect(code == CLIRunner.ExitCode.success.rawValue)
            #expect(!out.contents.isEmpty)
            #expect(err.contents.isEmpty)

            // Validate that stdout is 100% parseable JSON
            let data = Data(out.contents.utf8)
            let parsed = try? JSONSerialization.jsonObject(with: data)
            #expect(parsed != nil)
        }
    }

    @Test("sync sessions commands list, show, and delete work hermetically")
    func syncSessionsCrud() throws {
        let fixture = try CLIFixture()
        defer { fixture.cleanup() }

        let sessionsDir = fixture.home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // 1. List empty sessions
        let (list1Streams, list1Out, list1Err) = CLIStreams.buffered()
        let list1Code = CLIRunner.main(["sessions", "list"], environment: fixture.environment, streams: list1Streams)
        #expect(list1Code == CLIRunner.ExitCode.success.rawValue)
        #expect(list1Out.contents == "No sessions found.\n")
        #expect(list1Err.contents.isEmpty)

        // 2. Create session file
        let sessionID = "cli-crud-sess"
        let sessionJSON = """
        {
            "sessionID": "\(sessionID)",
            "workingDirectory": "/tmp/work",
            "createdAt": 700000000,
            "updatedAt": 700000500,
            "items": [{"type": "user", "content": [{"type": "text", "text": "Execute CLI tests"}]}]
        }
        """
        try Data(sessionJSON.utf8).write(to: sessionsDir.appendingPathComponent("\(sessionID).json"))

        // 3. Show session
        let (showStreams, showOut, showErr) = CLIStreams.buffered()
        let showCode = CLIRunner.main(["sessions", "show", sessionID], environment: fixture.environment, streams: showStreams)
        #expect(showCode == CLIRunner.ExitCode.success.rawValue)
        #expect(showOut.contents.contains("Session:    \(sessionID)"))
        #expect(showOut.contents.contains("Execute CLI tests"))
        #expect(showErr.contents.isEmpty)

        // 4. Delete session
        let (delStreams, delOut, delErr) = CLIStreams.buffered()
        let delCode = CLIRunner.main(["sessions", "delete", sessionID], environment: fixture.environment, streams: delStreams)
        #expect(delCode == CLIRunner.ExitCode.success.rawValue)
        #expect(delOut.contents == "Deleted session \(sessionID)\n")
        #expect(delErr.contents.isEmpty)

        // 5. Show deleted session returns failure (ExitCode 1)
        let (badShowStreams, badShowOut, badShowErr) = CLIStreams.buffered()
        let badShowCode = CLIRunner.main(["sessions", "show", sessionID], environment: fixture.environment, streams: badShowStreams)
        #expect(badShowCode == CLIRunner.ExitCode.failure.rawValue)
        #expect(badShowOut.contents.isEmpty)
        #expect(badShowErr.contents.contains(sessionID))
    }
}
