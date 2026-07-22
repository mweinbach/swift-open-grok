// OpenGrokSecretsTests.swift
//
// Redaction fixtures ported from `xai-grok-secrets` plus SecretStore
// platform/owner-only tests. Secrets must never appear in descriptions.

import Foundation
import Testing
@testable import OpenGrokSecrets

@Suite("OpenGrokSecrets")
struct OpenGrokSecretsTests {

    /// Join fixture fragments so scanners don't flag synthetic credentials.
    private func fixture(_ parts: [String]) -> String { parts.joined() }

    // MARK: - Credential redaction

    @Test("Credential description never leaks secret")
    func credentialRedacts() {
        let cred = Credential(account: "xai", secret: "super-secret-value", metadata: ["scope": "default"])
        #expect(cred.account == "xai")
        #expect(cred.secret == "super-secret-value")
        #expect(cred.metadata["scope"] == "default")
        #expect(!cred.description.contains("super-secret"))
        #expect(cred.description.contains(SecretRedaction.secret))
        #expect(!cred.debugDescription.contains("super-secret"))
    }

    @Test("Unsupported store never silent plaintext")
    func unsupportedStore() async {
        let store = UnsupportedSecretStore()
        #expect(store.backend == .unsupported)
        do {
            _ = try await store.read(account: "xai")
            Issue.record("Expected unsupported")
        } catch SecretStoreError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected: \(error)")
        }
        #expect(BootstrapSecretStore().backend == .unsupported)
    }

    // MARK: - Sanitizer (Rust fixtures)

    @Test("match pattern count tripwire")
    func matchCount() {
        #expect(SecretSanitizer.matchPatternCount == 10)
    }

    @Test("no match returns identical string")
    func noMatchBorrowed() {
        let input = "just a normal log line"
        #expect(SecretSanitizer.redactSecrets(input) == input)
        #expect(SecretSanitizer.redactSecrets("model=grok-3") == "model=grok-3")
    }

    @Test("redacts known secret shapes")
    func redactsKnown() {
        let cases: [(String, String)] = [
            (fixture(["key: xai-", "abc123XYZdef456GHIjkl789"]), "xai api key"),
            (fixture(["aws AKIA", "ABCDEFGHIJKLMNOP key"]), "aws access key"),
            (fixture(["Authorization: Bearer eyJhbGciOiJIUzI1NiJ9", ".foo.bar.baz"]), "bearer token"),
            (fixture(["api_key=", "ABCDEFGHIJ"]), "key=value"),
            (fixture(["refresh_token: \"rt_", "abc1234567\""]), "compound token name"),
            (
                fixture([
                    "deployment key eyJhbGciOiJIUzI1NiJ9",
                    ".eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4f",
                ]),
                "bare jwt"
            ),
        ]
        for (input, label) in cases {
            let out = SecretSanitizer.redactSecrets(input)
            #expect(out.contains(SecretRedaction.secret), Comment(rawValue: label))
        }
    }

    @Test("redacts additional provider prefixes")
    func redactsProviders() {
        let cases: [(String, String)] = [
            (fixture(["token ghp_", "0123456789abcdefghijABCDEFGHIJ012345"]), "github classic"),
            (
                fixture([
                    "github_pat_",
                    "11ABCDE0123456789_abcdefghijklmnopqrstuvwxyz0123456789",
                ]),
                "github fine-grained"
            ),
            (fixture(["glpat-", "0123456789abcdefABCD here"]), "gitlab"),
            (fixture(["xoxb-", "2420837490-2420837490-AbCdEfGhIjKlMnOpQr"]), "slack bot"),
            (fixture(["xapp-1-", "A0123BCDEF-0123456789-abcdef0123"]), "slack app"),
            (fixture(["AIza", "SyD0123456789abcdefghijklmnopqrstuvw"]), "google"),
            (fixture(["aws ASIA", "ABCDEFGHIJKLMNOP creds"]), "aws temp"),
            (fixture(["stripe sk_live_", "0123456789abcdefghijABCD"]), "stripe"),
        ]
        for (input, label) in cases {
            let out = SecretSanitizer.redactSecrets(input)
            #expect(out.contains(SecretRedaction.secret), Comment(rawValue: label))
        }
    }

    @Test("does not over-redact sk lookalikes")
    func noOverRedact() {
        for input in [
            "task-deadbeefdeadbeefdeadbeef0123",
            "disk-0123456789abcdefghijklmno",
            "risk-0123456789abcdefghijklmno",
        ] {
            #expect(SecretSanitizer.redactSecrets(input) == input)
        }
    }

    @Test("redacts PEM private key block")
    func redactsPEM() {
        let input = "key:\n-----BEGIN PRIVATE KEY-----\nMIIabc123def456\nMIIxyz789\n-----END PRIVATE KEY-----\ndone"
        let out = SecretSanitizer.redactSecrets(input)
        #expect(out.contains(SecretRedaction.secret))
        #expect(!out.contains("MIIabc123"))
        #expect(!out.contains("BEGIN PRIVATE KEY"))
    }

    @Test("redacts bare JWT leaving no token")
    func redactsJWT() {
        let out = SecretSanitizer.redactSecrets(
            "deployment key eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4f"
        )
        #expect(!out.contains("eyJ"))
    }

    @Test("redacts sensitive URL query params")
    func redactsURLParams() {
        let out = SecretSanitizer.redactSecrets(
            "callback https://x.ai/cb?code=ABC123XYZ&state=xyz789 failed"
        )
        #expect(!out.contains("ABC123XYZ"))
        #expect(!out.contains("xyz789"))
    }

    @Test("URL regex excludes trailing punctuation")
    func urlTrailingPunct() {
        let out = SecretSanitizer.redactSecrets("see `https://x.ai/cb?code=ABCD12345`")
        #expect(out.hasSuffix("`"))
    }

    @Test("leaves unrelated URLs alone")
    func leavesURLs() {
        let input = "https://api.example.com/v1/health?region=us-east-1"
        #expect(SecretSanitizer.redactSecrets(input) == input)
    }

    @Test("redact user paths collapses home and username")
    func userPaths() {
        let out = SecretSanitizer.redactUserPathsEnv(
            "/Users/alice/work/alice/file",
            home: "/Users/alice",
            usernames: ["alice"]
        )
        #expect(out == "~/work/<user>/file")
    }

    @Test("home prefix matches whole segment only")
    func homeWholeSegment() {
        let out = SecretSanitizer.redactUserPathsEnv(
            "/Users/bobby/x",
            home: "/Users/bob",
            usernames: []
        )
        #expect(out == "/Users/bobby/x")
    }

    @Test("user paths before punctuation")
    func userPathsPunct() {
        let home = "/Users/alice"
        let cases = [
            ("open '/Users/alice'", "open '~'"),
            ("/Users/alice: permission denied", "~: permission denied"),
            ("/Users/alice, retrying", "~, retrying"),
            ("path /Users/alice ok", "path ~ ok"),
        ]
        for (input, want) in cases {
            #expect(SecretSanitizer.redactUserPathsEnv(input, home: home, usernames: []) == want)
        }
        #expect(
            SecretSanitizer.redactUserPathsEnv("/data/alice: denied", home: nil, usernames: ["alice"])
                == "/data/<user>: denied"
        )
        #expect(
            SecretSanitizer.redactUserPathsEnv("/Users/alicia/x", home: home, usernames: [])
                == "/Users/alicia/x"
        )
    }

    @Test("backstop anonymizes when env unset")
    func backstop() {
        let out = SecretSanitizer.redactUserPathsWithBackstop(
            "/Users/realname/secret/file",
            home: nil,
            usernames: []
        )
        #expect(out == "/Users/<user>/secret/file")
    }

    @Test("backstop skipped when env known")
    func backstopSkipped() {
        let out = SecretSanitizer.redactUserPathsWithBackstop(
            "/Users/Shared/cfg",
            home: "/Users/alice",
            usernames: ["alice"]
        )
        #expect(out == "/Users/Shared/cfg")
    }

    @Test("redactURLString strips credentials and fragment")
    func redactURL() {
        let out = SecretSanitizer.redactURLString(
            "https://user:pw@idp.example.com/cb?code=ABC123XYZ&page=2#access_token=DEF456"
        )
        #expect(!out.contains("user"))
        #expect(!out.contains("pw"))
        #expect(!out.contains("ABC123XYZ"))
        #expect(!out.contains("DEF456"))
        #expect(out.contains("idp.example.com/cb"))
        #expect(out.contains("page=2"))
    }

    // MARK: - Owner-only file store

    @Test("owner-only store write/read/delete round trip")
    func ownerOnlyRoundTrip() async throws {
        #if os(Windows)
        #expect(throws: SecretStoreError.self) {
            _ = try OwnerOnlyFileSecretStore(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ogrok-win")
            )
        }
        return
        #else
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try OwnerOnlyFileSecretStore(rootDirectory: root)
        #expect(store.backend == .ownerOnlyFallback)

        try await store.write(Credential(account: "provider-a", secret: "tok-12345678", metadata: ["k": "v"]))
        let read = try await store.read(account: "provider-a")
        #expect(read.secret == "tok-12345678")
        #expect(read.metadata["k"] == "v")

        // Root must be 0700; files 0600.
        let rootAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
        let rootPerms = rootAttrs[.posixPermissions] as? NSNumber
        #expect(rootPerms?.intValue == 0o700)

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let json = files.first { $0.pathExtension == "json" }!
        let attrs = try FileManager.default.attributesOfItem(atPath: json.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)

        try await store.delete(account: "provider-a")
        do {
            _ = try await store.read(account: "provider-a")
            Issue.record("expected notFound")
        } catch SecretStoreError.notFound {
            // expected
        }
        #endif
    }

    @Test("distinct accounts never collide on filename sanitization")
    func accountNoCollision() async throws {
        #if os(Windows)
        return
        #else
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OwnerOnlyFileSecretStore(rootDirectory: root)
        let accounts = ["a/b", "a_b", "..", "../x", "a\\b"]
        for (i, acct) in accounts.enumerated() {
            try await store.write(
                Credential(account: acct, secret: "secret-value-\(i)-xxxxxx")
            )
        }
        for (i, acct) in accounts.enumerated() {
            let cred = try await store.read(account: acct)
            #expect(cred.secret == "secret-value-\(i)-xxxxxx")
            #expect(cred.account == acct)
        }
        let listed = try await store.listAccounts()
        #expect(listed.count == accounts.count)
        #endif
    }

    @Test("owner-only errors never include secret material")
    func ownerOnlyErrors() async throws {
        #if os(Windows)
        return
        #else
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OwnerOnlyFileSecretStore(rootDirectory: root)
        do {
            _ = try await store.read(account: "missing")
        } catch let err as SecretStoreError {
            #expect(!String(describing: err).contains("tok-"))
        }
        #endif
    }

    @Test("concurrent owner-only writes do not corrupt")
    func concurrentOwnerOnly() async throws {
        #if os(Windows)
        return
        #else
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OwnerOnlyFileSecretStore(rootDirectory: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await store.write(
                        Credential(account: "acct", secret: "value-\(i)-xxxxxxxx")
                    )
                }
            }
            try await group.waitForAll()
        }
        let cred = try await store.read(account: "acct")
        #expect(cred.secret.hasPrefix("value-"))
        #expect(!cred.description.contains(cred.secret))
        #endif
    }

    // MARK: - Platform store

    @Test("preferred backend matches platform")
    func preferredBackend() {
        #if os(macOS)
        #expect(PlatformSecretStore.preferredBackend == .keychain)
        #elseif os(Linux)
        #expect(PlatformSecretStore.preferredBackend == .secretService)
        #elseif os(Windows)
        #expect(PlatformSecretStore.preferredBackend == .credentialManager)
        #endif
    }

    @Test("macOS Keychain store round trip preserves metadata")
    func keychainRoundTrip() async throws {
        #if os(macOS)
        let service = "ai.xai.open-grok.secrets.test.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let account = "test-account-\(UUID().uuidString.prefix(8))"
        let secret = "keychain-secret-value-xyz"
        try await store.write(
            Credential(account: account, secret: secret, metadata: ["scope": "test"])
        )
        let read = try await store.read(account: account)
        #expect(read.secret == secret)
        #expect(read.metadata["scope"] == "test")
        #expect(!read.description.contains(secret))

        // Account switch / overwrite must not lose prior if update path used.
        try await store.write(
            Credential(account: account, secret: "rotated-secret-value", metadata: ["scope": "prod"])
        )
        let rotated = try await store.read(account: account)
        #expect(rotated.secret == "rotated-secret-value")
        #expect(rotated.metadata["scope"] == "prod")

        try await store.delete(account: account)
        do {
            _ = try await store.read(account: account)
            Issue.record("expected notFound after delete")
        } catch SecretStoreError.notFound {
            // expected
        }
        #else
        do {
            _ = try await PlatformSecretStore.makeDefault()
        } catch SecretStoreError.unsupported {
            // expected without ownerOnlyRoot
        } catch SecretStoreError.ownerOnlyFallbackActive {
            // also acceptable
        }
        #endif
    }

    @Test("makeDefault with failClosed on Linux-style fallback throws")
    func failClosedFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-fb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #if os(macOS)
        let store = try await PlatformSecretStore.makeDefault(
            options: SecretStoreOptions(failClosedOnFallback: true, ownerOnlyRoot: root)
        )
        #expect(store.backend == .keychain)
        #elseif os(Windows)
        do {
            _ = try await PlatformSecretStore.makeDefault(
                options: SecretStoreOptions(failClosedOnFallback: true, ownerOnlyRoot: root)
            )
            Issue.record("expected unsupported on Windows")
        } catch SecretStoreError.unsupported {
            // expected — no silent plaintext
        }
        #else
        do {
            _ = try await PlatformSecretStore.makeDefault(
                options: SecretStoreOptions(failClosedOnFallback: true, ownerOnlyRoot: root)
            )
            Issue.record("expected ownerOnlyFallbackActive")
        } catch SecretStoreError.ownerOnlyFallbackActive {
            // expected
        }
        #endif
    }
}
