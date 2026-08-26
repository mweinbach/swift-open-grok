import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellSessionSupport
import OpenGrokWorkspace

/// The persistent first-party agent behind `agent` and `agent headless`.
///
/// Rust `agent/app.rs:434-573` admits only a grok.com OIDC session before
/// starting its outbound ACP relay. Unlike upstream's destructive pre-login
/// clear (`auth/flow.rs:534-539`), forced reauthentication leaves every prior
/// credential intact until the browser flow successfully commits its own scope.
public enum LiveAgentRelayComposition {
    static let missingSessionMessage =
        "Headless mode requires a grok.com session. Run `open-grok login` "
        + "to sign in, or use `open-grok agent stdio` for API-key access."

    public static func session(
        options: CLIExecutionOptions,
        context: CLIApplicationContext,
        services: LiveACPServices,
        authServices: LiveAuthServices = .production,
        authDependencies: LiveLeaderAuthDependencies = .production(),
        remoteSettings: RemoteSettings? = nil
    ) async throws -> CLIApplicationSession {
        guard let relayOptions = options.agentRelay else {
            throw CLIApplicationError.unsupported(route: "agent headless relay")
        }
        try validateLaunchOptions(options)

        let environment = context.environment
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        var configuration = try LiveAuthComposition.effectiveGrokComConfig(
            environment: environment
        )
        if let override = relayOptions.grokWSURL {
            configuration.grokWSURL = override
        }
        if let override = relayOptions.grokWSOrigin {
            configuration.grokWSOrigin = override
        }
        let relayURL = try validatedWebSocketURL(configuration.grokWSURL)
        try validateOrigin(configuration.grokWSOrigin)

        let remote = remoteSettings.map(AllowlistedRemoteSettings.init(projecting:))
        if let policy = configuration.forceLoginTeamUUID, policy.allowedIDs.isEmpty {
            try enforceLoginPrincipal(policy: policy, actual: nil)
        }
        if let gate = remote?.gateMessage,
           !gate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIApplicationError.failed(gate)
        }

        let authFile = authenticationFile(home: home, environment: environment)
        if FileManager.default.fileExists(atPath: authFile.path) {
            let existingStore = try readAuthJSON(at: authFile)
            let existingAccount = lookupAuth(existingStore, scope: configuration.authScope)
            try validateAccount(existingAccount, remote: remote)
            if let existingAccount {
                try validatePrincipal(existingAccount, configuration: configuration)
            }
        }

        let manager = AuthManager(
            grokHome: home,
            config: configuration,
            environment: environment
        )

        if options.advanced.reauthenticate {
            guard configuration.effectiveOIDC != nil else {
                throw CLIApplicationError.failed(
                    "--reauth is unavailable because xAI OAuth is not configured"
                )
            }
            let announce: @Sendable (URL) -> Void = { url in
                context.streams.err(
                    "\nTo sign in, open this URL in your browser:\n\n  "
                    + url.absoluteString + "\n\n"
                )
                authServices.openBrowser?(url)
            }
            let replacement = try await authServices.xaiBrowserLogin(
                manager,
                environment,
                authServices.makeTransport(),
                announce
            )
            guard let committed = await manager.currentOrExpired(), committed == replacement else {
                throw CLIApplicationError.failed(
                    "xAI browser sign-in did not commit its authenticated account"
                )
            }
        }

        if let current = await manager.currentOrExpired() {
            await manager.configureRefresher(
                authDependencies.makeRefresher(current, configuration)
            )
        }

        let authenticated: GrokAuth
        do {
            authenticated = try await manager.auth()
        } catch AuthError.notLoggedIn {
            throw CLIApplicationError.failed(missingSessionMessage)
        }
        try validateAccount(authenticated, remote: remote)
        try validatePrincipal(authenticated, configuration: configuration)
        guard let authorization = LiveLeaderComposition.relayAuthorization(
            auth: authenticated,
            tokenType: await manager.tokenType(),
            tokenHeader: configuration.tokenHeader
        ) else {
            throw CLIApplicationError.failed(missingSessionMessage)
        }

