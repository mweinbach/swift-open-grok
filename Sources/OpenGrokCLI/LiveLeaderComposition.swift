// LiveLeaderComposition.swift
//
// The `open-grok leader` route: one agent, shared two ways.
//
// Leader mode is not a third transport next to `acp` and `serve`. It is a
// *process role*, and it faces in two directions at once:
//
//   * **Inwards**, it is an IPC broker. Local clients — TUI, IDE, `-p` — dial a
//     Unix socket and share one agent, so switching windows does not restart
//     the model or lose the session (`leader/server.rs`).
//   * **Outwards**, it is a WebSocket *client*. It dials the grok.com relay and
//     receives prompts from there, which is how a leader on a devbox answers a
//     phone (`agent/relay.rs`, wired at `agent/app.rs:842-887`).
//
// The two are independent: a leader with no credentials still brokers local
// clients, and a bare leader with no local clients still answers the relay.
// That is exactly why `--relay-on-demand` exists — see `relayIsEager` below.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`):
//
//   * `crates/codegen/xai-grok-pager/src/app/cli.rs:362-380` — `LeaderArgs`:
//     `--no-exit-on-disconnect`, `--relay-on-demand`, `--no-auto-update`, plus
//     the flattened `--grok-ws-url` / `--grok-ws-origin`.
//   * `crates/codegen/xai-grok-shell/src/agent/app.rs:842-887` —
//     `spawn_leader_relay`: eager by default, demand-gated under the flag.
//   * `crates/codegen/xai-grok-shell/src/agent/relay.rs:64-81` — the relay is
//     built only for an x.ai OIDC session with a non-empty key.
//   * `crates/codegen/xai-grok-shell/src/leader/lock.rs` — socket path, suffix,
//     and the advisory lock.
//
// The launcher hook that routes here goes in `LiveComposition.swift`; see
// INTEGRATION-leader.md.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokComputerHubCore
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellSessionSupport
import OpenGrokWorkspace

public struct LiveLeaderAuthDependencies: Sendable {
    public var makeRefresher: @Sendable (
        GrokAuth,
        GrokComConfig
    ) -> (any TokenRefresher)?

    public init(
        makeRefresher: @escaping @Sendable (
            GrokAuth,
            GrokComConfig
        ) -> (any TokenRefresher)?
    ) {
        self.makeRefresher = makeRefresher
    }

    public static func production(
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) -> LiveLeaderAuthDependencies {
        LiveLeaderAuthDependencies { auth, config in
            guard auth.authMode == .oidc,
                  auth.isXAIAuth,
                  let issuer = auth.oidcIssuer ?? config.effectiveOIDC?.issuer,
                  let clientID = auth.oidcClientID ?? config.effectiveOIDC?.clientID,
                  let tokenEndpoint = URL(
                      string: "\(issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/oauth2/token"
                  )
            else {
                return nil
            }
            return OIDCTokenRefresher(
                tokenEndpoint: tokenEndpoint,
                clientID: clientID,
                issuer: issuer,
                transport: transport
            )
        }
    }
}

public enum LiveLeaderComposition {
    public static let routeName = "leader"

