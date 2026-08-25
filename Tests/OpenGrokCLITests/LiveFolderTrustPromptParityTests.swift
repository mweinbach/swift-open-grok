import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFastWorktree
import OpenGrokHooks
import OpenGrokLSP
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokTerminalCore
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private final class FolderTrustPromptProbe: PagerTerminalSink, @unchecked Sendable {
    enum Response: Sendable {
        case answer(KeyEvent, following: [InputEvent] = [], finish: Bool = false)
        case eof
        case none
    }

    private let lock = NSLock()
    private let response: Response
    private let stream: AsyncThrowingStream<InputEvent, Error>
    private let continuation: AsyncThrowingStream<InputEvent, Error>.Continuation
    private var pendingStartup: [InputEvent]
    private var emittedEventCount: UInt64 = 0
    private var terminalOutput = ""
    private var answered = false
    private var samplerCount = 0
    private var leaderCount = 0
    private var closedCount = 0
    private var sampledTools: [[String]] = []
    private var promptSamplerCount: Int?
    private var promptLeaderCount: Int?

    var capabilities: PagerTerminalCapabilities { .standard }

    init(response: Response, startup: [InputEvent] = []) {
        self.response = response
        pendingStartup = startup
        let pair = AsyncThrowingStream<InputEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func makeInput() -> OpenGrokLiveInteractiveInput {
        let startup = lock.withLock { () -> [InputEvent] in
            defer { pendingStartup.removeAll() }
            return pendingStartup
        }
        for event in startup {
            emit(event)
        }
        return OpenGrokLiveInteractiveInput(
            events: stream,
            close: { [self] in
                lock.withLock { closedCount += 1 }
                continuation.finish()
            },
            emittedEventCount: { [self] in lock.withLock { emittedEventCount } }
        )
    }

    func terminalWrite(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let shouldRespond = lock.withLock { () -> Bool in
            terminalOutput += text
            guard text.contains("Do you trust the contents of this directory?"), !answered else {
                return false
            }
            answered = true
            promptSamplerCount = samplerCount
            promptLeaderCount = leaderCount
            return true
        }
        guard shouldRespond else { return }

        switch response {
        case .answer(let answer, let following, let finish):
            emit(.key(answer))
            for event in following { emit(event) }
            if finish { continuation.finish() }
        case .eof:
            continuation.finish()
        case .none:
            return
        }
    }

    private func emit(_ event: InputEvent) {
        lock.withLock {
            emittedEventCount += 1
            continuation.yield(event)
        }
    }

    func write(bytes: [UInt8]) throws {}
    func flush() throws {}

    func madeSampler() {
        lock.withLock { samplerCount += 1 }
    }

    func madeLeader() {
        lock.withLock { leaderCount += 1 }
    }

    func sampled(_ tools: [String]) -> Int {
        lock.withLock {
            sampledTools.append(tools)
            return sampledTools.count
        }
    }

    func finishInput() {
        continuation.finish()
    }

    var text: String { lock.withLock { terminalOutput } }
    var samplers: Int { lock.withLock { samplerCount } }
    var leaders: Int { lock.withLock { leaderCount } }
    var closes: Int { lock.withLock { closedCount } }
    var toolNames: [[String]] { lock.withLock { sampledTools } }
    var factoriesAtPrompt: (samplers: Int?, leaders: Int?) {
        lock.withLock { (promptSamplerCount, promptLeaderCount) }
    }
}

private struct FolderTrustPromptFixture {
    let root: URL
    let home: URL
    let ownerState: URL
    let workspace: URL
    let environment: [String: String]

    var trustPath: URL { ownerState.appendingPathComponent("trusted_folders.toml") }
    var sessionsPath: URL { ownerState.appendingPathComponent("sessions") }

    init(git: Bool = true, executableConfiguration: Bool = true) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-trust-prompt-\(UUID().uuidString)")
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(temporary, stateRoot: temporary)
        #else
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        #endif
        root = temporary.standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("owner")
        ownerState = home.appendingPathComponent(".opengrok")
        workspace = root.appendingPathComponent("workspace")
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(ownerState, stateRoot: ownerState)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        #else
        for directory in [ownerState, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #endif
        if git {
            let initialized = try runGit(["init", "--quiet"], cwd: workspace)
            guard initialized.exitCode == 0 else {
                throw CLIApplicationError.failed("could not initialize folder-trust fixture repository")
            }
        }
        if executableConfiguration {
            let project = workspace.appendingPathComponent(".opengrok")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "[trust_prompt_fixture]\nproject_loaded = true\n".write(
                to: project.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        try "[features]\nremote_fetch = false\n".write(
            to: ownerState.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": ownerState.path,
            "GROK_SANDBOX": "off",
            "XAI_API_KEY": "folder-trust-prompt-test-credential",
            "GROK_FOLDER_TRUST": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func terminal(for probe: FolderTrustPromptProbe, tty: Bool = true) -> OpenGrokLiveTerminal {
        OpenGrokLiveTerminal(
            isTTY: { tty },
            size: { OpenGrokLiveTerminalSize(width: 110, height: 35) },
            write: { data in probe.terminalWrite(data) }
        )
    }

    func preflight(
        probe: FolderTrustPromptProbe,
        directory: URL? = nil,
        environment override: [String: String]? = nil,
        explicitTrust: Bool = false,
        surface: Bool = true,
        tty: Bool = true,
        authenticationReady: Bool = true
    ) async throws -> LiveFolderTrustPromptResult {
        let input = surface ? probe.makeInput() : nil
        return try await LiveFolderTrustPrompt.preflight(
            workingDirectory: directory ?? workspace,
            environment: override ?? environment,
            explicitTrust: explicitTrust,
            interactiveInput: input,
            hasInteractiveSurface: surface,
            terminal: terminal(for: probe, tty: tty),
            authenticationReady: authenticationReady
        )
    }

    func startLauncher(
        probe: FolderTrustPromptProbe,
        arguments: [String] = [],
        environment override: [String: String]? = nil,
        requestDiagnostics: Bool = false,
        includeWorkingDirectory: Bool = true,
        remoteSettings: RemoteSettings? = nil
    ) async throws -> CLIApplicationSession {
        let launchEnvironment = override ?? environment
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                probe.madeSampler()
                return OpenGrokLiveSampler { request, emit in
                    let count = probe.sampled(request.tools.map(\.name))
                    if requestDiagnostics, count == 1 {
                        return OpenGrokLiveSamplingResponse(
                            output: "",
                            toolCalls: [ToolCall(
                                id: "trust-prompt-diagnostics",
                                name: "pull_diagnostics",
                                arguments: #"{"path":"Sample.swift"}"#
                            )]
                        )
                    }
                    await emit(.output("folder-trust approved"))
                    probe.finishInput()
                    return OpenGrokLiveSamplingResponse(output: "folder-trust approved")
                }
            },
            terminal: terminal(for: probe),
            makeInteractiveInput: { probe.makeInput() },
            makeTerminalSink: { probe },
            remoteSettingsSnapshot: remoteSettings,
            makeLeaderClient: { _ in
                probe.madeLeader()
                throw CLIApplicationError.failed("leader connection reached")
            }
        )
        let directoryArguments = includeWorkingDirectory ? ["--cwd", workspace.path] : []
        let command = try CLICommandParser.parseOrThrow(
            directoryArguments + ["--model", "grok-4.5"] + arguments
        )
        let context = CLIApplicationContext(
            environment: launchEnvironment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        return try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
    }

    func writeExecutableSurfaces(mcpMarker: URL, hookMarker: URL, lspMarker: URL) throws {
        let project = workspace.appendingPathComponent(".opengrok")
        let hookDirectory = project.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)

        #if os(Windows)
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")
            .appendingPathComponent("System32/cmd.exe").path
        let mcpArguments = ["/d", "/c", "echo started > \"\(mcpMarker.path)\""]
        let lspArguments = ["/d", "/c", "echo started > \"\(lspMarker.path)\""]
        let hookCommand = "\"\(executable)\" /d /c echo started > \"\(hookMarker.path)\""
        #else
        let executable = "/usr/bin/touch"
        let mcpArguments = [mcpMarker.path]
        let lspArguments = [lspMarker.path]
        let hookCommand = "/usr/bin/touch '\(hookMarker.path)'"
        #endif

        let encodedExecutable = String(decoding: try JSONEncoder().encode(executable), as: UTF8.self)
        let encodedArguments = String(decoding: try JSONEncoder().encode(mcpArguments), as: UTF8.self)
        try """
        [trust_prompt_fixture]
        project_loaded = true

        [mcp_servers.prompt_fixture]
        command = \(encodedExecutable)
        args = \(encodedArguments)
        """.write(to: project.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let hooks: [String: Any] = [
            "hooks": ["SessionStart": [["hooks": [["type": "command", "command": hookCommand]]]]],
        ]
        try JSONSerialization.data(withJSONObject: hooks)
            .write(to: hookDirectory.appendingPathComponent("session.json"))

        let server = LspServerConfig(
            command: executable,
            args: lspArguments,
            extensions: [".swift": "swift"]
        )
        try JSONEncoder().encode(["project": server]).write(to: project.appendingPathComponent("lsp.json"))
        try "let visible = true\n".write(
            to: workspace.appendingPathComponent("Sample.swift"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@Suite("initial interactive folder-trust prompt and pre-session authority")
struct LiveFolderTrustPromptParityTests {
    @Test("the real launcher paints upstream's warning and refusal creates no session or provider")
    func refusalStopsBeforeEverySessionSideEffect() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "n")))

        let session = try await fixture.startLauncher(probe: probe, arguments: ["do not start"])
        try await session.waitForExit()
        await session.shutdown()

        #expect(probe.samplers == 0)
        #expect(probe.leaders == 0)
        #expect(probe.factoriesAtPrompt.samplers == 0)
        #expect(probe.factoriesAtPrompt.leaders == 0)
        #expect(probe.closes >= 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionsPath.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
        #expect(probe.text.contains("Do you trust the contents of this directory?"))
        #expect(probe.text.contains(fixture.workspace.path))
        #expect(probe.text.contains("Open Grok may run or modify contents in this directory,"))
        #expect(probe.text.contains("posing security risks."))
        #expect(probe.text.contains("Yes, proceed"))
        #expect(probe.text.contains("No, quit"))
    }

    @Test("interactive leader refusal happens before connecting to or spawning the leader")
    func leaderRefusalNeverConnects() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: .escape)))

        let session = try await fixture.startLauncher(probe: probe, arguments: ["--leader", "blocked"])
        try await session.waitForExit()
        await session.shutdown()

        #expect(probe.leaders == 0)
        #expect(probe.samplers == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionsPath.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("worktree refusal occurs before a checkout, registry, session, or provider exists")
    func worktreeRefusalNeverCreatesCheckout() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "n")))

        let session = try await fixture.startLauncher(probe: probe, arguments: ["--worktree"])
        try await session.waitForExit()
        await session.shutdown()

        #expect(probe.samplers == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.ownerState.appendingPathComponent("worktrees").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.ownerState.appendingPathComponent("worktrees.db").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionsPath.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("leader connection is attempted only after the interactive grant is durable")
    func leaderAcceptancePersistsBeforeConnecting() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "y")))

        do {
            let session = try await fixture.startLauncher(probe: probe, arguments: ["--leader", "allowed"])
            await session.shutdown()
            Issue.record("the fixture leader unexpectedly connected")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("leader connection reached"))
        }

        #expect(probe.leaders == 1)
        #expect(probe.factoriesAtPrompt.leaders == 0)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
    }

    @Test("acceptance enables genuine project MCP, SessionStart hooks, and LSP in the first session")
    func firstApprovedSessionLoadsEveryExecutableProjectSurface() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let mcpMarker = fixture.root.appendingPathComponent("project-mcp-started")
        let hookMarker = fixture.root.appendingPathComponent("project-hook-started")
        let lspMarker = fixture.root.appendingPathComponent("project-lsp-started")
        try fixture.writeExecutableSurfaces(mcpMarker: mcpMarker, hookMarker: hookMarker, lspMarker: lspMarker)
        var environment = fixture.environment
        environment["GROK_LSP_TOOLS"] = "1"
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "Y")))

        let session = try await fixture.startLauncher(
            probe: probe,
            arguments: ["inspect Sample.swift"],
            environment: environment,
            requestDiagnostics: true
        )
        try await session.waitForExit()

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: hookMarker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.shutdown()

        #expect(probe.factoriesAtPrompt.samplers == 0)
        #expect(probe.samplers == 1)
        #expect(probe.toolNames.first?.contains("pull_diagnostics") == true)
        #expect(PersistentFolderTrustStore(environment: environment).isTrusted(fixture.workspace))
        #expect(FileManager.default.fileExists(atPath: mcpMarker.path))
        #expect(FileManager.default.fileExists(atPath: hookMarker.path))
        #expect(FileManager.default.fileExists(atPath: lspMarker.path))
    }

    @Test("a non-Git folder can grant trust for its canonical working directory")
    func nonGitWorkspaceUsesCanonicalDirectory() async throws {
        let fixture = try FolderTrustPromptFixture(git: false)
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: .enter)))

        let outcome = try await fixture.preflight(probe: probe)

        guard case .proceed(let input) = outcome else {
            Issue.record("non-Git folder trust unexpectedly refused explicit consent")
            return
        }
        await input?.close()
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
        #expect(probe.text.contains(fixture.workspace.path))
    }

    @Test("a nested Git checkout grants its repository root rather than its current subdirectory")
    func nestedGitDirectoryGrantsRepositoryRoot() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let nested = fixture.workspace.appendingPathComponent("deep/source")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "y")))

        let outcome = try await fixture.preflight(probe: probe, directory: nested)
        guard case .proceed(let input) = outcome else {
            Issue.record("nested Git checkout did not accept folder trust")
            return
        }
        await input?.close()

        let persisted = try String(contentsOf: fixture.trustPath, encoding: .utf8)
        #if os(Windows)
        let document = try parseTOML(persisted)
        guard case .table(let documentRoot) = document,
              case .table(let folders)? = documentRoot["folders"]
        else {
            Issue.record("folder-trust store did not contain a readable folders table")
            return
        }
        let normalizePath = { (path: String) in
            URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
                .replacingOccurrences(of: "\\", with: "/")
                .lowercased()
        }
        let persistedRoots = folders.pairs.map { normalizePath($0.0) }
        #expect(persistedRoots.contains(normalizePath(fixture.workspace.path)))
        #expect(!persistedRoots.contains(normalizePath(nested.path)))
        #else
        #expect(persisted.contains(fixture.workspace.path))
        #expect(!persisted.contains(nested.path))
        #endif
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(nested))
    }

    @Test("capital N, Escape, Ctrl-C, Ctrl-D, and EOF refuse without writing trust", arguments: [
        KeyEvent(key: "N"),
        KeyEvent(key: .escape),
        KeyEvent(key: .char("c"), modifiers: .control),
        KeyEvent(key: .char("d"), modifiers: .control),
    ])
    func refusalKeysFailClosed(_ key: KeyEvent) async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .answer(key))

        let outcome = try await fixture.preflight(probe: probe)

        guard case .cancelled = outcome else {
            Issue.record("refusal key \(key) unexpectedly authorized project code")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("EOF at the trust question never authorizes a repository")
    func eofFailsClosed() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .eof)

        let outcome = try await fixture.preflight(probe: probe)

        guard case .cancelled = outcome else {
            Issue.record("EOF unexpectedly authorized project code")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("paste, unrelated keys, and startup typeahead cannot answer the trust question")
    func startupTypeaheadAndPasteAreNotConsent() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(
            response: .answer(
                KeyEvent(key: "y"),
                following: [.key(KeyEvent(key: "q"))],
                finish: true
            ),
            startup: [
                .key(KeyEvent(key: "n")),
                .paste("y"),
                .key(KeyEvent(key: "y")),
                .key(KeyEvent(key: "x")),
            ]
        )

        let outcome = try await fixture.preflight(probe: probe)

        guard case .proceed(let input?) = outcome else {
            Issue.record("startup typeahead answered the question instead of being discarded")
            return
        }
        var iterator = input.events.makeAsyncIterator()
        let remaining = try await iterator.next()
        #expect(remaining == .key(KeyEvent(key: "q")))
        #expect(try await iterator.next() == nil)
        await input.close()
    }

    @Test("unsequenced startup input cannot authorize an untrusted repository")
    func unsequencedStartupFailsClosed() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .none)
        let pair = AsyncThrowingStream<InputEvent, Error>.makeStream()
        pair.continuation.yield(.key(KeyEvent(key: "y")))
        let input = OpenGrokLiveInteractiveInput(
            events: pair.stream,
            close: { pair.continuation.finish() }
        )

        await #expect(throws: CLIApplicationError.self) {
            try await LiveFolderTrustPrompt.preflight(
                workingDirectory: fixture.workspace,
                environment: fixture.environment,
                explicitTrust: false,
                interactiveInput: input,
                hasInteractiveSurface: true,
                terminal: fixture.terminal(for: probe)
            )
        }

        #expect(probe.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
        await input.close()
    }

    @Test("events after the answer survive the relay in their original order")
    func postGrantInputIsForwardedLosslessly() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let forwarded: [InputEvent] = [
            .paste("inspect the repository"),
            .key(KeyEvent(key: .enter)),
            .key(KeyEvent(key: "z")),
        ]
        let probe = FolderTrustPromptProbe(
            response: .answer(KeyEvent(key: "y"), following: forwarded, finish: true)
        )

        let outcome = try await fixture.preflight(probe: probe)

        guard case .proceed(let input?) = outcome else {
            Issue.record("explicit consent did not return an interactive input relay")
            return
        }
        var received: [InputEvent] = []
        for try await event in input.events { received.append(event) }
        #expect(received == forwarded)
        await input.close()
    }

    @Test("a prior durable grant never prompts again or rewrites the trust decision")
    func durableTrustSkipsQuestion() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        var store = PersistentFolderTrustStore(environment: fixture.environment)
        try store.record(fixture.workspace, trusted: true)
        let before = try Data(contentsOf: fixture.trustPath)
        let probe = FolderTrustPromptProbe(response: .none)

        let outcome = try await fixture.preflight(probe: probe)

        guard case .proceed(let input) = outcome else {
            Issue.record("persisted trust unexpectedly blocked startup")
            return
        }
        await input?.close()
        #expect(probe.text.isEmpty)
        #expect(try Data(contentsOf: fixture.trustPath) == before)
    }

    @Test("a checkout with no executable project configuration never prompts")
    func ordinaryCheckoutSkipsQuestion() async throws {
        let fixture = try FolderTrustPromptFixture(executableConfiguration: false)
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .none)

        let outcome = try await fixture.preflight(probe: probe)

        guard case .proceed(let input) = outcome else {
            Issue.record("an ordinary checkout was incorrectly gated")
            return
        }
        await input?.close()
        #expect(probe.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("owner-controlled folder-trust disable suppresses the interactive question")
    func ownerFeatureFlagDisablesQuestion() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_FOLDER_TRUST"] = "0"
        let probe = FolderTrustPromptProbe(response: .none)

        let outcome = try await fixture.preflight(probe: probe, environment: environment)

        guard case .proceed(let input) = outcome else {
            Issue.record("disabled folder trust still blocked startup")
            return
        }
        await input?.close()
        #expect(probe.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("an untrusted repository cannot disable the trust question in its own configuration")
    func projectCannotDisableItsOwnConsentGate() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        try "[folder_trust]\nenabled = false\n".write(
            to: fixture.workspace.appendingPathComponent(".opengrok/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        var environment = fixture.environment
        environment.removeValue(forKey: "GROK_FOLDER_TRUST")
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "n")))

        let outcome = try await fixture.preflight(probe: probe, environment: environment)

        guard case .cancelled = outcome else {
            Issue.record("repository-owned config disabled its own folder-trust gate")
            return
        }
        #expect(probe.text.contains("Do you trust the contents of this directory?"))
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("headless and non-TTY compositions never ask or create an implicit grant")
    func noninteractiveSurfacesStayFailClosed() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }

        let headless = FolderTrustPromptProbe(response: .none)
        let headlessResult = try await fixture.preflight(probe: headless, surface: false, tty: false)
        guard case .proceed(nil) = headlessResult else {
            Issue.record("headless launch unexpectedly requested folder trust")
            return
        }

        let redirected = FolderTrustPromptProbe(response: .none)
        let redirectedResult = try await fixture.preflight(probe: redirected, tty: false)
        guard case .proceed(let input) = redirectedResult else {
            Issue.record("redirected terminal unexpectedly requested folder trust")
            return
        }
        await input?.close()
        #expect(headless.text.isEmpty)
        #expect(redirected.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("login, access, and ZDR gates suppress the trust question and never persist consent")
    func unresolvedAuthenticationNeverPromptsOrGrants() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .none)

        let outcome = try await fixture.preflight(probe: probe, authenticationReady: false)

        guard case .proceed(let input) = outcome else {
            Issue.record("unresolved authentication unexpectedly intercepted launch")
            return
        }
        await input?.close()
        #expect(probe.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("the actual unauthenticated launcher cannot permanently trust a repository")
    func unauthenticatedLauncherNeverPromptsOrGrants() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment.removeValue(forKey: "XAI_API_KEY")
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "y")))

        do {
            let session = try await fixture.startLauncher(probe: probe, environment: environment)
            await session.shutdown()
            Issue.record("unauthenticated launcher unexpectedly initialized a provider session")
        } catch {
            #expect(String(describing: error).contains("required"))
        }

        #expect(probe.text.isEmpty)
        #expect(probe.samplers == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("an xAI access-gated account never sees or answers folder trust")
    func accessBlockedLauncherNeverPromptsOrGrants() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        var settings = RemoteSettings()
        settings.gateMessage = "access blocked"
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "y")))

        let session = try await fixture.startLauncher(probe: probe, remoteSettings: settings)
        await session.shutdown()

        #expect(probe.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("a blocked ZDR identity never receives a durable folder-trust grant")
    func blockedZDRLauncherNeverPromptsOrGrants() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment.removeValue(forKey: "XAI_API_KEY")
        let config = GrokComConfig.default(environment: environment)
        let auth = GrokAuth(
            key: "zdr-trust-prompt-token",
            authMode: .oidc,
            userID: "zdr-user",
            teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"],
            oidcIssuer: xaiOAuth2Issuer
        )
        try writeAuthJSON(
            at: fixture.ownerState.appendingPathComponent("auth.json"),
            store: [config.authScope: auth]
        )
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "y")))

        let session = try await fixture.startLauncher(probe: probe, environment: environment)
        await session.shutdown()

        #expect(probe.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("cross-workspace resume prompts for the stored session's actual repository")
    func resumedWorkspaceIsPromptedInsteadOfProcessDirectory() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let sessionID = "trust-prompt-cross-workspace"
        let record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: fixture.workspace)
        let store = LiveConversationStore(openGrokHome: fixture.ownerState)
        try await store.save(record)
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "n")))

        let session = try await fixture.startLauncher(
            probe: probe,
            arguments: ["--resume", sessionID],
            includeWorkingDirectory: false
        )
        try await session.waitForExit()
        await session.shutdown()

        #expect(probe.text.contains(fixture.workspace.path))
        #expect(probe.samplers == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.trustPath.path))
    }

    @Test("explicit --trust preserves Rust's pre-authentication durable grant semantics")
    func explicitTrustRemainsIndependentOfAuthentication() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .none)

        let outcome = try await fixture.preflight(
            probe: probe,
            explicitTrust: true,
            surface: false,
            authenticationReady: false
        )

        guard case .proceed(nil) = outcome else {
            Issue.record("explicit --trust was incorrectly conditioned on provider authentication")
            return
        }
        #expect(probe.text.isEmpty)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
    }

    @Test("--trust persists before startup without displaying an interactive question")
    func explicitTrustPersistsWithoutQuestion() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        let probe = FolderTrustPromptProbe(response: .none)

        let outcome = try await fixture.preflight(probe: probe, explicitTrust: true, surface: false)

        guard case .proceed(nil) = outcome else {
            Issue.record("explicit CLI trust did not admit startup")
            return
        }
        #expect(probe.text.isEmpty)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
    }

    @Test("a failed durable grant refuses startup instead of authorizing transient project code")
    func failedPersistenceNeverAuthorizesProject() async throws {
        let fixture = try FolderTrustPromptFixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(at: fixture.trustPath, withIntermediateDirectories: true)
        let probe = FolderTrustPromptProbe(response: .answer(KeyEvent(key: "y")))

        do {
            let outcome = try await fixture.preflight(probe: probe)
            if case .proceed(let input) = outcome { await input?.close() }
            Issue.record("a failed durable write unexpectedly admitted project configuration")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("Failed to persist folder trust"))
        }
        #expect(!PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
    }
}
