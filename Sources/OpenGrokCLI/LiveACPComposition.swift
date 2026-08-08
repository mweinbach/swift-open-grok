// LiveACPComposition.swift
//
// The `open-grok acp` / `open-grok agent stdio` route, plus the honest
// disposition of `serve` and `leader`.
//
// The wire half lives in `OpenGrokACPRuntime`: `ACPAgentRuntime` implements
// the agent side of ACP, `ACPStdioTransport` supplies the newline-delimited
// JSON-RPC framing, and `ACPStandardIO`/`ACPStdioHost` bind that to real
// process descriptors. This file is the CLI seam over those pieces.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`):
//
//   * `crates/codegen/xai-grok-pager/src/app/cli.rs:314-324` — upstream spells
//     these as `agent stdio|headless|serve|leader`. This port additionally
//     accepts the bare `acp` spelling, which `CLICommand.parseAgent`
//     (`CLICommand.swift:531-533`) already maps onto `.acp` launch mode.
//   * `crates/codegen/xai-grok-shell/src/agent/app.rs:290` (`run_stdio_agent`)
//     — the stdio surface this route reproduces.
//
// Like the other live compositions, the launcher hook that routes here belongs
// in `LiveComposition.swift`, which the integration slice owns.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellSessionSupport

// MARK: - Injected services

/// The one thing this route cannot build for itself.
///
/// Everything on the ACP wire — initialize, session lifecycle, prompt
/// bookkeeping, notification fan-out, cancellation — is implemented by
/// `ACPAgentRuntime`. What remains is the driver that actually calls a model,
/// and building one needs the sampler/provider stack that the launch path in
/// `LiveComposition.swift` assembles (`LiveShellSamplingDriver` there is
/// file-private). So it is injected rather than reconstructed, and the default
/// refuses loudly instead of quietly answering nothing.
public struct LiveACPServices: Sendable {
    public var makePromptDriver: @Sendable (LiveACPLaunch) async throws -> LiveACPPromptDriver
    private let makeComponentsOperation: @Sendable (LiveACPLaunch) async throws -> LiveACPLaunchComponents

    public init(
        makePromptDriver: @escaping @Sendable (LiveACPLaunch) async throws -> LiveACPPromptDriver
    ) {
        self.makePromptDriver = makePromptDriver
        self.makeComponentsOperation = { launch in
            LiveACPLaunchComponents(promptDriver: try await makePromptDriver(launch))
        }
    }

    public init(
        makeComponents: @escaping @Sendable (LiveACPLaunch) async throws -> LiveACPLaunchComponents
    ) {
        self.makeComponentsOperation = makeComponents
        self.makePromptDriver = { launch in
            try await makeComponents(launch).promptDriver
        }
    }

    /// Internal (not fileprivate): `LiveServeComposition` builds the same
    /// components so the ws:// carrier serves the same extension-method
    /// surface stdio serves — a serve host that silently dropped the router
    /// would answer every `open-grok/*`/`x.ai/*` method "unknown" while the
    /// stdio agent answered them, an untestable carrier divergence.
    func makeComponents(
        _ launch: LiveACPLaunch
    ) async throws -> LiveACPLaunchComponents {
        try await makeComponentsOperation(launch)
    }

    /// The default. A no-op driver would make `session/prompt` return an empty
    /// turn and look like a working agent, so this refuses with a message that
    /// names the missing piece.
    public static let unavailable = LiveACPServices(makePromptDriver: { _ in
        throw CLIApplicationError.failed(
            """
            the ACP stdio agent has no prompt driver wired in this build.
            The ACP protocol surface is available, but answering `session/prompt` \
            needs the live sampler stack, which the launcher must supply via \
            LiveACPServices(makePromptDriver:) — see LiveACPComposition.
            """
        )
    })
}

public struct LiveACPLaunchComponents: Sendable {
    public let promptDriver: LiveACPPromptDriver
    public let extensionHandler: (any ACPAgentExtensionHandler)?
    /// Inbound ext-notification dispatch (`x.ai/yolo_mode_changed`,
    /// `x.ai/swarm_mode_changed`, `x.ai/permissions/reset`) — handed to the
    /// runtime beside the method router.
    public let extensionNotifications: ACPExtensionNotificationRouter?
    /// Outbound gateway the composition's emitters (recap, swarm acks, the
    /// subagent mailbox observer) hold. The carrier host attaches the built
    /// runtime to it; a components value whose gateway is never attached
    /// emits into the void, which is why both carrier compositions attach
    /// immediately after construction.
    public let notificationGateway: ACPNotificationGateway?

    public init(
        promptDriver: LiveACPPromptDriver,
        extensionHandler: (any ACPAgentExtensionHandler)? = nil,
        extensionNotifications: ACPExtensionNotificationRouter? = nil,
        notificationGateway: ACPNotificationGateway? = nil
    ) {
        self.promptDriver = promptDriver
        self.extensionHandler = extensionHandler
        self.extensionNotifications = extensionNotifications
        self.notificationGateway = notificationGateway
    }
}

