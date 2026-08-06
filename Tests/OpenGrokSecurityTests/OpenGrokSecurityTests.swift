import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokAuth
import OpenGrokFileTools
import OpenGrokProviderSession
import OpenGrokReleaseValidation
import OpenGrokSamplingTypes
import OpenGrokSandbox
import OpenGrokShellBase

private struct SecurityFixture: Sendable {
    let root: URL
    let workspace: URL
    let outside: URL
    let home: URL
    let openGrokHome: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-security-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let openGrokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openGrokHome, withIntermediateDirectories: true)
        self.root = root
        self.workspace = workspace
        self.outside = outside
        self.home = home
        self.openGrokHome = openGrokHome
    }

    var environment: [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "off",
            "OPENGROK_ALLOW_WRITES": "1",
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func testJWT(payload: [String: Any]) throws -> String {
    func encode(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return try [
        encode(["alg": "none", "typ": "JWT"]),
        encode(payload),
        "signature",
    ].joined(separator: ".")
}

private func codexIDToken() throws -> String {
    try testJWT(payload: [
        "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "acct-security",
            "chatgpt_user_id": "user-security",
            "chatgpt_plan_type": "plus",
        ],
    ])
}

private func freshAccessToken() throws -> String {
    try testJWT(payload: [
        "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
    ])
}

@Suite("security release gate")
struct SecurityReleaseGateTests {
    @Test("resume cannot weaken a persisted sandbox")
    func sandboxWeakeningIsRejected() {
        do {
            try LiveSandboxComposition.validateResume(requested: "off", persisted: "strict")
            Issue.record("sandbox downgrade unexpectedly succeeded")
        } catch let error as SandboxError {
            guard case .modePinningViolation = error else {
                Issue.record("unexpected sandbox error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("live write rejects a missing leaf below an outbound symlink")
    func liveWriteRejectsSymlinkEscape() async throws {
        let fixture = try SecurityFixture()
        defer { fixture.remove() }

        let sentinel = fixture.outside.appendingPathComponent("sentinel.txt")
        try Data("outside".utf8).write(to: sentinel)
        let link = fixture.workspace.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)

        let sessionID = "security-symlink"
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(),
            sessionID: sessionID,
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: fixture.environment,
            sandboxDecision: LiveSandboxDecision(
                profileName: "off",
                mode: .none,
                enforced: false
            )
        )
        let call = ToolCall(
            id: "security-write",
            name: "write",
            arguments: "{\"file_path\":\"link/created.txt\",\"content\":\"must-not-land\"}"
        )
        let result = await executor.invoke(
            sessionID: sessionID,
            workingDirectory: fixture.workspace,
            call: call
        )
        await executor.shutdown()

        switch result {
        case .success:
            Issue.record("live write unexpectedly succeeded through a symlink")
        case .failure(let error):
            #expect(error.description.localizedCaseInsensitiveContains("symlink"))
        }
        #expect(String(data: try Data(contentsOf: sentinel), encoding: .utf8) == "outside")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.outside.appendingPathComponent("created.txt").path
        ))
    }

    @Test("deterministic parent swap cannot redirect an atomic write")
    func writeTOCTOURefusesOutboundSwap() async throws {
        let fixture = try SecurityFixture()
        defer { fixture.remove() }

        let containedParent = fixture.workspace.appendingPathComponent("swap", isDirectory: true)
        try FileManager.default.createDirectory(at: containedParent, withIntermediateDirectories: true)
        let target = containedParent.appendingPathComponent("created.txt")
        let outsideTarget = fixture.outside.appendingPathComponent("created.txt")
        let resources = FileToolSession.makeResources(
            workspaceRoot: fixture.workspace.path,
            sessionId: "security-toctou",
            policy: .allowAll
        )

        do {
            try await SessionFS.writeText(
                absolute: target.path,
                content: "must-not-land",
                resources: resources,
                previousContent: nil,
                beforeWrite: {
                    try FileManager.default.removeItem(at: containedParent)
                    try FileManager.default.createSymbolicLink(
                        at: containedParent,
                        withDestinationURL: fixture.outside
                    )
                }
            )
            Issue.record("write unexpectedly survived a parent symlink swap")
        } catch let error as SessionFSError {
            guard case .symlinkEscape = error else {
                Issue.record("unexpected file-tool error: \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    @Test("provider credentials and account headers stay isolated")
    func providerCredentialAndHeaderIsolation() async throws {
        let fixture = try SecurityFixture()
        defer { fixture.remove() }
        try storeAPIKey(grokHome: fixture.openGrokHome, apiKey: "xai-only")
        let codexPath = fixture.openGrokHome.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
        let resolver = LiveCredentialResolver(
            environment: fixture.environment,
            openGrokHome: fixture.openGrokHome,
            codexAuthFile: codexPath
        )

        do {
            _ = try await resolver.resolve(provider: .codex, scope: "security")
            Issue.record("Codex borrowed a credential from the xAI store")
        } catch let error as LiveCredentialError {
            guard case .codexAuthRequired = error else {
                Issue.record("unexpected credential error: \(error)")
                return
            }
        }

        try persistCodexTokens(
            at: codexPath,
            idToken: codexIDToken(),
            accessToken: freshAccessToken(),
            refreshToken: "refresh-security",
            accountID: "acct-security"
        )
        let codex = try await resolver.resolve(provider: .codex, scope: "security")
        let mergedCodex = OpenGrokLiveApplicationLauncher.mergeCredentialHeaders(
            provider: .codex,
            credentialHeaders: codex.extraHeaders,
            configuredHeaders: [
                ("Authorization", "Bearer foreign"),
                ("ChatGPT-Account-ID", "foreign-account"),
            ]
        )
        let captured = LockedConfiguration()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { configuration in
                captured.store(configuration)
                return OpenGrokLiveSampler { _, _ in throw CancellationError() }
            }
        )
        _ = try dependencies.makeSampler(OpenGrokLiveSamplingConfiguration(
            model: "security-model",
            baseURL: "https://example.invalid",
            apiKey: codex.bearer,
            provider: .codex,
            extraHeaders: mergedCodex
        ))
        #expect(captured.value?.extraHeaders["ChatGPT-Account-ID"] == "acct-security")
        #expect(captured.value?.extraHeaders["Authorization"] == nil)

        let xai = try await resolver.resolve(
            provider: .xai,
            explicitAPIKey: nil,
            scope: "security"
        )
        let mergedXAI = OpenGrokLiveApplicationLauncher.mergeCredentialHeaders(
            provider: .xai,
            credentialHeaders: xai.extraHeaders,
            configuredHeaders: [("ChatGPT-Account-ID", "foreign-account")]
        )
        #expect(mergedXAI["ChatGPT-Account-ID"] == nil)
    }

    @Test("isolated-home validation fails escaped and legacy paths")
    func isolatedHomeValidationIsFailClosed() throws {
        let fixture = try SecurityFixture()
        defer { fixture.remove() }
        let report = SmokeValidation.validateIsolatedHome(
            isolatedRoot: fixture.workspace.path,
            touchedPaths: [
                fixture.outside.appendingPathComponent("escaped").path,
                fixture.workspace.appendingPathComponent(".grok/legacy").path,
            ]
        )
        #expect(!report.passed)
        #expect(report.findings.contains { $0.id == "isolation.escaped" })
        #expect(report.findings.contains { $0.id == "isolation.legacyHome" })
    }
}

private final class LockedConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OpenGrokLiveSamplingConfiguration?

    var value: OpenGrokLiveSamplingConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ configuration: OpenGrokLiveSamplingConfiguration) {
        lock.lock()
        stored = configuration
        lock.unlock()
    }
}
