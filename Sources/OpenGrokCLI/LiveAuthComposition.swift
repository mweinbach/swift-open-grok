// LiveAuthComposition.swift
//
// Live `login` / `logout` behavior for the Open Grok CLI.
//
// Routing contract (ported from the Rust shell auth commands):
//   * bare `login` / `logout`        -> the xAI store (`auth.json`)
//   * `login --codex` / `logout --codex` -> the ISOLATED Codex OAuth store
//     (`codex-auth.json`) under `OPENGROK_HOME`
//   * `logout --all`                 -> both stores, cleared independently
//
// The two stores never read each other: a Codex-only user can sign in and run
// headless without ever holding xAI credentials, and clearing one store leaves
// the other byte-for-byte untouched. The legacy `~/.grok` path is never used.
//
// This file is self-contained: it does not import or modify `LiveComposition`.
// The launcher hook that routes `login`/`logout` here lives in
// `LiveComposition.swift` and is owned by the integration slice.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Injectable services

/// Side-effecting dependencies of the auth commands. Tests inject fakes so no
/// browser, socket, terminal, or network is touched.
public struct LiveAuthServices: Sendable {
    public typealias CodexLoginFlow = @Sendable (
        _ authFile: URL,
        _ endpoints: CodexEndpoints,
        _ transport: any HTTPTransport,
        _ openBrowser: (@Sendable (URL) -> Void)?
    ) async throws -> CodexCredentials

    /// Transport used for OAuth exchange, refresh, and best-effort revoke.
    public var makeTransport: @Sendable () -> any HTTPTransport
    /// Browser + local-callback OAuth flow.
    public var codexBrowserLogin: CodexLoginFlow
    /// Device-code fallback flow.
    public var codexDeviceLogin: CodexLoginFlow
    /// Best-effort browser opener. `nil` disables opening.
    public var openBrowser: (@Sendable (URL) -> Void)?
    /// Reads one secret line from the controlling terminal.
    public var readSecretLine: @Sendable () -> String?
    /// Whether stdin is a terminal that can be prompted.
    public var isInteractive: @Sendable () -> Bool

    public init(
        makeTransport: @escaping @Sendable () -> any HTTPTransport,
        codexBrowserLogin: @escaping CodexLoginFlow,
        codexDeviceLogin: @escaping CodexLoginFlow,
        openBrowser: (@Sendable (URL) -> Void)?,
        readSecretLine: @escaping @Sendable () -> String?,
        isInteractive: @escaping @Sendable () -> Bool
    ) {
        self.makeTransport = makeTransport
        self.codexBrowserLogin = codexBrowserLogin
        self.codexDeviceLogin = codexDeviceLogin
        self.openBrowser = openBrowser
        self.readSecretLine = readSecretLine
        self.isInteractive = isInteractive
    }

    public static let production = LiveAuthServices(
        makeTransport: { URLSessionHTTPTransport() },
        codexBrowserLogin: { authFile, endpoints, transport, openBrowser in
            try await loginCodexBrowser(
                authFile: authFile,
                endpoints: endpoints,
                transport: transport,
                announce: false,
                openBrowser: openBrowser
            )
        },
        codexDeviceLogin: { authFile, endpoints, transport, openBrowser in
            try await loginCodexDevice(
                authFile: authFile,
                endpoints: endpoints,
                transport: transport,
                openBrowser: openBrowser
            )
        },
        openBrowser: { url in LiveAuthComposition.openInSystemBrowser(url) },
        readSecretLine: { readLine(strippingNewline: true) },
        isInteractive: { isatty(0) == 1 }
    )
}

// MARK: - Status model

/// Authentication status of one credential store. Never carries a secret.
public struct LiveAuthProviderStatus: Sendable, Equatable, Encodable {
    public var authenticated: Bool
    /// Where the credential came from (`environment`, `api_key`, `session`, `oauth`).
    public var source: String?
    /// Non-secret account label (email, user id, or account id).
    public var account: String?
    /// Plan/tier label when the provider reports one.
    public var plan: String?