/// A prompt driver plus the teardown for the stack behind it.
///
/// The live driver owns a tool executor and possibly a Code Mode runtime, both
/// of which hold processes. The ACP session has to shut those down when the
/// peer disconnects, and only the factory that built them knows how — so the
/// teardown travels with the driver instead of being reconstructed here.
public struct LiveACPPromptDriver: ACPPromptDriver {
    private let driver: any ACPPromptDriver
    private let availableCommands: [AvailableCommand]
    private let skillCatalog: [LiveSkills.SkillCommand]
    public let shutdown: @Sendable () async -> Void

    public init(
        driver: any ACPPromptDriver,
        availableCommands: [AvailableCommand] = [],
        skillCatalog: [LiveSkills.SkillCommand] = [],
        shutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.driver = driver
        self.availableCommands = availableCommands
        self.skillCatalog = skillCatalog
        self.shutdown = shutdown
    }

    public func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        if !availableCommands.isEmpty {
            await emit(
                SessionNotification(
                    sessionId: context.request.sessionId,
                    update: .availableCommandsUpdate(
                        AvailableCommandsUpdate(availableCommands: availableCommands)
                    )
                ),
                .durable
            )
        }

        var adaptedContext = context
        let text = context.request.prompt.compactMap { block -> String? in
            guard case let .text(value) = block else { return nil }
            return value.text
        }.joined()
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let first = tokens.first,
           first.hasPrefix("/"),
           !skillCatalog.isEmpty {
            let commandName = String(first.dropFirst()).lowercased()
            let args = tokens.dropFirst().joined(separator: " ")
            if let expanded = LiveSkills.invocationPrompt(
                commandName: commandName,
                args: args,
                catalog: skillCatalog,
                sessionID: context.session.sessionId.rawValue
            ) {
                var request = context.request
                request.prompt = [.text(expanded)]
                adaptedContext = ACPPromptContext(session: context.session, request: request)
            }
        }
        return try await driver.run(context: adaptedContext, emit: emit)
    }

    public func cancel(sessionId: AcpSessionId) async {
        await driver.cancel(sessionId: sessionId)
    }
}

/// What the launcher knows about the run, handed to the driver factory.
public struct LiveACPLaunch: Sendable {
    public var workingDirectory: URL
    public var openGrokHome: URL
    public var environment: [String: String]
    public var streams: CLIStreams
    public var options: CLIExecutionOptions

    public init(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        streams: CLIStreams,
        options: CLIExecutionOptions
    ) {
        self.workingDirectory = workingDirectory
        self.openGrokHome = openGrokHome
        self.environment = environment
        self.streams = streams
        self.options = options
    }
}

// MARK: - Composition

public enum LiveACPComposition {
    public static let routeName = "acp"

    public static func handles(_ command: CLICommand) -> Bool {
        switch command {
        case .launch(let options): return options.mode == .acp
        case .serve, .leader: return true
        default: return false
        }
    }

