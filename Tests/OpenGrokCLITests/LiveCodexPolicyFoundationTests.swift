import Foundation
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

@Suite("Live Codex execution-policy foundation")
struct LiveCodexPolicyFoundationTests {
    private let workspace = URL(fileURLWithPath: "/tmp/open-grok-codex-policy")

    @Test("a requested but unenforced sandbox is never reported as applied")
    func unappliedSandboxIsReportedTruthfully() throws {
        let permissions = try #require(LiveToolExecutor.codexPermissions(
            provider: .codex,
            sandbox: LiveSandboxDecision(
                profileName: "strict",
                mode: .readOnly,
                enforced: false
            ),
            workingDirectory: workspace,
            environment: [:],
            alwaysApprove: false,
            autoReviewEnabled: false
        ))

        #expect(permissions.sandbox == "none")
        #expect(permissions.sandboxMode == "danger-full-access")
        #expect(permissions.sandboxProfile == nil)
        #expect(permissions.writableRoots.isEmpty)
        #expect(permissions.approvalPolicy == .onRequest)
    }

    @Test("non-Codex providers never inherit Codex execution policy")
    func otherProvidersNeverInheritCodexPolicy() {
        let permissions = LiveToolExecutor.codexPermissions(
            provider: .xai,
            sandbox: LiveSandboxDecision(profileName: "off", mode: .none, enforced: false),
            workingDirectory: workspace,
            environment: [:],
            alwaysApprove: true,
            autoReviewEnabled: true
        )
        #expect(permissions == nil)
    }

    @Test("actual approval and auto-review modes are reflected independently")
    func approvalModesRemainIndependent() throws {
        let permissions = try #require(LiveToolExecutor.codexPermissions(
            provider: .codex,
            sandbox: LiveSandboxDecision(profileName: "off", mode: .none, enforced: false),
            workingDirectory: workspace,
            environment: [:],
            alwaysApprove: true,
            autoReviewEnabled: true
        ))

        #expect(permissions.approvalPolicy == .never)
        #expect(permissions.autoReviewEnabled)
    }

    @Test("the live mapper forwards finalized tool arguments as nonterminal readiness")
    func finalizedArgumentsRemainNonterminal() {
        let action = LiveSamplingStreamMapper.map(.toolCallArgumentsComplete(
            requestId: .random(),
            toolIndex: 2,
            id: "call-2",
            name: "apply_patch"
        ))

        #expect(action == .emit(.toolCallArgumentsComplete(
            toolIndex: 2,
            id: "call-2",
            name: "apply_patch"
        )))
    }
}