        let cwd = try liveResolveWorkingDirectory(options.common.cwd)
        let runtimeSessionID = options.sessionID ?? UUID().uuidString
        var launchOptions = options
        launchOptions.sessionID = runtimeSessionID
        // A restored model/provider preference must never silently route a
        // first-party relay turn through Codex or another external provider.
        launchOptions.common.provider = "xai"
        let launch = LiveACPLaunch(
            workingDirectory: cwd,
            openGrokHome: home,
            environment: environment,
            streams: context.streams,
            options: launchOptions
        )
        let components = try await services.makeComponents(launch)
        let workspace = LocalOpenGrokShellWorkspace(root: cwd, openGrokHome: home)
        let runtime = DefaultOpenGrokShellACPRuntimeFactory().makeRuntime(
            sessionID: SessionID(runtimeSessionID),
            cwd: cwd,
            workspace: workspace,
            promptDriver: components.promptDriver,
            extensionHandler: components.extensionHandler,
            extensionNotifications: components.extensionNotifications,
            onSessionOpened: components.onSessionOpened,
            onSessionClosed: components.onSessionClosed,
            configuration: ACPAgentConfiguration(
                agentCapabilities: components.agentCapabilities,
                initializationMetadata: OpenGrokInitializeMetadata(
                    currentWorkingDirectory: cwd.path
                )
            )
        ).runtime
        await runtime.setCombineQueuedPrompts(
            LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: cwd,
                environment: environment
            ).inputModes.combineQueuedPrompts
        )
        if let gateway = components.notificationGateway {
            await gateway.attach(runtime)
        }
        if let permissionPrompter = components.permissionPrompter {
            await permissionPrompter.attach(client: ACPRuntimePermissionClient(runtime))
        }

        let tokenHeader = configuration.tokenHeader
        let recovery: ACPRelayClient.AuthRecovery = { _ in
            switch await manager.recoverUnauthorized() {
            case .recovered:
                guard let refreshed = await manager.current(),
                      let refreshedAuthorization = LiveLeaderComposition.relayAuthorization(
                          auth: refreshed,
                          tokenType: await manager.tokenType(),
                          tokenHeader: tokenHeader
                      )
                else {
                    return .terminalFailure
                }
                return .recovered(refreshedAuthorization)
            case .retryableFailure:
                return .retryableFailure
            case .terminalFailure:
                return .terminalFailure
            }
        }
        let relay = ACPRelayClient(
            configuration: ACPRelayConfiguration(
                url: relayURL,
                origin: configuration.grokWSOrigin,
                authorization: authorization,
                clientVersion: OpenGrokCLIVersion.installed(environment: environment),
                clientMode: "headless",
                reconnect: .relay
            ),
            makeRuntime: { runtime },
            authRecovery: recovery,
            log: { message in context.streams.err("\(message)\n") }
        )

        return CLIApplicationSession(
            waitForExit: {
                await withTaskCancellationHandler {
                    await relay.run()
                } onCancel: {
                    Task { await relay.stop() }
                }
            },
            shutdown: {
                await relay.stop()
                await runtime.close()
                await components.promptDriver.shutdown()
            }
        )
    }

    private static func validateLaunchOptions(_ options: CLIExecutionOptions) throws {
        guard !options.common.leader else {
            throw CLIApplicationError.unsupported(route: "agent headless leader attachment")
        }
        if let provider = options.common.provider,
           try OpenGrokLiveApplicationLauncher.resolveProvider(provider) != .xai {
            throw CLIApplicationError.failed(
                "the agent headless relay requires the first-party xAI provider"
            )
        }
        let unsupported: [(Bool, String)] = [
            (options.prompt != nil, "--prompt"),
            (options.promptJSON != nil, "--prompt-json"),
            (options.promptFile != nil, "--prompt-file"),
            (options.resume != nil, "--resume"),
            (options.loadSession != nil, "--load"),
            (options.continueSession, "--continue"),
            (options.forkSession, "--fork"),
            (options.restoreCode, "--restore-code"),
            (options.worktree != nil, "--worktree"),
            (options.worktreeRef != nil, "--worktree-ref"),
            (options.jsonSchema != nil, "--json-schema"),
            (options.includePartialMessages, "--include-partial-messages"),
            (options.verbatim, "--verbatim"),
            (options.outputFormat != .plain, "--output-format"),
            (options.chat, "--chat"),
            (options.localWorkspace != nil, "--local-workspace"),
            (options.localWorkspaceAttach != nil, "--local-workspace-attach"),
            (options.localWorkspaceCWD != nil, "--local-workspace-cwd"),
            (options.minimalRendering, "--minimal"),
            (options.noAltScreen, "--no-alt-screen"),
            (options.fullscreen, "--fullscreen"),
        ]
        if let (_, flag) = unsupported.first(where: { $0.0 }) {
            throw CLIApplicationError.unsupported(route: "\(flag) with agent headless relay")
        }
    }

    private static func authenticationFile(
        home: URL,
        environment: [String: String]
    ) -> URL {
        if let override = environment["OPENGROK_AUTH_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent("auth.json")
    }

    private static func validateAccount(
        _ auth: GrokAuth?,
        remote: AllowlistedRemoteSettings?
    ) throws {
        if auth?.isZDRTeam == true, remote?.zdrAccessEnabled != true {
            throw CLIApplicationError.failed(
                "xAI login is unavailable because zero-data-retention access is disabled"
            )
        }
    }

    private static func validatePrincipal(
        _ auth: GrokAuth,
        configuration: GrokComConfig
    ) throws {
        try enforceLoginPrincipal(
            policy: configuration.forceLoginTeamUUID,
            actual: auth.principalID
                ?? auth.teamID
                ?? peekAccessTokenPrincipalID(auth.key)
        )
    }

    private static func validatedWebSocketURL(_ value: String) throws -> WebSocketURL {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !value.contains("#")
        else {
            throw CLIApplicationError.failed("the agent relay WebSocket URL is invalid")
        }
        let url: WebSocketURL
        do {
            url = try WebSocketURL.parse(value)
        } catch {
            throw CLIApplicationError.failed("the agent relay WebSocket URL is invalid: \(error)")
        }
        guard !url.host.contains("@"),
              !url.host.contains(where: { $0.isWhitespace }),
              url.isSecure || isLoopbackHost(url.host)
        else {
            throw CLIApplicationError.failed("the agent relay WebSocket URL is invalid")
        }
        return url
    }

    private static func validateOrigin(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let origin = URLComponents(string: value),
              origin.scheme == "https" || origin.scheme == "http",
              origin.host?.isEmpty == false,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              origin.scheme == "https" || isLoopbackHost(origin.host ?? "")
        else {
            throw CLIApplicationError.failed("the agent relay WebSocket origin is invalid")
        }
    }

    private static func isLoopbackHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if host == "localhost" || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else {
            return false
        }
        return octets.allSatisfy { octet in
            guard let value = UInt8(octet) else { return false }
            return String(value) == String(octet)
        }
    }
}