    /// Launcher entry point.
    ///
    /// Unlike the auth/mcp routes this one is long-lived: it hands back a
    /// session whose `waitForExit` is the serve loop, so the process stays up
    /// until the peer closes stdin.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveACPServices = .unavailable
    ) async throws -> CLIApplicationSession {
        switch command {
        case .launch(let options) where options.mode == .acp:
            return try await stdioSession(
                options: options,
                context: context,
                services: services
            )
        case .serve(let options):
            throw serveUnsupported(options)
        case .leader(let options):
            throw leaderUnsupported(options)
        default:
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
    }

    // MARK: stdio

    /// Build the runtime and serve it over the process's own stdin/stdout.
    ///
    /// `transport` is injectable so tests can drive the exact same composition
    /// over a pipe pair instead of the real handles.
    public static func stdioSession(
        options: CLIExecutionOptions,
        context: CLIApplicationContext,
        services: LiveACPServices = .unavailable,
        transport: (any ACPTransport)? = nil
    ) async throws -> CLIApplicationSession {
        let cwd = try resolveWorkingDirectory(options.common.cwd)
        let home = OpenGrokHomeResolver.resolve(environment: context.environment)
        let runtimeSessionID = options.sessionID ?? UUID().uuidString
        var launchOptions = options
        launchOptions.sessionID = runtimeSessionID
        let launch = LiveACPLaunch(
            workingDirectory: cwd,
            openGrokHome: home,
            environment: context.environment,
            streams: context.streams,
            options: launchOptions
        )
        let launchComponents = try await services.makeComponents(launch)

        // The same shapes Shell uses for its own sessions
        // (`OpenGrokShell.swift:483-500`): an in-memory ACP snapshot store and
        // the local workspace boundary rooted at the launch cwd. Reusing
        // `DefaultOpenGrokShellACPRuntimeFactory` keeps the two paths from
        // drifting apart.
        let workspace = LocalOpenGrokShellWorkspace(root: cwd, openGrokHome: home)
        let runtimeComponents = DefaultOpenGrokShellACPRuntimeFactory().makeRuntime(
            sessionID: SessionID(runtimeSessionID),
            cwd: cwd,
            workspace: workspace,
            promptDriver: launchComponents.promptDriver,
            extensionHandler: launchComponents.extensionHandler,
            extensionNotifications: launchComponents.extensionNotifications
        )
        // The outbound half of the notification gateway: the components'
        // emitters (recap, swarm acks, the mailbox observer) now target THIS
        // runtime, whose notification sink is the stdio writer once the host
        // serves it.
        if let gateway = launchComponents.notificationGateway {
            await gateway.attach(runtimeComponents.runtime)
        }
        let host = ACPStdioHost(
            runtime: runtimeComponents.runtime,
            transport: transport ?? ACPStdioTransport(io: ACPStandardIO())
        )
        return CLIApplicationSession(
            waitForExit: { await host.run() },
            shutdown: {
                // Runtime first so an in-flight prompt is cancelled, then the
                // transport, then the tool executor and Code Mode processes
                // the driver owns.
                await host.shutdown()
                await launchComponents.promptDriver.shutdown()
            }
        )
    }

    private static func resolveWorkingDirectory(_ path: String?) throws -> URL {
        guard let path, !path.isEmpty else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CLIApplicationError.failed("working directory does not exist: \(url.path)")
        }
        return url
    }

    // MARK: serve / leader

    /// Why `serve` cannot run here yet.
    ///
    /// Upstream `agent serve` is an **axum WebSocket server**: it binds a
    /// `tokio::net::TcpListener`, exposes exactly one route `GET /ws`, checks
    /// `Authorization: Bearer` or `?server-key=`, and bridges each text frame
    /// into the same ACP JSON-RPC stream stdio uses
    /// (`crates/codegen/xai-grok-shell/src/agent/server.rs:18-27,92-126,
    /// 219-232,375-377,469-485`; banner and defaults at
    /// `crates/codegen/xai-grok-pager-bin/src/main.rs:90-102,1251-1259` and
    /// `crates/codegen/xai-grok-pager/src/app/cli.rs:334-348`).
    ///
    /// This port has no server-side transport at all. `OpenGrokHTTP` ships a
    /// WebSocket **client** only (`WebSocketClient` /
    /// `URLSessionWebSocketClient`, `OpenGrokHTTP.swift:1388-1469`), and
    /// nothing in `Sources/` opens a listening socket — the only listeners in
    /// the tree are test helpers under `OpenGrokTestSupport`, which the
    /// shipping CLI does not and must not link.
    ///
    /// So the honest answer is this error rather than a process that binds
    /// nothing and looks alive. The protocol half is already done and reusable:
    /// `ACPAgentRuntime.serve(_:)` accepts any `ACPTransport`, and
    /// `ACPStandardIO` already speaks the framing over arbitrary file
    /// descriptors, so a local `AF_UNIX` listener is the smallest real
    /// implementation — it needs a socket/bind/listen/accept loop, not new
    /// protocol work.
    static func serveUnsupported(_ options: CLIServeOptions) -> CLIApplicationError {
        CLIApplicationError.failed(
            """
            `serve` is not available: this build has no WebSocket server transport.
            Upstream serves ACP over ws://\(options.bind)/ws?server-key=<secret> \
            (axum + tokio TcpListener); the Swift port ships a WebSocket client only \
            (OpenGrokHTTP.WebSocketClient) and opens no listening socket.
            Use `open-grok acp` (ACP over stdio) for a local agent connection.
            """
        )
    }

    /// Why `leader` cannot run here yet.
    ///
    /// Upstream `agent leader` is a shared-process broker over a **Unix domain
    /// socket** at `{grok_home}/leader{suffix}.sock`
    /// (`crates/codegen/xai-grok-shell/src/leader/lock.rs:12-58`,
    /// `transport.rs:10-12`), framed as a 4-byte big-endian length prefix plus
    /// a JSON `ClientMessage` — `Register`/`Acp`/`Control`/`Ping`/`Disconnect`
    /// (`leader/protocol.rs:8,21-72,200-330`) — with an advisory lock file and
    /// a connect-or-spawn race so the first client starts the leader and the
    /// rest attach (`leader/mod.rs:1443`).
    ///
    /// None of that framing or the multi-client control plane exists in this
    /// port; the ACP runtime's `ACPLeaderRouter` covers message routing only.
    /// Naming the gap precisely is better than a leader that accepts nothing.
    static func leaderUnsupported(_ options: CLILeaderOptions) -> CLIApplicationError {
        _ = options
        return CLIApplicationError.failed(
            """
            `leader` is not available: this build has no leader IPC transport.
            Upstream brokers clients over a Unix socket at $OPENGROK_HOME/leader.sock \
            using length-prefixed JSON ClientMessage frames (Register/Acp/Control) plus \
            an advisory lock and connect-or-spawn; none of that framing is implemented here.
            Use `open-grok acp` (ACP over stdio) for a single-client agent connection.
            """
        )
    }
}
