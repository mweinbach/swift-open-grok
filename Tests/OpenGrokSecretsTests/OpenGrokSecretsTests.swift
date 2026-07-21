// OpenGrokSecretsTests.swift
import Foundation
import Testing
@testable import OpenGrokSecrets

@Suite("OpenGrokSecrets")
struct OpenGrokSecretsTests {
    @Test("Credential value type and backend")
    func valueTypes() {
        let cred = Credential(account: "xai", secret: "s", metadata: ["scope": "default"])
        #expect(cred.account == "xai")
        #expect(cred.secret == "s")
        #expect(cred.metadata["scope"] == "default")
        #expect(BootstrapSecretStore().backend == .unsupported)
    }

    @Test("BootstrapSecretStore read/write/delete report unsupported (never silent plaintext)")
    func bootstrapStore() async {
        let store = BootstrapSecretStore()
        do {
            _ = try await store.read(account: "xai")
            Issue.record("Expected unsupported")
        } catch SecretStoreError.unsupported {
            // expected — bootstrap never silently downgrades to plaintext
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            try await store.write(Credential(account: "xai", secret: "s"))
            Issue.record("Expected unsupported")
        } catch SecretStoreError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            try await store.delete(account: "xai")
            Issue.record("Expected unsupported")
        } catch SecretStoreError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