    /// Only `.leader`. `.serve` deliberately stays with `LiveServeComposition`.
    public static func handles(_ command: CLICommand) -> Bool {
        switch command {
        case .leader: return true
        default: return false
        }
    }

    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveACPServices = .unavailable,
        authDependencies: LiveLeaderAuthDependencies = .production()
    ) async throws -> CLIApplicationSession {
        guard case .leader(let options) = command else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        return try await leaderSession(
            options: options,
            context: context,
            services: services,
            authDependencies: authDependencies
        )
    }

    // MARK: - Endpoint resolution

    /// Where the relay lives, after flags, environment and defaults.
    ///
    /// Flags win over the environment because `--grok-ws-url` is how a spawned
    /// leader is told which relay its parent chose (`leader/mod.rs:1697-1698`);
    /// an inherited `GROK_WS_URL` must not override that.
    public static func resolveRelayEndpoint(
        options: CLILeaderOptions,
        environment: [String: String]
    ) -> (url: String, origin: String) {
        let config = GrokComConfig.default(environment: environment)
        return (
            options.grokWSURL ?? config.grokWSURL,
            options.grokWSOrigin ?? config.grokWSOrigin
        )
    }

    /// Whether the relay connects at startup or waits for a headless client.
    ///
    /// `app.rs:842-887`. Eager is the default and is not merely a preference: a
    /// bare leader (devbox, systemd) has no IPC clients at all, so a
    /// demand-gated relay would never connect and every remote prompt would
    /// fail with "No online agents".
    public static func relayIsEager(_ options: CLILeaderOptions) -> Bool {
        !options.relayOnDemand
    }

    /// Relay credentials, or `nil` when this login is not relay-eligible.
    ///
    /// `relay.rs:64-81` gates on an x.ai-issuer OIDC session with a non-empty
    /// key. API-key/BYOK, external-binary and legacy web logins are excluded —
    /// not as a policy choice here, but because the relay authenticates the
    /// bearer as a grok.com session and those tokens are not one.
    public static func relayAuthorization(
        auth: GrokAuth?,
        tokenType: TokenType,
        tokenHeader: String
    ) -> ACPRelayAuthorization? {
        guard let auth,
              tokenType == .oidcSession,
              auth.isXAIAuth,
              !auth.key.isEmpty
        else { return nil }
        return ACPRelayAuthorization(
            token: auth.key,
            userID: auth.userID,
            tokenHeader: tokenHeader
        )
    }

    // MARK: - Session

    static func leaderSession(
        options: CLILeaderOptions,
        context: CLIApplicationContext,
        services: LiveACPServices,
        authDependencies: LiveLeaderAuthDependencies
    ) async throws -> CLIApplicationSession {
        let environment = context.environment
        let cwd = try resolveWorkingDirectory(options.common.cwd)
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let relay = resolveRelayEndpoint(options: options, environment: environment)

        if options.noAutoUpdate {
            // Upstream disables a periodic update check that this port does not
            // run at all, so the flag is a no-op rather than a lie.
            context.streams.err(
                "open-grok: `leader --no-auto-update` is accepted for compatibility; "
                    + "this build has no leader auto-update check to disable.\n"
            )
        }
        if options.noExitOnDisconnect {
            // Honoured trivially: this leader never exits on client disconnect,
            // so the flag names the behaviour it already has.
            context.streams.err(
                "open-grok: `leader --no-exit-on-disconnect` is the only supported behaviour here; "
                    + "this leader always outlives its clients.\n"
            )
        }

        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: relay.url,
            environment: environment,
            socketOverride: options.common.leaderSocket
        )

        // The lock is taken *before* the socket is bound, because binding
        // removes a stale socket file and only the lock proves that file is
        // stale rather than a live leader's.
        let lock = ACPLeaderLock(lockPath: paths.lock, socketPath: paths.socket)
        do {
            try lock.acquire()
        } catch let error as ACPLeaderLockError {
            throw CLIApplicationError.failed(leaderAlreadyRunningMessage(error, socket: paths.socket))
        } catch {
            throw CLIApplicationError.failed(
                "could not take the leader lock at \(paths.lock.path): \(error)"
            )
        }

        let promptDriver: LiveACPPromptDriver
        do {
            promptDriver = try await services.makePromptDriver(
                LiveACPLaunch(
                    workingDirectory: cwd,
                    openGrokHome: home,
                    environment: environment,
                    streams: context.streams,
                    options: CLIExecutionOptions(mode: .acp, common: options.common)
                )
            )
        } catch {
            lock.release()
            throw error
        }

        // One store, one runtime, for the life of the process: that is the
        // whole point of a leader. Every IPC client and the relay all address
        // the same sessions.
        let store = InMemoryACPSessionStore()
        let workspace = LocalOpenGrokShellWorkspace(root: cwd, openGrokHome: home)
        let runtime = ACPAgentRuntime(
            store: store,
            promptDriver: promptDriver,
            workspaceBoundary: workspace.acpBoundary
        )

        let authConfig = GrokComConfig.default(environment: environment)
        let manager = AuthManager(
            grokHome: home,
            config: authConfig,
            environment: environment
        )
        if let auth = await manager.currentOrExpired(),
           let refresher = authDependencies.makeRefresher(auth, authConfig) {
            await manager.configureRefresher(refresher)
        }
        let hubAuth = LeaderComputerHubAuthProvider(manager: manager)
        let sharedPermissionPipeline = workspace.permissionPipeline
        let hubConnector: ACPWorkspaceExposureConnector = { [hubAuth, sharedPermissionPipeline, environment] hubURL, workspaceCwd in
            let mediation = HubMediation.mediated(
                LivePermissionHubMediator(pipeline: sharedPermissionPipeline)
            )
            let mcpConnections = MCPSessionConnections()
            let mcpClients = await LiveMCPComposition.connectConfiguredClientsForHub(
                cwd: workspaceCwd,
                environment: environment,
                connections: mcpConnections
            )
            return try await ComputerHubWorkspaceExposure.connect(
                hubURL: hubURL,
                cwd: workspaceCwd,
                auth: hubAuth,
                mediation: mediation,
                mcpClients: mcpClients,
                mcpConnections: mcpClients.isEmpty ? nil : mcpConnections
            )
        }

        let log: @Sendable (String) -> Void = { message in
            context.streams.err("open-grok: \(message)\n")
        }

        let ipc = ACPLeaderIPCHost(
            runtime: runtime,
            configuration: productionIPCConfiguration(
                paths: paths,
                relayURL: relay.url,
                environment: environment,
                productionExposureConnector: hubConnector
            ),
            log: log
        )
        let listener = ACPLeaderSocketListener(path: paths.socket)
        let channels: AsyncStream<any WebSocketByteChannel>
        do {
            channels = try await listener.start()
        } catch {
            lock.release()
            await promptDriver.shutdown()
            throw CLIApplicationError.failed(
                "could not bind the leader socket at \(paths.socket.path): \(error)"
            )
        }

        // Relay credentials are read once at startup, matching upstream: the
        // `ConfigUpdate::Auth` handler there never re-arms a relay either
        // (`app.rs:1432-1442` promises it, `app.rs:1557-1582` does not do it),
        // so a leader that starts logged-out stays relay-less until restart.
        let auth = await manager.current()
        let authorization = relayAuthorization(
            auth: auth,
            tokenType: await manager.tokenType(),
            tokenHeader: authConfig.tokenHeader
        )

        let authRecovery: ACPRelayClient.AuthRecovery?
        if authorization == nil {
            authRecovery = nil
        } else {
            authRecovery = { _ in
                switch await manager.recoverUnauthorized() {
                case .recovered:
                    guard let refreshedAuth = await manager.current() else {
                        return .terminalFailure
                    }
                    let refreshedType = await manager.tokenType()
                    guard let refreshedAuthorization = Self.relayAuthorization(
                        auth: refreshedAuth,
                        tokenType: refreshedType,
                        tokenHeader: authConfig.tokenHeader
                    ) else {
                        return .terminalFailure
                    }
                    return .recovered(refreshedAuthorization)
                case .retryableFailure:
                    return .retryableFailure
                case .terminalFailure:
                    return .terminalFailure
                }
            }
        }

        var relayClient: ACPRelayClient?
        var relayNote: String
        if authorization == nil {
            relayNote =
                "not started: no grok.com session token (BYOK / local-only leader). "
                + "Run `open-grok login` and restart to enable remote prompts."
        } else if let url = try? WebSocketURL.parse(relay.url) {
            relayClient = ACPRelayClient(
                configuration: ACPRelayConfiguration(
                    url: url,
                    origin: relay.origin,
                    authorization: authorization,
                    clientMode: "headless"
                ),
                makeRuntime: { runtime },
                authRecovery: authRecovery,
                log: log
            )
            relayNote = relayIsEager(options) ? "connecting" : "waiting for a headless client"
        } else {
            relayNote = "not started: `\(relay.url)` is not a valid ws:// or wss:// URL"
        }

        context.streams.err(
            startupBanner(socket: paths.socket, relayURL: relay.url, relayState: relayNote)
        )

        let relayHandle = RelayHandle()
        let ipcHandle = ipc
        let eager = relayIsEager(options)
        // Rebound to a `let` so the escaping session closures capture a value
        // rather than the mutable slot the relay decision was built up in.
        let relayRunner = relayClient

        return CLIApplicationSession(
            waitForExit: {
                await withTaskGroup(of: Void.self) { group in
                    if let relayRunner {
                        group.addTask {
                            if !eager {
                                // `server.rs:1650-1665` — only a *headless*
                                // registration arms the relay. A TUI attaching
                                // locally must not, or an auto-spawned leader
                                // would open a remote leg nobody asked for.
                                await waitForHeadlessClient(on: ipcHandle)
                            }
                            await relayHandle.adopt(relayRunner)
                            await relayRunner.run()
                        }
                    }
                    group.addTask {
                        for await channel in channels {
                            Task { await ipcHandle.serve(channel: channel) }
                        }
                    }
                    await group.waitForAll()
                }
            },
            shutdown: {
                await relayHandle.stop()
                await ipcHandle.stop()
                await listener.stop()
                await promptDriver.shutdown()
                lock.release()
            }
        )
    }

    /// Build the production leader configuration from one resolved startup
    /// snapshot. Keeping this seam together prevents registration metadata and
    /// `get_leader_info` from silently falling back to library defaults.
    static func productionIPCConfiguration(
        paths: (socket: URL, lock: URL),
        relayURL: String,
        environment: [String: String],
        productionExposureConnector: @escaping ACPWorkspaceExposureConnector
    ) -> ACPLeaderIPCConfiguration {
        let version = OpenGrokCLIVersion.installed(environment: environment)
        let metadata = ACPLeaderControlMetadata(
            socketPath: paths.socket.path,
            lockPath: paths.lock.path,
            wsURLSuffix: ACPLeaderSocketPaths.suffix(forRelayURL: relayURL),
            binaryVersion: version
        )
        let controlPlane = ACPLeaderControlPlane(
            metadata: metadata,
            defaultHubURL: ACPLeaderControlPlane.productionComputerHubURL,
            connector: productionExposureConnector
        )
        return ACPLeaderIPCConfiguration(
            binaryVersion: version,
            controlPlane: controlPlane
        )
    }

    /// Poll for the first headless registration.
    ///
    /// Polling rather than a signal because `ACPLeaderIPCHost` deliberately has
    /// no observer seam: the relay is the only consumer of this bit, and a
    /// one-second granularity on a connection that then takes a network
    /// round-trip is not worth the extra state.
    static func waitForHeadlessClient(on host: ACPLeaderIPCHost) async {
        while !Task.isCancelled {
            if await host.hasHeadlessClient() { return }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Holds the relay so shutdown can stop it without racing its startup.
    actor RelayHandle {
        private var client: ACPRelayClient?
        private var stopped = false

        func adopt(_ client: ACPRelayClient) async {
            guard !stopped else {
                await client.stop()
                return
            }
            self.client = client
        }

        func stop() async {
            stopped = true
            await client?.stop()
            client = nil
        }
    }

    // MARK: - Messages

    static func leaderAlreadyRunningMessage(_ error: ACPLeaderLockError, socket: URL) -> String {
        switch error {
        case .held(let pid, let path):
            let owner = pid.map { "process \($0)" } ?? "another process"
            return """
                a leader is already running for this endpoint (\(owner) holds \(path)).
                Normal launches using `--leader` use connect-or-spawn to attach to \(socket.path) instead of starting a second one.
                Stop the existing leader first only when you intend to replace its shared runtime.
                """
        case .cannotOpen(let path, let reason):
            return "could not open the leader lock at \(path): \(reason)"
        case .unsupportedPlatform(let path):
            return """
                leader mode is unavailable on Windows: the leader lock at \(path) has no supported locking backend.
                No leader was started and no endpoint was created; Windows support requires both a native lock and named-pipe transport.
                """
        }
    }

    static func startupBanner(socket: URL, relayURL: String, relayState: String) -> String {
        """

           Open Grok leader starting...

           Socket:   \(socket.path)
           Relay:    \(relayURL)
           Status:   \(relayState)


        """
    }

    private static func resolveWorkingDirectory(_ path: String?) throws -> URL {
        guard let path else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CLIApplicationError.failed("`--cwd \(path)` is not a directory")
        }
        return url
    }
}