    public init(
        authenticated: Bool,
        source: String? = nil,
        account: String? = nil,
        plan: String? = nil
    ) {
        self.authenticated = authenticated
        self.source = source
        self.account = account
        self.plan = plan
    }

    public static let unauthenticated = LiveAuthProviderStatus(authenticated: false)
}

/// Combined status of both isolated stores.
public struct LiveAuthStatus: Sendable, Equatable, Encodable {
    public var xai: LiveAuthProviderStatus
    public var codex: LiveAuthProviderStatus

    public init(xai: LiveAuthProviderStatus, codex: LiveAuthProviderStatus) {
        self.xai = xai
        self.codex = codex
    }
}

// MARK: - Composition

public enum LiveAuthComposition {
    /// Utility routes this composition owns.
    public static let routeNames: Set<String> = ["login", "logout"]

    /// Whether the launcher should delegate `command` here.
    public static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return routeNames.contains(options.name)
    }

    /// Launcher entry point. Runs the command to completion, then hands back an
    /// already-finished session so the generic run loop can shut down.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveAuthServices = .production
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, routeNames.contains(options.name) else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try await run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            services: services
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveAuthServices = .production
    ) async throws {
        switch options.name {
        case "login":
            try await runLogin(
                options: options,
                environment: environment,
                streams: streams,
                services: services
            )
        case "logout":
            try await runLogout(
                options: options,
                environment: environment,
                streams: streams,
                services: services
            )
        default:
            throw CLIApplicationError.unsupported(route: options.name)
        }
    }

    // MARK: - login

    public static func runLogin(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveAuthServices = .production
    ) async throws {
        switch try target(for: options) {
        case .all:
            throw CLIApplicationError.failed(
                "`login --all` is not supported; run `open-grok login` and `open-grok login --codex` separately"
            )
        case .codex:
            try await loginCodex(
                options: options,
                environment: environment,
                streams: streams,
                services: services
            )
        case .xai:
            try await loginXAI(
                options: options,
                environment: environment,
                streams: streams,
                services: services
            )
        }
        try emitStatus(options: options, environment: environment, streams: streams)
    }

    private static func loginXAI(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveAuthServices
    ) async throws {
        let config = GrokComConfig.default(environment: environment)
        if config.apiKeyAuthDisabled(environment: environment) {
            throw CLIApplicationError.failed(AuthError.apiKeyAuthDisabled.description)
        }

        guard let apiKey = try resolveXAIAPIKey(
            options: options,
            environment: environment,
            streams: streams,
            services: services
        ) else {
            throw CLIApplicationError.failed(
                "no xAI API key supplied; pass it as an argument, set XAI_API_KEY, or run `open-grok login` on a terminal"
            )
        }

        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let manager = AuthManager(grokHome: home, config: config, environment: environment)
        do {
            try await loginXAIWithAPIKey(manager: manager, apiKey: apiKey)
        } catch {
            throw CLIApplicationError.failed(describe(error))
        }
        if !options.json {
            streams.out("Signed in to xAI with an API key.\n")
        }
    }

    /// Positional argument, then environment, then an interactive prompt.
    private static func resolveXAIAPIKey(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveAuthServices
    ) throws -> String? {
        if let positional = options.values.first(where: { !$0.isEmpty && $0 != "xai" }) {
            return positional.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fromEnvironment = xaiAPIKeyFromEnvironment(environment) {
            return fromEnvironment
        }
        guard services.isInteractive() else { return nil }
        streams.out("Paste your xAI API key (input is not echoed by the terminal): ")
        guard let entered = services.readSecretLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !entered.isEmpty
        else {
            return nil
        }
        streams.out("\n")
        return entered
    }

    private static func loginCodex(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveAuthServices
    ) async throws {
        let authFile = OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        let endpoints = CodexEndpoints.fromEnvironment(environment)
        let transport = services.makeTransport()
        let preferDevice = options.options["--device-code"] != nil
            || options.options["--device-auth"] != nil

        let announce: @Sendable (URL) -> Void = { url in
            streams.out("Open this URL to finish signing in to Codex:\n  \(url.absoluteString)\n")
            services.openBrowser?(url)
        }

        let credentials: CodexCredentials
        if preferDevice {
            credentials = try await runCodexFlow(
                services.codexDeviceLogin,
                authFile: authFile,
                endpoints: endpoints,
                transport: transport,
                openBrowser: announce
            )
        } else {
            do {
                credentials = try await runCodexFlow(
                    services.codexBrowserLogin,
                    authFile: authFile,
                    endpoints: endpoints,
                    transport: transport,
                    openBrowser: announce
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                streams.err(
                    "open-grok: browser sign-in failed (\(describe(error))); falling back to the device code flow.\n"
                )
                credentials = try await runCodexFlow(
                    services.codexDeviceLogin,
                    authFile: authFile,
                    endpoints: endpoints,
                    transport: transport,
                    openBrowser: announce
                )
            }
        }

        if !options.json {
            let account = credentials.email ?? credentials.accountID ?? "your ChatGPT account"
            streams.out("Signed in to Codex as \(account).\n")
        }
    }

    private static func runCodexFlow(
        _ flow: LiveAuthServices.CodexLoginFlow,
        authFile: URL,
        endpoints: CodexEndpoints,
        transport: any HTTPTransport,
        openBrowser: @escaping @Sendable (URL) -> Void
    ) async throws -> CodexCredentials {
        try await flow(authFile, endpoints, transport, openBrowser)
    }

    // MARK: - logout

    public static func runLogout(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveAuthServices = .production
    ) async throws {
        let accountTarget = try target(for: options)
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let codexFile = OpenGrokAuthPaths.codexAuthFileURL(environment: environment)

        // Each store is addressed only when the target names it, so a
        // single-store logout can never touch the other file.
        let manager: AuthManager? = accountTarget == .codex
            ? nil
            : AuthManager(
                grokHome: home,
                config: GrokComConfig.default(environment: environment),
                environment: environment
            )
        let codexAuthFile: URL? = accountTarget == .xai ? nil : codexFile
        let codexTransport: (any HTTPTransport)? = codexAuthFile == nil
            ? nil
            : services.makeTransport()

        let result: MultiLogoutResult
        do {
            result = try await logout(
                target: accountTarget,
                manager: manager,
                codexAuthFile: codexAuthFile,
                codexTransport: codexTransport,
                codexEndpoints: CodexEndpoints.fromEnvironment(environment)
            )
        } catch {
            throw CLIApplicationError.failed(describe(error))
        }

        if !options.json {
            if let xai = result.xai {
                if xai.wasLoggedIn {
                    let who = xai.email.map { " (\($0))" } ?? ""
                    streams.out("Signed out of xAI\(who).\n")
                } else {
                    streams.out("No xAI credentials were stored.\n")
                }
                if xai.apiKeyStillSet {
                    streams.out(
                        "XAI_API_KEY is still set in your environment and will continue to authenticate requests.\n"
                    )
                }
            }
            if let removed = result.codexRemoved {
                streams.out(
                    removed
                        ? "Signed out of Codex; codex-auth.json removed.\n"
                        : "No Codex credentials were stored.\n"
                )
            }
        }
        try emitStatus(options: options, environment: environment, streams: streams)
    }

    // MARK: - Status

    /// Read-only status of both stores. No network, no refresh, no secrets.
    public static func status(environment: [String: String]) -> LiveAuthStatus {
        LiveAuthStatus(
            xai: xaiStatus(environment: environment),
            codex: codexStatus(environment: environment)
        )
    }

    public static func statusLines(environment: [String: String]) -> [String] {
        let current = status(environment: environment)
        return [
            line(provider: "xAI", status: current.xai, hint: "open-grok login"),
            line(provider: "Codex", status: current.codex, hint: "open-grok login --codex"),
        ]
    }

    private static func line(
        provider: String,
        status: LiveAuthProviderStatus,
        hint: String
    ) -> String {
        guard status.authenticated else {
            return "\(provider): not authenticated (run `\(hint)`)"
        }
        var detail: [String] = []
        if let source = status.source { detail.append(source) }
        if let account = status.account { detail.append(account) }
        if let plan = status.plan { detail.append(plan) }
        let suffix = detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))"
        return "\(provider): authenticated\(suffix)"
    }

    private static func xaiStatus(environment: [String: String]) -> LiveAuthProviderStatus {
        if deploymentKeyFromEnvironment(environment) != nil {
            return LiveAuthProviderStatus(authenticated: true, source: "GROK_DEPLOYMENT_KEY")
        }
        if xaiAPIKeyFromEnvironment(environment) != nil {
            return LiveAuthProviderStatus(authenticated: true, source: "environment")
        }
        let path = OpenGrokAuthPaths.authFileURL(environment: environment)
        guard let store = try? readAuthJSONOrEmpty(at: path) else {
            return .unauthenticated
        }
        let scope = GrokComConfig.default(environment: environment).authScope
        if let session = lookupAuth(store, scope: scope) {
            return LiveAuthProviderStatus(
                authenticated: true,
                source: session.authMode == .apiKey ? "api_key" : "session",
                account: session.email ?? (session.userID.isEmpty ? nil : session.userID)
            )
        }
        if store[apiKeyScope] != nil {
            return LiveAuthProviderStatus(authenticated: true, source: "api_key")
        }
        return .unauthenticated
    }

    private static func codexStatus(environment: [String: String]) -> LiveAuthProviderStatus {
        let path = OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        guard let credentials = try? loadCodexCredentials(at: path) else {
            return .unauthenticated
        }
        return LiveAuthProviderStatus(
            authenticated: true,
            source: "oauth",
            account: credentials.email ?? credentials.accountID,
            plan: credentials.planType
        )
    }

    private static func emitStatus(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams
    ) throws {
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                let data = try encoder.encode(status(environment: environment))
                streams.out(String(decoding: data, as: UTF8.self) + "\n")
            } catch {
                throw CLIApplicationError.failed("failed to encode auth status: \(error)")
            }
            return
        }
        for entry in statusLines(environment: environment) {
            streams.out(entry + "\n")
        }
    }

    // MARK: - Target selection

    /// `--codex` selects the Codex store, `--all` both, otherwise xAI.
    ///
    /// The positional spellings (`logout codex`, `logout all`) are accepted so
    /// the behavior is reachable before the shared parser learns `--all`.
    static func target(for options: CLIUtilityOptions) throws -> AuthAccountTarget {
        let values = Set(options.values.map { $0.lowercased() })
        let wantsAll = options.options["--all"] != nil || values.contains("all")
        let wantsCodex = options.options["--codex"] != nil || values.contains("codex")
        if wantsAll && wantsCodex {
            throw CLIApplicationError.failed("options --all and --codex cannot be used together")
        }
        if wantsAll { return .all }
        if wantsCodex { return .codex }
        return .xai
    }

    // MARK: - Misc

    static func describe(_ error: Error) -> String {
        if let convertible = error as? any CustomStringConvertible {
            return convertible.description
        }
        return String(describing: error)
    }

    /// Best-effort browser launch. Failures are silent: the URL was already
    /// printed for the user to open manually.
    static func openInSystemBrowser(_ url: URL) {
        #if os(macOS)
        let launcher = "/usr/bin/open"
        #else
        let launcher = "/usr/bin/xdg-open"
        #endif
        guard FileManager.default.isExecutableFile(atPath: launcher) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
