// LiveServeComposition.swift
//
// The `open-grok serve` route — ACP over a WebSocket — and the honest
// disposition of `leader`.
//
// `serve` is the same agent `open-grok acp` runs, on a different carrier. The
// protocol layer is `ACPAgentRuntime`, the framing is one JSON-RPC object per
// WebSocket text frame (`ACPWebSocketConnectionTransport`), and the socket is
// `WebSocketServer`. This file is the CLI seam: parse the bind address,
// resolve the secret, print the banner, own the lifetime.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`):
//
//   * `crates/codegen/xai-grok-pager/src/app/cli.rs:334-361` — `ServeArgs`:
//     `--bind` defaults to `127.0.0.1:2419`, `--secret` falls back to the
//     `GROK_AGENT_SECRET` environment variable and then to a generated
//     12-character key. The secret is never optional at the server.
//   * `crates/codegen/xai-grok-pager-bin/src/main.rs:89-102` — the startup
//     banner, printed to stderr.
//   * `crates/codegen/xai-grok-pager-bin/src/main.rs:1251-1259` — the wiring
//     from parsed args to `run_agent_server`.
//   * `crates/codegen/xai-grok-shell/src/agent/server.rs` — the server itself.
//
// The launcher hook that routes here belongs in `LiveComposition.swift`, which
// the integration slice owns; see INTEGRATION-serve.md for the diff.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellSessionSupport

public enum LiveServeComposition {
    public static let routeName = "serve"

    /// The environment variable upstream reads for the secret
    /// (`cli.rs:340`, `#[arg(long, env = "GROK_AGENT_SECRET")]`). Kept
    /// verbatim, the same way this port keeps `GROK_OIDC_*` and
    /// `GROK_DEPLOYMENT_KEY`.
    public static let secretEnvironmentVariable = "GROK_AGENT_SECRET"

    public static func handles(_ command: CLICommand) -> Bool {
        switch command {
        case .serve, .leader: return true
        default: return false
        }
    }

