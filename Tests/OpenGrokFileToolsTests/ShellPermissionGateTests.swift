// ShellPermissionGateTests.swift
//
// `run_terminal_cmd` used to dispatch straight to the shell runtime with no
// permission check: no deny rules, no PreToolUse hooks, no modal. It now goes
// through the same `PermissionPipeline` the file tools use, so these tests
// drive that pipeline with a `.bash` access in both directions.

import Foundation
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing
@testable import OpenGrokFileTools

/// Records what it was asked and answers with a fixed decision.
private actor RecordingPrompter: PermissionPrompter {
    private(set) var prompted: [String] = []
    private let answer: PermissionDecision

    init(answer: PermissionDecision) { self.answer = answer }

    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        prompted.append(access.detail ?? "")
        return answer
    }

    func recorded() -> [String] { prompted }
}

private struct DenyingHook: PreToolUseHookRunner {
    func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        .deny(reason: "blocked by policy", hookName: "test-hook")
    }
}

private func bashRequest(_ command: String) -> PrepareToolAccessRequest {
    PrepareToolAccessRequest(
        access: .bash(command),
        toolName: "run_terminal_cmd",
        toolCallId: "call-1"
    )
}

@Suite("run_terminal_cmd permission gate")
struct ShellPermissionGateTests {
    private func resolved(_ rules: [PermissionRule]) -> ResolvedPermissions {
        ResolvedPermissions(config: PermissionConfig(rules: rules, promptPolicy: .ask))
    }

    @Test("a config deny rule stops the command")
    func denyRuleBlocks() async {
        let pipeline = FileToolSession.makePipeline(
            policy: .prompt(RecordingPrompter(answer: .allow)),
            workspaceRoot: "/work",
            resolved: resolved([
                PermissionRule(action: .deny, tool: .bash, pattern: "rm", source: .config)
            ])
        )

        let prepared = await pipeline.prepare(bashRequest("rm -rf /"))
        #expect(prepared.mayDispatch == false)
        guard case .policyDeny = prepared.decision else {
            Issue.record("expected a policy deny, got \(prepared.decision)")
            return
        }
    }

    @Test("a command outside the deny rule still dispatches")
    func unrelatedCommandAllowed() async {
        let pipeline = FileToolSession.makePipeline(
            policy: .prompt(RecordingPrompter(answer: .allow)),
            workspaceRoot: "/work",
            resolved: resolved([
                PermissionRule(action: .deny, tool: .bash, pattern: "rm", source: .config)
            ])
        )

        let prepared = await pipeline.prepare(bashRequest("ls -la"))
        #expect(prepared.mayDispatch)
    }

    @Test("an allow rule dispatches without prompting")
    func allowRuleSkipsPrompt() async {
        let prompter = RecordingPrompter(answer: .reject("should not be asked"))
        let pipeline = FileToolSession.makePipeline(
            policy: .prompt(prompter),
            workspaceRoot: "/work",
            resolved: resolved([
                PermissionRule(action: .allow, tool: .bash, pattern: "npm run build", source: .config)
            ])
        )

        let prepared = await pipeline.prepare(bashRequest("npm run build"))
        #expect(prepared.mayDispatch)
        #expect(await prompter.recorded().isEmpty)
    }

    @Test("an ask rule reaches the prompter, and a denial stops the command")
    func askRuleRoutesToPrompter() async {
        let prompter = RecordingPrompter(answer: .reject("user said no"))
        let pipeline = FileToolSession.makePipeline(
            policy: .prompt(prompter),
            workspaceRoot: "/work",
            resolved: resolved([
                PermissionRule(action: .ask, tool: .bash, pattern: "git push", source: .config)
            ])
        )

        let prepared = await pipeline.prepare(bashRequest("git push origin main"))
        #expect(prepared.mayDispatch == false)
        #expect(await prompter.recorded() == ["git push origin main"])
    }

