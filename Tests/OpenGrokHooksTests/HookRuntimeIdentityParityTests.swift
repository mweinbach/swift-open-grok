import Foundation
import OpenGrokHooks
import OpenGrokWorkspace
import Testing

@Suite("Authentic hook runtime identity")
struct HookRuntimeIdentityParityTests {
    private var ambientSpoofs: [String: String] {
        [
            "GROK_HOOK_EVENT": "ambient-event",
            "GROK_HOOK_NAME": "ambient-name",
            "GROK_SESSION_ID": "ambient-session",
            "GROK_WORKSPACE_ROOT": "/ambient/workspace",
            "CLAUDE_PROJECT_DIR": "/ambient/project",
            "PLUGIN_ROOT": "/actual/plugin",
        ]
    }

    @Test("file and agent hook configuration defer every runner-owned ambient identity")
    func configurationDefersAmbientIdentity() throws {
        let document = #"""
        {
          "hooks": {
            "PreToolUse": [{"hooks": [
              {
                "type": "command",
                "command": "${PLUGIN_ROOT}/${GROK_SESSION_ID}/$GROK_HOOK_NAME/${CLAUDE_PROJECT_DIR:-.}",
                "env": {
                  "GROK_SESSION_ID": "spoofed-session",
                  "GROK_HOOK_NAME": "spoofed-name",
                  "PLUGIN_ROOT": "/owned/plugin"
                }
              },
              {
                "type": "http",
                "url": "https://${GROK_SESSION_ID}/$GROK_HOOK_EVENT?root=${GROK_WORKSPACE_ROOT}&project=${CLAUDE_PROJECT_DIR}",
                "env": {"GROK_WORKSPACE_ROOT": "/spoofed/workspace"}
              }
            ]}]
          }
        }
        """#
        let parsed = parseHookFile(
            document,
            path: URL(fileURLWithPath: "/tmp/agent-hooks.json"),
            environment: ambientSpoofs
        )

        #expect(parsed.errors.isEmpty)
        #expect(parsed.specs.count == 2)
        let command = try #require(parsed.specs.first { $0.handlerType == .command })
        #expect(command.command ==
            "/owned/plugin/${GROK_SESSION_ID}/$GROK_HOOK_NAME/${CLAUDE_PROJECT_DIR:-.}")
        #expect(command.extraEnvironment["GROK_SESSION_ID"] == nil)
        #expect(command.extraEnvironment["GROK_HOOK_NAME"] == nil)

        let http = try #require(parsed.specs.first { $0.handlerType == .http })
        #expect(http.url ==
            "https://${GROK_SESSION_ID}/$GROK_HOOK_EVENT?root=${GROK_WORKSPACE_ROOT}&project=${CLAUDE_PROJECT_DIR}")
        #expect(http.extraEnvironment["GROK_WORKSPACE_ROOT"] == nil)
    }

    @Test("runner-variable skipping preserves hook-owned values, shell modifiers, and positional parameters")
    func expansionPreservesShellSemantics() {
        let deferred = expandHookEnvironmentSkippingRunnerVariables(
            "$GROK_SESSION_ID/${CLAUDE_PROJECT_DIR:-.}/$1/$PLUGIN_ROOT",
            extra: [:],
            environment: ambientSpoofs.merging(["1": "spoofed-positional"]) { _, new in new }
        )
        #expect(deferred == "$GROK_SESSION_ID/${CLAUDE_PROJECT_DIR:-.}/$1//actual/plugin")

        let owned = expandHookEnvironmentSkippingRunnerVariables(
            "${GROK_SESSION_ID}/$PLUGIN_ROOT",
            extra: ["GROK_SESSION_ID": "hook-owned-session"],
            environment: ambientSpoofs
        )
        #expect(owned == "hook-owned-session//actual/plugin")
    }

    @Test("HTTP hook URL expands authentic runtime identity before SSRF validation")
    func httpRuntimeIdentityOverridesAmbientAndHookSpoofs() async throws {
        let source = "https://${GROK_SESSION_ID}/${GROK_HOOK_EVENT}/${GROK_HOOK_NAME}"
            + "?root=${GROK_WORKSPACE_ROOT}&project=${CLAUDE_PROJECT_DIR}"
        let spec = HookSpec(
            name: "agent:researcher/hook",
            event: .preToolUse,
            handlerType: .http,
            url: source,
            urlRaw: source,
            timeoutMs: 100,
            sourceDirectory: URL(fileURLWithPath: "/tmp"),
            extraEnvironment: [
                "GROK_SESSION_ID": "spoofed.example.com",
                "GROK_HOOK_EVENT": "spoofed-event",
                "GROK_HOOK_NAME": "spoofed-hook",
                "GROK_WORKSPACE_ROOT": "/spoofed/root",
                "CLAUDE_PROJECT_DIR": "/spoofed/project",
            ]
        )
        let envelope = HookEventEnvelope(
            hookEventName: .preToolUse,
            sessionId: "10.0.0.1",
            cwd: "/trusted/workspace/nested",
            workspaceRoot: "/trusted/workspace",
            payload: ["agentType": .string("researcher")]
        )
        let invocation = await HookRunner.run(
            spec: spec,
            envelope: envelope,
            context: HookRunContext(
                sessionId: "10.0.0.1",
                workspaceRoot: URL(fileURLWithPath: "/trusted/workspace"),
                environment: ambientSpoofs
            ),
            mode: .tool
        )

        guard case .failed(let reason) = invocation.result else {
            Issue.record("private authentic session host escaped SSRF validation")
            return
        }
        #expect(reason.contains("SSRF"))
        #expect(invocation.httpInfo?.url ==
            "https://10.0.0.1/pre_tool_use/agent:researcher/hook"
            + "?root=/trusted/workspace&project=/trusted/workspace")
        #expect(invocation.httpInfo?.rawURL == source)
    }

    @Test("hook payload cannot replace authentic session, workspace, or cwd metadata")
    func payloadCannotOverrideEnvelopeIdentity() throws {
        let envelope = HookEventEnvelope(
            hookEventName: .preToolUse,
            sessionId: "actual-agent-session",
            cwd: "/trusted/workspace/child",
            workspaceRoot: "/trusted/workspace",
            payload: [
                "sessionId": .string("spoofed-session"),
                "cwd": .string("/spoofed/cwd"),
                "workspaceRoot": .string("/spoofed/workspace"),
                "agentType": .string("researcher"),
            ]
        )
        let object = try #require(try JSONSerialization.jsonObject(
            with: envelope.jsonData()
        ) as? [String: Any])
        #expect(object["sessionId"] as? String == "actual-agent-session")
        #expect(object["cwd"] as? String == "/trusted/workspace/child")
        #expect(object["workspaceRoot"] as? String == "/trusted/workspace")
        #expect(object["agentType"] as? String == "researcher")
    }

    #if !os(Windows)
    @Test("the live permission gate executes agent hooks with authentic process and stdin identity")
    func liveAgentGateReceivesAuthenticIdentity() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-authentic-hook-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let capture = workspace.appendingPathComponent("hook-envelope.json")
        let command = #"/bin/cat > "\#(capture.path)"; printf '{"decision":"deny","reason":"%s|%s|%s|%s|%s"}' "$GROK_SESSION_ID" "$GROK_HOOK_EVENT" "$GROK_HOOK_NAME" "$GROK_WORKSPACE_ROOT" "$CLAUDE_PROJECT_DIR""#
        let source = HookJSONValue.object([
            "PreToolUse": .array([.object([
                "hooks": .array([.object([
                    "type": .string("command"),
                    "command": .string(command),
                    "env": .object([
                        "GROK_SESSION_ID": .string("malicious-config-session"),
                        "GROK_WORKSPACE_ROOT": .string("/malicious/config"),
                    ]),
                ])]),
            ])]),
        ])
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in ambientSpoofs { environment[key] = value }
        let parsed = parseHooksFromValue(
            source,
            sourceName: "agent:researcher",
            sourceDirectory: workspace,
            sourcePath: workspace.appendingPathComponent("agent.json"),
            environment: environment
        )
        #expect(parsed.errors.isEmpty)
        let spec = try #require(parsed.specs.first)
        #expect(spec.command?.contains("$GROK_SESSION_ID") == true)
        let gate = HookPermissionGate(
            dispatcher: HookDispatcher(registry: HookRegistry(specs: [spec]), disabledNames: []),
            context: HookSessionContext(
                sessionId: "actual-agent-session",
                workspaceRoot: workspace,
                cwd: workspace.appendingPathComponent("agent-cwd").path,
                environment: environment
            )
        )

        let decision = await gate.runPreToolUse(
            toolName: "read_file",
            toolCallId: "actual-call",
            access: .read(workspace.appendingPathComponent("document.txt").path),
            permissionMode: "default"
        )
        guard case .deny(let reason, let hookName) = decision else {
            Issue.record("the live permission gate failed to execute the identity-checking hook")
            return
        }
        #expect(hookName == spec.name)
        #expect(reason == "actual-agent-session|pre_tool_use|\(spec.name)|\(workspace.path)|\(workspace.path)")

        let payload = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: capture)
        ) as? [String: Any])
        #expect(payload["sessionId"] as? String == "actual-agent-session")
        #expect(payload["cwd"] as? String == workspace.appendingPathComponent("agent-cwd").path)
        #expect(payload["workspaceRoot"] as? String == workspace.path)
        #expect(payload["toolName"] as? String == "read_file")
        #expect(payload["toolUseId"] as? String == "actual-call")
    }
    #endif
}
