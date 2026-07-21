// OpenGrokSandboxTests.swift
import Foundation
import Testing
@testable import OpenGrokSandbox

@Suite("OpenGrokSandbox")
struct OpenGrokSandboxTests {
    @Test("canResume never weakens the persisted sandbox mode")
    func noSilentWeakening() {
        let enforcer = BootstrapSandboxEnforcer()
        #expect(!enforcer.canResume(persisted: .restricted, candidate: .readOnly))
        #expect(!enforcer.canResume(persisted: .restricted, candidate: .none))
        #expect(!enforcer.canResume(persisted: .readOnly, candidate: .none))
        #expect(enforcer.canResume(persisted: .none, candidate: .readOnly))
        #expect(enforcer.canResume(persisted: .readOnly, candidate: .restricted))
        #expect(enforcer.canResume(persisted: .restricted, candidate: .restricted))
    }

    @Test("compile rejects traversable roots")
    func compileRejectsTraversal() {
        let enforcer = BootstrapSandboxEnforcer()
        #expect(throws: SandboxError.self) {
            try enforcer.compile(mode: .readOnly, roots: [URL(fileURLWithPath: "/safe/..")], capabilities: [])
        }
    }

    @Test("compile accepts clean roots and apply reports unsupported")
    func compileAndApply() async throws {
        let enforcer = BootstrapSandboxEnforcer()
        let profile = try enforcer.compile(
            mode: .readOnly,
            roots: [URL(fileURLWithPath: "/safe")],
            capabilities: [.fileSystemWrite, .openGrokHomeAccess]
        )
        #expect(profile.mode == .readOnly)
        #expect(profile.capabilities.contains(.openGrokHomeAccess))
        do {
            try await enforcer.apply(profile)
            Issue.record("Expected unsupported")
        } catch SandboxError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