    @Test("a PreToolUse hook deny stops the command before it runs")
    func hookDenyBlocks() async {
        let pipeline = FileToolSession.makePipeline(
            policy: .prompt(RecordingPrompter(answer: .allow)),
            workspaceRoot: "/work",
            hooks: DenyingHook(),
            resolved: resolved([])
        )

        let prepared = await pipeline.prepare(bashRequest("echo hi"))
        #expect(prepared.mayDispatch == false)
        #expect(prepared.source == .preToolUseHook)
    }

    @Test("an Edit deny rule cannot be bypassed by writing through the shell")
    func shellFileAccessEscalates() async {
        let pipeline = FileToolSession.makePipeline(
            policy: .prompt(RecordingPrompter(answer: .reject("denied at prompt"))),
            workspaceRoot: "/work",
            resolved: resolved([
                PermissionRule(action: .deny, tool: .edit, pattern: "/work/.env", source: .config)
            ])
        )

        // No bash rule matches `tee`, but the shell file-access scanner sees the
        // write target and escalates it against the Edit deny rule.
        let prepared = await pipeline.prepare(bashRequest("echo pwned | tee /work/.env"))
        #expect(prepared.mayDispatch == false)
    }

    @Test("an admin YOLO pin survives the OPENGROK_ALLOW_WRITES bypass")
    func yoloPinOutranksAllowAll() async {
        var pinned = ResolvedPermissions(
            config: PermissionConfig(rules: [
                PermissionRule(action: .deny, tool: .bash, pattern: "rm", source: .systemRequirements)
            ])
        )
        pinned.yoloPinReason = "managed policy"

        let pipeline = FileToolSession.makePipeline(
            policy: .allowAll,
            workspaceRoot: "/work",
            resolved: pinned
        )

        let prepared = await pipeline.prepare(bashRequest("rm -rf /"))
        #expect(prepared.mayDispatch == false)
    }

    @Test("OPENGROK_ALLOW_WRITES does not override an explicit deny rule")
    func blanketApprovalRespectsDenyRules() async {
        // Blanket approval maps to yolo, which the engine evaluates after
        // deny/ask — so a user who asked for both gets the stricter one.
        let pipeline = FileToolSession.makePipeline(
            policy: .allowAll,
            workspaceRoot: "/work",
            resolved: resolved([
                PermissionRule(action: .deny, tool: .bash, pattern: "rm", source: .config)
            ])
        )

        let denied = await pipeline.prepare(bashRequest("rm -rf /"))
        #expect(denied.mayDispatch == false)

        // Everything the deny rule does not name still runs without prompting.
        let allowed = await pipeline.prepare(bashRequest("echo hi"))
        #expect(allowed.mayDispatch)
    }

    @Test("with no resolved policy blanket approval still allows everything")
    func blanketApprovalWithoutPolicy() async {
        let pipeline = FileToolSession.makePipeline(
            policy: .allowAll,
            workspaceRoot: "/work"
        )
        let prepared = await pipeline.prepare(bashRequest("rm -rf /"))
        #expect(prepared.mayDispatch)
    }

    @Test("with no resolved policy the preset still governs")
    func presetWithoutResolvedPolicy() async {
        let pipeline = FileToolSession.makePipeline(
            policy: .denyMutations,
            workspaceRoot: "/work"
        )

        let edit = await pipeline.prepare(PrepareToolAccessRequest(
            access: .edit("/work/a.txt"),
            toolName: "write",
            toolCallId: "c"
        ))
        #expect(edit.mayDispatch == false)
    }

    @Test("additionalDirectories widen the session's allowed roots")
    func additionalDirectoriesWidenRoots() {
        var resolved = ResolvedPermissions()
        resolved.additionalDirectories = ["/extra/docs"]

        let resources = FileToolSession.makeResources(
            workspaceRoot: "/work",
            sessionId: "s",
            resolved: resolved
        )
        #expect(resources.allowedRoots.contains("/work"))
        #expect(resources.allowedRoots.contains("/extra/docs"))
    }
}
