import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokModels

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ManagedSetupNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct LiveManagedSetupServices: Sendable {
    public var makeTransport: @Sendable () -> any HTTPTransport
    public var now: @Sendable () -> Date

    public init(
        makeTransport: @escaping @Sendable () -> any HTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.makeTransport = makeTransport
        self.now = now
    }

    public static let production = LiveManagedSetupServices(
        makeTransport: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            let session = URLSession(
                configuration: configuration,
                delegate: ManagedSetupNoRedirectDelegate(),
                delegateQueue: nil
            )
            return URLSessionHTTPTransport(session: session)
        }
    )
}

public enum LiveManagedSetupOutcome: Sendable, Equatable {
    case installed
    case nothingConfigured
    case skipped
    case reported
}

public struct LiveManagedSetupReport: Encodable, Sendable, Equatable {
    public var source: String?
    public var configured: Bool
    public var deploymentID: String?
    public var teamID: String?
    public var managedConfig: String?
    public var requirements: String?
    public var failClosed: Bool

    private enum CodingKeys: String, CodingKey {
        case source
        case configured
        case deploymentID = "deploymentId"
        case teamID = "teamId"
        case managedConfig
        case requirements
        case failClosed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(configured, forKey: .configured)
        try container.encode(deploymentID, forKey: .deploymentID)
        try container.encode(teamID, forKey: .teamID)
        try container.encode(managedConfig, forKey: .managedConfig)
        try container.encode(requirements, forKey: .requirements)
        try container.encode(failClosed, forKey: .failClosed)
    }
}

private enum LiveManagedSetupPrincipal: Sendable, Equatable {
    case deploymentKey(String)
    case team(GrokAuth)

    var token: String {
        switch self {
        case .deploymentKey(let key): key
        case .team(let auth): auth.key
        }
    }

    var source: String {
        switch self {
        case .deploymentKey: "deploymentKey"
        case .team: "teamOauth"
        }
    }

    var teamID: String? {
        guard case .team(let auth) = self else { return nil }
        return auth.teamID
    }

    var keyFingerprint: String? {
        guard case .deploymentKey(let key) = self else { return nil }
        return Blake3.hexDigest(Array(key.utf8))
    }
}

private struct LiveManagedConfigResponse: Decodable, Sendable {
    var deploymentID: String?
    var teamID: String?
    var managedConfig: String?
    var requirements: String?
    var signatures: [SignatureEnvelope]?
    var managedIdentitySignatures: [SignatureEnvelope]?

    private enum CodingKeys: String, CodingKey {
        case deploymentID = "deployment_id"
        case teamID = "team_id"
        case managedConfig = "managed_config"
        case requirements
        case signatures
        case managedIdentitySignatures = "managed_identity_signatures"
    }

    var configured: Bool { deploymentID != nil || teamID != nil }

    var failClosed: Bool {
        guard let requirements else { return false }
        return failClosedFlagFromStr(requirements)
    }
}

private struct LiveManagedFetchedPolicy: Sendable {
    var principal: LiveManagedSetupPrincipal
    var body: LiveManagedConfigResponse
    var verifiedDeploymentID: String?
    var verifiedEnvelope: SignatureEnvelope?
    var verifiedClaimEnvelope: SignatureEnvelope?
}

private enum LiveManagedSetupFailure: Error, Sendable {
    case noPrincipal
    case invalidCredentials
    case remoteFetchDisabled
    case untrustedEndpoint
    case rejectedDeploymentKey
    case rejectedTeam
    case invalidResponse
    case invalidSignature
    case mismatchedPrincipal
    case server(Int)
    case transport
    case invalidConfiguration
    case disk
    case invalidArguments