    /// Launcher entry point.
    ///
    /// Long-lived like the ACP route: the returned session's `waitForExit` is
    /// the accept loop, so the process stays up until it is cancelled.
    ///
    /// Must be consulted *before* `LiveACPComposition`, whose `handles` still
    /// claims `.serve`/`.leader` from when neither had an implementation.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveACPServices = .unavailable
    ) async throws -> CLIApplicationSession {
        switch command {
        case .serve(let options):
            return try await serveSession(options: options, context: context, services: services)
        case .leader(let options):
            throw leaderUnsupported(options)
        default:
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
    }

    // MARK: - serve

    static func serveSession(
        options: CLIServeOptions,
        context: CLIApplicationContext,
        services: LiveACPServices
    ) async throws -> CLIApplicationSession {
        let address = try parseBind(options.bind)
        let secret = resolveSecret(options: options, environment: context.environment)
        let cwd = try resolveWorkingDirectory(options.common.cwd)
        let home = OpenGrokHomeResolver.resolve(environment: context.environment)

        if options.remote != nil {
            // Upstream parses `--remote` on `serve` but never reads it —
            // `main.rs:1252-1259` builds `ServerConfig` from `bind` and
            // `secret` only. Saying so beats silently doing nothing.
            context.streams.err(
                "open-grok: `serve --remote` is accepted for compatibility but has no effect; "
                    + "serve always runs the local agent.\n"
            )
        }
        if !isLoopback(address.host) {
            // Not blocked — upstream allows `--bind 0.0.0.0:9000` and the
            // secret is mandatory either way — but an operator who typed this
            // by accident should find out now.
            context.streams.err(
                "open-grok: warning: binding \(address.host) exposes the agent beyond this machine; "
                    + "the connection is token-authenticated but not encrypted.\n"
            )
        }

        // Built once and shared by every connection. This is what upstream's
        // persistent `MvpAgent` gives it (`server.rs:293-302`): reconnecting
        // must not rebuild the sampler stack or re-read credentials. The
        // full components — prompt driver AND extension router — are built
        // together so the ws:// carrier serves the same ext-method surface
        // stdio serves (upstream's server bridges into the same agent, so
        // `open-grok/*` and `x.ai/*` methods work identically on both).
        let launchComponents = try await services.makeComponents(
            LiveACPLaunch(
                workingDirectory: cwd,
                openGrokHome: home,
                environment: context.environment,
                streams: context.streams,
                options: CLIExecutionOptions(mode: .acp, common: options.common)
            )
        )
        let promptDriver = launchComponents.promptDriver

        // Shared across reconnects so a session created on one connection is
        // still addressable on the next. `DefaultOpenGrokShellACPRuntimeFactory`
        // (`OpenGrokShell.swift:486-499`) is not reused here for exactly that
        // reason — it mints a fresh store per call, which is right for stdio
        // (one connection, one process) and wrong for serve. The runtime
        // construction below is otherwise that factory's body verbatim.
        let store = InMemoryACPSessionStore()
        let workspace = LocalOpenGrokShellWorkspace(root: cwd, openGrokHome: home)
        let boundary = workspace.acpBoundary

        let host = ACPServeHost(
            configuration: ACPServeConfiguration(
                host: address.host,
                port: address.port,
                secret: secret.value
            ),
            makeRuntime: {
                let runtime = ACPAgentRuntime(
                    store: store,
                    promptDriver: promptDriver,
                    workspaceBoundary: boundary,
                    extensionHandler: launchComponents.extensionHandler,
                    extensionNotifications: launchComponents.extensionNotifications
                )
                // Re-attached per accepted connection: the serve host mints a
                // runtime per client, and the gateway's emitters must follow
                // the runtime whose sink is the LIVE socket — an emitter
                // pointed at a closed connection's runtime broadcasts into
                // nothing, exactly the reconnect gap upstream's persistent
                // gateway relay avoids by repointing (server.rs:342).
                if let gateway = launchComponents.notificationGateway {
                    await gateway.attach(runtime)
                }
                // Re-point the reverse permission prompter at THIS connection's
                // runtime so `session/request_permission` rides the live socket
                // after reconnect (same attach discipline as the gateway).
                if let permissionPrompter = launchComponents.permissionPrompter {
                    await permissionPrompter.attach(
                        client: ACPRuntimePermissionClient(runtime)
                    )
                }
                return runtime
            },
            log: { message in context.streams.err("open-grok: \(message)\n") }
        )

        let endpoint = try await startHost(host, requested: address)
        context.streams.err(startupBanner(endpoint: endpoint, secret: secret.value))

        return CLIApplicationSession(
            waitForExit: {
                // The accept loop ends when `stop()` closes the listener,
                // which is what the shutdown hook below does on a signal.
                await host.run()
            },
            shutdown: {
                await host.stop()
                await promptDriver.shutdown()
            }
        )
    }

    private static func startHost(
        _ host: ACPServeHost,
        requested: (host: String, port: UInt16)
    ) async throws -> ACPServeEndpoint {
        do {
            return try await host.start()
        } catch let error as WebSocketServerError {
            throw CLIApplicationError.failed(
                "could not start the agent server on \(requested.host):\(requested.port): \(error)"
            )
        }
    }

    // MARK: - secret

    public struct ResolvedSecret: Sendable, Equatable {
        public var value: String
        /// How the secret was obtained, which decides whether the operator
        /// needs to be told what it is.
        public var source: Source

        public enum Source: Sendable, Equatable {
            case flag
            case environment
            case generated
        }
    }

    /// `--secret`, else `GROK_AGENT_SECRET`, else a generated key.
    ///
    /// Upstream's `ServeArgs::get_secret` (`cli.rs:355-361`) has exactly this
    /// precedence, and there is no way to run the server without one. That is
    /// deliberate here too: the port must never open an unauthenticated
    /// network surface upstream does not open.
    public static func resolveSecret(
        options: CLIServeOptions,
        environment: [String: String],
        generate: () -> String = { generateKey() }
    ) -> ResolvedSecret {
        if let secret = options.secret, !secret.isEmpty {
            return ResolvedSecret(value: secret, source: .flag)
        }
        if let secret = environment[secretEnvironmentVariable], !secret.isEmpty {
            return ResolvedSecret(value: secret, source: .environment)
        }
        return ResolvedSecret(value: generate(), source: .generated)
    }

    /// Upstream's `generate_random_key(12)` (`cli.rs:364-367`): a v4 UUID with
    /// its dashes removed, truncated to 12 characters.
    public static func generateKey(length: Int = 12) -> String {
        var raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Upstream cycles the characters if more are asked for than a UUID
        // provides; 12 never reaches that, but matching it costs nothing.
        while raw.count < length { raw += raw }
        return String(raw.prefix(length))
    }

    // MARK: - bind address

    public enum BindParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case missingPort(String)
        case invalidPort(String)
        case missingHost(String)

        public var description: String {
            switch self {
            case .missingPort(let value):
                return "--bind \(value) has no port; expected host:port, e.g. 127.0.0.1:2419"
            case .invalidPort(let value):
                return "--bind port '\(value)' is not a number in 0...65535"
            case .missingHost(let value):
                return "--bind \(value) has no host; expected host:port, e.g. 127.0.0.1:2419"
            }
        }
    }

    /// Split `host:port`, with `[::1]:2419` handled for IPv6 literals.
    public static func parseBind(_ value: String) throws -> (host: String, port: UInt16) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let hostPart: Substring
        let portPart: Substring
        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]"),
                  trimmed.index(after: closing) < trimmed.endIndex,
                  trimmed[trimmed.index(after: closing)] == ":"
            else { throw CLIApplicationError.failed(BindParseError.missingPort(value).description) }
            hostPart = trimmed[trimmed.index(after: trimmed.startIndex)..<closing]
            portPart = trimmed[trimmed.index(closing, offsetBy: 2)...]
        } else {
            guard let colon = trimmed.lastIndex(of: ":") else {
                throw CLIApplicationError.failed(BindParseError.missingPort(value).description)
            }
            hostPart = trimmed[trimmed.startIndex..<colon]
            portPart = trimmed[trimmed.index(after: colon)...]
        }
        guard !hostPart.isEmpty else {
            throw CLIApplicationError.failed(BindParseError.missingHost(value).description)
        }
        guard let port = UInt16(portPart) else {
            throw CLIApplicationError.failed(BindParseError.invalidPort(String(portPart)).description)
        }
        return (String(hostPart), port)
    }

    static func isLoopback(_ host: String) -> Bool {
        switch host.lowercased() {
        case "127.0.0.1", "localhost", "::1", "0:0:0:0:0:0:0:1":
            return true
        default:
            // The whole 127.0.0.0/8 block is loopback.
            return host.hasPrefix("127.")
        }
    }

    // MARK: - banner

    /// Upstream's `print_serve_startup_info` (`main.rs:89-102`), which writes
    /// to stderr so stdout stays clean.
    public static func startupBanner(endpoint: ACPServeEndpoint, secret: String) -> String {
        """

           Open Grok agent server starting...

           Address:  \(endpoint.host):\(endpoint.port)
           Secret:   \(secret)

           WebSocket URL: \(endpoint.url(withSecret: secret))


        """
    }

    // MARK: - working directory

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

    // MARK: - leader

    /// Why `leader` still cannot run, now that `serve` can.
    ///
    /// `serve` and `leader` look adjacent in the CLI but are different
    /// protocols, and building the WebSocket server did not move `leader`
    /// forward. Upstream `agent leader` is a shared-process broker over a
    /// **Unix domain socket** at `{grok_home}/leader{suffix}.sock`
    /// (`crates/codegen/xai-grok-shell/src/leader/lock.rs:12-58`,
    /// `leader/transport.rs:10-12`), framed as a 4-byte big-endian length
    /// prefix plus a JSON `ClientMessage` — `Register`/`Acp`/`Control`/`Ping`/
    /// `Disconnect`, capped at 64 MB (`leader/protocol.rs:8,21-72,200-330`) —
    /// with an advisory lock file and a connect-or-spawn race so the first
    /// client starts the leader and the rest attach (`leader/mod.rs:1443`).
    /// Per-client `ClientCapabilities` are injected as `_meta` into that
    /// client's `session/new`, which is how several clients share one leader
    /// with independently scoped behaviour.
    ///
    /// What exists here: `ACPAgentRuntime` (the agent), `ACPLeaderRouter`
    /// (message routing only), and now a WebSocket accept loop. What does not:
    /// the `ClientMessage` envelope, the multi-client control plane, the
    /// advisory lock, and connect-or-spawn. Naming those precisely is more
    /// useful than a leader that accepts a connection and then cannot register
    /// a client.
    static func leaderUnsupported(_ options: CLILeaderOptions) -> CLIApplicationError {
        _ = options
        return CLIApplicationError.failed(
            """
            `leader` is not available: this build has no leader IPC transport.
            Upstream brokers several clients through one agent over a Unix socket at \
            $OPENGROK_HOME/leader.sock, framed as a 4-byte big-endian length prefix plus a \
            JSON ClientMessage (Register/Acp/Control/Ping/Disconnect), with an advisory lock \
            and a connect-or-spawn race; none of that envelope or control plane is implemented \
            here. `serve` is a different protocol and does not substitute for it.
            For one client at a time, use `open-grok serve` (ACP over WebSocket) or \
            `open-grok acp` (ACP over stdio).
            """
        )
    }
}
