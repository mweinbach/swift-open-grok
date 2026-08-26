import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokSessionPersistence
import OpenGrokWorkspace

/// The ACP metadata lane inherits launch authority, never request authority.
/// Rust: `agent/mvp_agent/agent_ops.rs:526-565`; `session/merge.rs:184-200`.
struct LivePersistentSessionRemoteRegistry: Sendable {
    private let home: URL
    private let environment: [String: String]?
    private let transport: any HTTPTransport
    private let identityPin: IdentityPin
    let workingDirectory: URL
    let repositoryRemotes: [String]
    let enabled: Bool

    init(
        home: URL,
        workingDirectory: URL,
        environment: [String: String],
        transport: any HTTPTransport,
        remoteRegistryEnabled: Bool?
    ) {
        self.home = home.standardizedFileURL
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.transport = transport
        self.identityPin = IdentityPin()

        var isolated = environment
        isolated["OPENGROK_HOME"] = self.home.path
        self.enabled = LiveRemoteSessionHydration.registryEnabled(
            environment: isolated,
            remoteRegistryEnabled: remoteRegistryEnabled
        )

        guard enabled else {
            self.environment = nil
            self.repositoryRemotes = []
            return
        }

        do {
            let document = try loadAuthorityComposition(
                cwd: self.workingDirectory,
                environment: isolated
            ).effective()
            for (variable, key) in [
                ("GROK_CLI_CHAT_PROXY_BASE_URL", "cli_chat_proxy_base_url"),
                ("GROK_DEPLOYMENT_KEY", "deployment_key"),
                ("GROK_ALPHA_TEST_KEY", "alpha_test_key"),
            ] where isolated[variable] == nil {
                if let configured = document[path: ["endpoints", key]]?.stringValue,
                   !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    isolated[variable] = configured
                }
            }
            self.environment = isolated
            self.repositoryRemotes = WorkspaceSessionGitMetadata.resolve(
                at: self.workingDirectory
            ).gitRemotes
        } catch {
            self.environment = nil
            self.repositoryRemotes = []
        }
    }

    func search(query: String?, limit: Int) async -> [SessionReplicaResponse] {
        guard enabled, limit > 0, let environment else { return [] }
        let initial: GrokAuth
        do {
            initial = try await durableAccount(environment: environment)
        } catch {
            identityPin.close()
            return []
        }
        let expected = Identity(initial)
        guard identityPin.verify(expected) else { return [] }

        do {
            let outerLimit = max(100, min(limit, 1_111) * 3)
            let client = try LiveSessionRegistryClient(
                home: home,
                environment: environment,
                transport: transport
            )
            let sessions = try await client.search(query: query, limit: outerLimit)

            // Deployment auth bypasses the client's bearer-account pin, so the
            // caller must still prove this response belongs to its launch owner.
            let final: GrokAuth
            do {
                final = try await durableAccount(environment: environment)
            } catch {
                identityPin.close()
                return []
            }
            guard Identity(final) == expected, identityPin.verify(expected) else {
                identityPin.close()
                return []
            }
            try Task.checkCancellation()
            return sessions.filter(Self.validWorkspace)
        } catch {
            return []
        }
    }

    private func durableAccount(environment: [String: String]) async throws -> GrokAuth {
        let manager = AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )
        guard let account = await manager.currentOrExpired(),
              account.isXAIAuth,
              account.isSessionAuth,
              !account.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              account.userID.utf8.count <= 16 * 1_024,
              account.key.utf8.count <= 16 * 1_024,
              !account.userID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !account.key.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw LiveSessionRegistryClientError.unavailable
        }
        switch account.authMode {
        case .oidc, .external:
            return account
        case .apiKey, .webLogin:
            throw LiveSessionRegistryClientError.unavailable
        }
    }

    private static func validWorkspace(_ replica: SessionReplicaResponse) -> Bool {
        guard replica.cwd.utf8.count <= 16 * 1_024,
              !replica.cwd.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return false }
        do {
            try RelocationFS.validateCWD(field: "cwd", value: replica.cwd)
            return true
        } catch {
            return false
        }
    }

    private struct Identity: Equatable, Sendable {
        let userID: String
        let principalID: String?
        let teamID: String?
        let organizationID: String?
        let issuer: String?
        let mode: AuthMode

        init(_ auth: GrokAuth) {
            userID = auth.userID
            principalID = auth.principalID
            teamID = auth.teamID
            organizationID = auth.organizationID
            issuer = auth.oidcIssuer
            mode = auth.authMode
        }
    }

    private final class IdentityPin: @unchecked Sendable {
        private let lock = NSLock()
        private var identity: Identity?
        private var closed = false

        func verify(_ candidate: Identity) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return false }
            if let identity {
                guard identity == candidate else {
                    closed = true
                    return false
                }
            } else {
                identity = candidate
            }
            return true
        }

        func close() {
            lock.lock()
            closed = true
            lock.unlock()
        }
    }
}