    var message: String {
        switch self {
        case .noPrincipal:
            return """
                No deployment key or team sign-in found.

                To install managed configuration, sign in with a team using `open-grok login`,
                or set GROK_DEPLOYMENT_KEY and run `open-grok setup`.
                """
        case .invalidCredentials:
            return "The configured managed account credentials could not be read safely."
        case .remoteFetchDisabled:
            return "Managed configuration fetch is disabled by deployment policy."
        case .untrustedEndpoint:
            return "Managed configuration requires the trusted official xAI deployment endpoint."
        case .rejectedDeploymentKey:
            return "The deployment key was rejected. Confirm that GROK_DEPLOYMENT_KEY is valid."
        case .rejectedTeam:
            return "Your team sign-in was rejected. Run `open-grok login` to sign in again."
        case .invalidResponse:
            return "The server returned an invalid managed configuration response."
        case .invalidSignature:
            return "The managed configuration signature could not be verified; nothing was installed."
        case .mismatchedPrincipal:
            return "The managed configuration belongs to a different team; nothing was installed."
        case .server(let status):
            return "The managed configuration server returned HTTP \(status)."
        case .transport:
            return "The managed configuration server could not be reached."
        case .invalidConfiguration:
            return "The server returned malformed managed configuration; nothing was installed."
        case .disk:
            return "The managed configuration could not be saved safely; existing policy remains enforced."
        case .invalidArguments:
            return "open-grok setup accepts only the optional --json flag."
        }
    }
}

