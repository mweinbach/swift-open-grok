import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport

/// ACP deletion knows the serving agent's storage mode, unlike the standalone
/// sessions command. Only a writeback agent can own a remote copy to erase.
///
/// Rust: `extensions/session_admin.rs:434-483` and
/// `session/persistence.rs:3681-3746` at `00e176c8`.
struct LiveACPSessionRemoteAdministration: Sendable {
    private struct AccountIdentity: Sendable, Equatable {
        let userID: String
        let principalID: String?
        let teamID: String?
        let organizationID: String?

        init(_ account: GrokAuth) {
            userID = account.userID
            principalID = account.principalID
            teamID = account.teamID
            organizationID = account.organizationID
        }
    }

    private let home: URL
    private let environment: [String: String]
    private let storageMode: LiveSessionWritebackSync.Mode
    private let transport: any HTTPTransport

    init(
        home: URL,
        environment: [String: String],
        storageMode: LiveSessionWritebackSync.Mode,
        transport: any HTTPTransport
    ) {
        self.home = home.standardizedFileURL
        self.environment = environment
        self.storageMode = storageMode
        self.transport = transport
    }

    func deleteIfEligible(sessionID: String) async throws {
        try LiveConversationStore.validateSessionID(sessionID)
        guard storageMode == .writeback else { return }

        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        let manager = AuthManager(
            grokHome: home,
            config: configuration,
            environment: environment
        )
        guard let original = await manager.current(), Self.isEligible(original) else {
            return
        }
        let identity = AccountIdentity(original)

        let client = try LiveSessionWritebackClient(
            home: home,
            environment: environment,
            authManager: manager,
            exportBoundary: ExportBoundary(),
            transport: transport,
            clientMode: "acp"
        )
        let removed = try await client.deleteSessionData(sessionID: sessionID)

        // AuthManager caches its snapshot. A separate manager must reread the
        // owner-private file before granting permission to erase local data.
        // Same-account token rotation is safe: DELETE publishes no transcript.
        let durable = AuthManager(
            grokHome: home,
            config: configuration,
            environment: environment
        )
        guard let current = await durable.current() else {
            throw LiveSessionWritebackClientError.accountChanged
        }
        if current.isZDRTeam {
            throw LiveSessionWritebackClientError.zeroDataRetention
        }
        guard Self.isEligible(current), AccountIdentity(current) == identity else {
            throw LiveSessionWritebackClientError.accountChanged
        }
        try Task.checkCancellation()

        // `false` is precisely the backend's idempotent 404. The account
        // recheck above is equally necessary before deleting either outcome.
        if !removed { return }
    }

    private static func isEligible(_ account: GrokAuth) -> Bool {
        guard account.isXAIAuth,
              account.isSessionAuth,
              TokenType.from(auth: account).isRefreshable,
              !account.isZDRTeam,
              !account.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        switch account.authMode {
        case .oidc:
            return account.refreshToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        case .external:
            return true
        case .apiKey, .webLogin:
            return false
        }
    }
}