public enum LiveManagedSetupComposition {
    public static let routeName = "setup"
    private static let trustedHost = "cli-chat-proxy.grok.com"
    private static let trustedPath = "/v1/deployment/config"

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return options.name == routeName
    }

    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveManagedSetupServices = .production
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == routeName else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        do {
            try await run(
                options: options,
                environment: context.environment,
                streams: context.streams,
                services: services
            )
        } catch let error as LiveManagedSetupFailure {
            throw CLIApplicationError.failed(error.message)
        } catch {
            throw CLIApplicationError.failed(LiveManagedSetupFailure.disk.message)
        }
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    @discardableResult
    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveManagedSetupServices = .production
    ) async throws -> LiveManagedSetupOutcome {
        guard options.name == routeName, options.values.isEmpty else {
            throw LiveManagedSetupFailure.invalidArguments
        }
        guard let home = userGrokHome(environment: environment) else {
            throw LiveManagedSetupFailure.noPrincipal
        }
        let document = trustedConfigDocument(environment: environment)
        let deploymentKey = resolveDeploymentKey(environment: environment, document: document)
        let credentials: [GrokAuth]
        do {
            credentials = try managedAuthCredentials(home: home, environment: environment)
        } catch {
            guard deploymentKey != nil else { throw error }
            // Deployment credentials own policy independently. A broken
            // optional team source cannot disable that administrator path.
            credentials = []
        }
        let signedInTeam = eligibleTeamPrincipal(
            credentials: credentials,
            environment: environment,
            now: services.now(),
            includingExpired: true
        )
        var team = eligibleTeamPrincipal(
            credentials: credentials,
            environment: environment,
            now: services.now(),
            includingExpired: false
        )
        let bindingTeamID = signedInTeamIDForPolicyBinding(
            home: home,
            environment: environment
        )
        guard deploymentKey != nil || signedInTeam != nil else {
            throw LiveManagedSetupFailure.noPrincipal
        }
        guard resolveTrustedRemoteFetchEnabled(environment: environment) else {
            throw LiveManagedSetupFailure.remoteFetchDisabled
        }
        let endpoint = try trustedManagedEndpoint(environment: environment, document: document)
        let transport = services.makeTransport()
        var operationEnvironment = environment
        if team == nil, let signedInTeam {
            team = await refreshTeamPrincipal(
                signedInTeam,
                home: home,
                environment: environment,
                transport: transport
            )
            if let team, environment["OPENGROK_AUTH"] != nil {
                operationEnvironment["OPENGROK_AUTH"] = try encodeInlineAuth(team)
            }
        }
        guard deploymentKey != nil || team != nil else {
            throw LiveManagedSetupFailure.noPrincipal
        }
        let fetched = try await fetch(
            endpoint: endpoint,
            deploymentKey: deploymentKey,
            team: team,
            bindingTeamID: bindingTeamID,
            transport: transport,
            environment: operationEnvironment,
            now: services.now()
        )

        if options.json {
            let report = LiveManagedSetupReport(
                source: fetched.principal.source,
                configured: fetched.body.configured,
                deploymentID: fetched.body.deploymentID,
                teamID: fetched.body.teamID,
                managedConfig: fetched.body.managedConfig,
                requirements: fetched.body.requirements,
                failClosed: fetched.body.failClosed
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = try encoder.encode(report)
            guard let text = String(data: output, encoding: .utf8) else {
                throw LiveManagedSetupFailure.invalidResponse
            }
            streams.out(text + "\n")
            if !fetched.body.configured {
                streams.err(nothingConfiguredMessage + "\n")
            }
            return .reported
        }

        let outcome = try apply(
            fetched,
            home: home,
            environment: operationEnvironment,
            now: services.now()
        )
        switch outcome {
        case .installed:
            streams.err("Applied managed configuration.\n")
        case .nothingConfigured:
            streams.err(nothingConfiguredMessage + "\n")
        case .skipped:
            streams.err("Managed configuration was not applied this run; run `open-grok setup` again.\n")
        case .reported:
            break
        }
        return outcome
    }

    private static let nothingConfiguredMessage =
        "Your team doesn't have a managed configuration yet. A team admin can set one up at console.x.ai."

    /// A malformed user-owned config cannot erase independently readable
    /// administrator requirements, managed policy, or deployment identity.
    static func trustedConfigDocument(environment: [String: String]) -> TOMLValue {
        do {
            return try ConfigLayers.load(environment: environment).effectiveConfigBase()
        } catch {
            var trusted = (try? loadSystemManagedConfig(environment: environment))
                ?? .table(TOMLTable())
            if let managed = try? loadManagedConfig(environment: environment) {
                deepMergeTOML(&trusted, overrides: managed)
            }
            if let requirements = loadMergedRequirements(environment: environment) {
                deepMergeTOML(&trusted, overrides: requirements)
            }
            return trusted
        }
    }

    /// Match AuthManager's source selection without treating a malformed
    /// highest-priority override as permission to fall back to another user.
    static func managedAuthCredentials(
        home: URL,
        environment: [String: String]
    ) throws -> [GrokAuth] {
        if let inline = environment["OPENGROK_AUTH"] {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) {
                        let fractional = ISO8601DateFormatter()
                        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        let standard = ISO8601DateFormatter()
                        standard.formatOptions = [.withInternetDateTime]
                        if let date = fractional.date(from: text) ?? standard.date(from: text) {
                            return date
                        }
                    }
                    if let timestamp = try? container.decode(Double.self) {
                        return Date(timeIntervalSince1970: timestamp)
                    }
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "invalid account timestamp"
                    )
                }
                return [try decoder.decode(GrokAuth.self, from: Data(inline.utf8))]
            } catch {
                throw LiveManagedSetupFailure.invalidCredentials
            }
        }

        if let override = environment["OPENGROK_AUTH_PATH"], !override.isEmpty {
            do {
                return Array(try readAuthJSON(at: URL(fileURLWithPath: override)).values)
            } catch {
                throw LiveManagedSetupFailure.invalidCredentials
            }
        }
        do {
            let path = home.appendingPathComponent(OpenGrokAuthPaths.authFileName)
            return Array(try readAuthJSONOrEmpty(at: path).values)
        } catch {
            throw LiveManagedSetupFailure.invalidCredentials
        }
    }

    private static func resolveDeploymentKey(
        environment: [String: String],
        document: TOMLValue
    ) -> String? {
        let candidate = deploymentKeyFromEnvironment(environment)
            ?? document[path: ["endpoints", "deployment_key"]]?.stringValue
        guard let key = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private static func activeTeamPrincipal(
        home: URL,
        environment: [String: String],
        now: Date
    ) -> GrokAuth? {
        guard let credentials = try? managedAuthCredentials(home: home, environment: environment) else {
            return nil
        }
        return eligibleTeamPrincipal(
            credentials: credentials,
            environment: environment,
            now: now,
            includingExpired: false
        )
    }

    private static func eligibleTeamPrincipal(
        credentials: [GrokAuth],
        environment: [String: String],
        now: Date,
        includingExpired: Bool
    ) -> GrokAuth? {
        credentials.first {
            $0.isTeamPrincipal
                && $0.isSessionAuth
                && normalizeIdentity($0.teamID) != nil
                && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (includingExpired || !isExpired($0, now: now, environment: environment))
        }
    }

    static func signedInTeamIDForPolicyBinding(
        home: URL,
        environment: [String: String] = [:]
    ) -> String? {
        if let credentials = try? managedAuthCredentials(home: home, environment: environment) {
            return credentials.first { $0.isTeamPrincipal }
                .flatMap { normalizeIdentity($0.teamID) }
        }

        // AuthManager falls through malformed inline JSON to its selected
        // path. A deployment key may still serve policy, but that must never
        // erase the real disk tenant's cryptographic envelope binding.
        var fallback = environment
        fallback.removeValue(forKey: "OPENGROK_AUTH")
        if let credentials = try? managedAuthCredentials(home: home, environment: fallback) {
            return credentials.first { $0.isTeamPrincipal }
                .flatMap { normalizeIdentity($0.teamID) }
        }
        guard fallback.removeValue(forKey: "OPENGROK_AUTH_PATH") != nil,
              let credentials = try? managedAuthCredentials(home: home, environment: fallback)
        else {
            return nil
        }
        return credentials.first { $0.isTeamPrincipal }
            .flatMap { normalizeIdentity($0.teamID) }
    }

    private static func refreshTeamPrincipal(
        _ expired: GrokAuth,
        home: URL,
        environment: [String: String],
        transport: any HTTPTransport
    ) async -> GrokAuth? {
        guard expired.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        else {
            return nil
        }
        let config = GrokComConfig.default(environment: environment)
        guard let refresher = makeXAIOIDCTokenRefresher(
            auth: expired,
            config: config,
            transport: transport
        ) else {
            return nil
        }

        let manager = AuthManager(grokHome: home, config: config, environment: environment)
        await manager.hotSwap(expired)
        await manager.configureRefresher(refresher)
        do {
            let refreshed = try await manager.auth()
            guard refreshed.isTeamPrincipal,
                  refreshed.isSessionAuth,
                  normalizeIdentity(refreshed.teamID) == normalizeIdentity(expired.teamID),
                  !refreshed.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isExpired(refreshed, environment: environment)
            else {
                return nil
            }
            return refreshed
        } catch {
            return nil
        }
    }

    private static func encodeInlineAuth(_ auth: GrokAuth) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(auth), as: UTF8.self)
        } catch {
            throw LiveManagedSetupFailure.invalidCredentials
        }
    }

    private static func trustedManagedEndpoint(
        environment: [String: String],
        document: TOMLValue
    ) throws -> URL {
        let explicit = nonempty(environment["GROK_MANAGED_CONFIG_URL"])
            ?? nonempty(document[path: ["endpoints", "managed_config_url"]]?.stringValue)
        let proxy = nonempty(environment["GROK_CLI_CHAT_PROXY_BASE_URL"])
            ?? nonempty(document[path: ["endpoints", "cli_chat_proxy_base_url"]]?.stringValue)
            ?? CLI_CHAT_PROXY_BASE_URL_DEFAULT
        let value = explicit ?? proxy.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/deployment/config"
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == trustedHost,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == trustedPath,
              let url = components.url
        else {
            throw LiveManagedSetupFailure.untrustedEndpoint
        }
        return url
    }

    private static func nonempty(_ string: String?) -> String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func fetch(
        endpoint: URL,
        deploymentKey: String?,
        team: GrokAuth?,
        bindingTeamID: String?,
        transport: any HTTPTransport,
        environment: [String: String],
        now: Date
    ) async throws -> LiveManagedFetchedPolicy {
        if let key = deploymentKey {
            do {
                let body = try await request(
                    endpoint: endpoint,
                    principal: .deploymentKey(key),
                    transport: transport,
                    environment: environment
                )
                if body.configured || team == nil {
                    return try verified(
                        body: body,
                        principal: .deploymentKey(key),
                        bindingTeamID: bindingTeamID,
                        now: now
                    )
                }
            } catch LiveManagedSetupFailure.rejectedDeploymentKey where team != nil {
                // A rejected stale deployment key must not starve a valid team.
            }
        }
        guard let team else { throw LiveManagedSetupFailure.noPrincipal }
        let body = try await request(
            endpoint: endpoint,
            principal: .team(team),
            transport: transport,
            environment: environment
        )
        return try verified(
            body: body,
            principal: .team(team),
            bindingTeamID: bindingTeamID,
            now: now
        )
    }

    private static func request(
        endpoint: URL,
        principal: LiveManagedSetupPrincipal,
        transport: any HTTPTransport,
        environment: [String: String]
    ) async throws -> LiveManagedConfigResponse {
        let request = HTTPRequest(
            method: .get,
            url: endpoint,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(principal.token)",
            ],
            timeout: 15
        )
        let attempts = 5
        for attempt in 0..<attempts {
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                guard attempt + 1 < attempts else { throw LiveManagedSetupFailure.transport }
                try await retryBackoff(attempt: attempt, environment: environment)
                continue
            }
            let status = response.metadata.statusCode
            if status == 401 || status == 403 {
                throw principal.teamID == nil
                    ? LiveManagedSetupFailure.rejectedDeploymentKey
                    : LiveManagedSetupFailure.rejectedTeam
            }
            if (500..<600).contains(status), attempt + 1 < attempts {
                try await retryBackoff(attempt: attempt, environment: environment)
                continue
            }
            guard (200..<300).contains(status) else {
                throw LiveManagedSetupFailure.server(status)
            }
            do {
                return try JSONDecoder().decode(LiveManagedConfigResponse.self, from: response.body)
            } catch {
                throw LiveManagedSetupFailure.invalidResponse
            }
        }
        throw LiveManagedSetupFailure.transport
    }

    private static func retryBackoff(
        attempt: Int,
        environment: [String: String]
    ) async throws {
        let nanoseconds = boundedRetryBackoffNanoseconds(attempt: attempt, environment: environment)
        guard nanoseconds > 0 else { return }
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    static func boundedRetryBackoffNanoseconds(
        attempt: Int,
        environment: [String: String]
    ) -> UInt64 {
        let base = UInt64(environment["GROK_DEPLOYMENT_CONFIG_BACKOFF_MS"] ?? "1000") ?? 1000
        let multiplier = UInt64(1) << UInt64(min(max(attempt, 0), 4))
        let scaled = base.multipliedReportingOverflow(by: multiplier)
        let milliseconds = scaled.overflow ? 15_000 : min(scaled.partialValue, 15_000)
        return milliseconds * 1_000_000
    }

    private static func verified(
        body: LiveManagedConfigResponse,
        principal: LiveManagedSetupPrincipal,
        bindingTeamID: String?,
        now: Date
    ) throws -> LiveManagedFetchedPolicy {
        if let expected = principal.teamID,
           let returned = body.teamID,
           normalizeIdentity(returned) != normalizeIdentity(expected) {
            throw LiveManagedSetupFailure.mismatchedPrincipal
        }
        if let config = body.managedConfig, !config.isEmpty {
            guard (try? parseTOML(config)) != nil else {
                throw LiveManagedSetupFailure.invalidConfiguration
            }
        }
        if let requirements = body.requirements, !requirements.isEmpty {
            guard (try? parseTOML(requirements)) != nil else {
                throw LiveManagedSetupFailure.invalidConfiguration
            }
        }
        guard verificationActive() else {
            return LiveManagedFetchedPolicy(
                principal: principal,
                body: body,
                verifiedDeploymentID: nil,
                verifiedEnvelope: nil,
                verifiedClaimEnvelope: nil
            )
        }
        guard let envelope = preferredEnvelope(body.signatures) else {
            throw LiveManagedSetupFailure.invalidSignature
        }
        let payload: SignedPayload
        do {
            payload = try verifyFetched(
                sidecar: envelope,
                activeTeamId: bindingTeamID,
                nowUnix: UInt64(max(0, now.timeIntervalSince1970))
            )
        } catch {
            throw LiveManagedSetupFailure.invalidSignature
        }
        guard payload.managedConfig == body.managedConfig,
              payload.requirements == body.requirements else {
            throw LiveManagedSetupFailure.invalidSignature
        }

        let verifiedClaim: SignatureEnvelope? = preferredEnvelope(
            body.managedIdentitySignatures
        ).flatMap { claim -> SignatureEnvelope? in
            guard let value = try? verifyFetchedClaim(
                sidecar: claim,
                nowUnix: UInt64(max(0, now.timeIntervalSince1970))
            ),
                  normalizeIdentity(value.principal)
                    == normalizeIdentity(payload.deploymentId ?? payload.teamId)
            else { return nil }
            return claim
        }
        return LiveManagedFetchedPolicy(
            principal: principal,
            body: body,
            verifiedDeploymentID: normalizeIdentity(payload.deploymentId),
            verifiedEnvelope: envelope,
            verifiedClaimEnvelope: verifiedClaim
        )
    }

    private static func preferredEnvelope(_ envelopes: [SignatureEnvelope]?) -> SignatureEnvelope? {
        guard let envelopes, !envelopes.isEmpty else { return nil }
        return envelopes.first { embeddedKeyIdTrusted($0.keyId) } ?? envelopes.first
    }

    private static func apply(
        _ fetched: LiveManagedFetchedPolicy,
        home: URL,
        environment: [String: String],
        now: Date
    ) throws -> LiveManagedSetupOutcome {
        let lock: AdvisoryLock
        do {
            lock = try AdvisoryFileLock.acquire(
                at: home.appendingPathComponent("managed_config.lock"),
                options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
            )
        } catch let error as FileUtilsError {
            if case .lockFailed = error { return .skipped }
            throw LiveManagedSetupFailure.disk
        } catch {
            throw LiveManagedSetupFailure.disk
        }
        defer { lock.release() }

        let current = resolveDeploymentKey(
            environment: environment,
            document: trustedConfigDocument(environment: environment)
        )
        switch fetched.principal {
        case .deploymentKey(let token):
            guard current == token else { return .skipped }
        case .team(let serving):
            guard let active = activeTeamPrincipal(home: home, environment: environment, now: now),
                  active.key == serving.key,
                  normalizeIdentity(active.teamID) == normalizeIdentity(serving.teamID)
            else { return .skipped }
        }

        let principal: String?
        switch fetched.principal {
        case .deploymentKey:
            principal = fetched.verifiedDeploymentID ?? fetched.body.deploymentID
        case .team(let serving):
            principal = serving.teamID
        }
        let fingerprint = fetched.principal.keyFingerprint
        do {
            try rejectSymbolicManagedArtifacts(in: home)
            if managedConfigIdentityChangedAt(
                home,
                newPrincipal: principal,
                newKeyFingerprint: fingerprint
            ) {
                try removeArtifacts(home: home, includingMarker: false)
            }
            try installArtifact(
                fetched.body.managedConfig,
                at: home.appendingPathComponent(MANAGED_CONFIG_FILENAME)
            )
            try installArtifact(
                fetched.body.requirements,
                at: home.appendingPathComponent(REQUIREMENTS_FILENAME)
            )
            if let envelope = fetched.verifiedEnvelope {
                try writeSidecar(home, sidecar: envelope)
            } else {
                try removeIfPresent(home.appendingPathComponent(SIGNATURE_SIDECAR_FILE))
            }
            if let claim = fetched.verifiedClaimEnvelope {
                try writeManagedIdentitySidecar(home, sidecar: claim)
            } else {
                try removeIfPresent(home.appendingPathComponent(MANAGED_IDENTITY_SIDECAR_FILE))
            }
            let timestamp = UInt64(max(0, now.timeIntervalSince1970))
            let marker = ManagedConfigCache(
                syncedAt: timestamp,
                principal: normalizeIdentity(principal),
                hadManagedConfig: nonempty(fetched.body.managedConfig) != nil,
                hadRequirements: nonempty(fetched.body.requirements) != nil,
                keyFingerprint: fingerprint,
                failClosed: fetched.body.failClosed,
                rollbackFloor: timestamp
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try AtomicFile.write(
                home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE),
                data: encoder.encode(marker),
                options: .ownerOnly
            )
        } catch {
            throw LiveManagedSetupFailure.disk
        }
        return fetched.body.configured ? .installed : .nothingConfigured
    }

    private static func rejectSymbolicManagedArtifacts(in home: URL) throws {
        let artifacts = [
            MANAGED_CONFIG_FILENAME,
            REQUIREMENTS_FILENAME,
            SIGNATURE_SIDECAR_FILE,
            MANAGED_IDENTITY_SIDECAR_FILE,
            MANAGED_CONFIG_CACHE_FILE,
        ]
        for artifact in artifacts {
            let path = home.appendingPathComponent(artifact)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil
                || (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            {
                throw LiveManagedSetupFailure.disk
            }
        }
    }

    private static func installArtifact(_ contents: String?, at path: URL) throws {
        guard let contents, !contents.isEmpty else {
            try removeIfPresent(path)
            return
        }
        try AtomicFile.write(path, contents: contents, options: .ownerOnly)
    }

    private static func removeArtifacts(home: URL, includingMarker: Bool) throws {
        var names = [
            MANAGED_CONFIG_FILENAME,
            REQUIREMENTS_FILENAME,
            SIGNATURE_SIDECAR_FILE,
            MANAGED_IDENTITY_SIDECAR_FILE,
        ]
        if includingMarker { names.append(MANAGED_CONFIG_CACHE_FILE) }
        for name in names {
            try removeIfPresent(home.appendingPathComponent(name))
        }
    }

    private static func removeIfPresent(_ path: URL) throws {
        do {
            try FileManager.default.removeItem(at: path)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain,
                  failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError
            else { throw error }
        }
    }
}
