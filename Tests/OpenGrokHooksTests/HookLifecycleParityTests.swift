import Foundation
import OpenGrokConfig
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import Testing

@Suite("Rust-compatible hook lifecycle matching")
struct HookLifecycleParityTests {
    @Test("canonical and alias registrations preserve every matcher group")
    func canonicalAndAliasGroupsAreMerged() throws {
        let document = #"""
        {
          "hooks": {
            "SubagentStop": [{"matcher":"reviewer","hooks":[{"type":"command","command":"review.sh"}]}],
            "SubagentEnd": [{"matcher":"explore","hooks":[{"type":"command","command":"explore.sh"}]}],
            "PreToolUse": [{"matcher":"Read","hooks":[{"type":"command","command":"read.sh"}]}],
            "beforeShellExecution": [{"matcher":"Bash","hooks":[{"type":"command","command":"shell.sh"}]}]
          }
        }
        """#

        let result = parseHookFile(document, path: URL(fileURLWithPath: "/tmp/lifecycle.json"))
        #expect(result.errors.isEmpty)
        #expect(result.specs.count == 4)

        let subagentHooks = result.specs.filter { $0.event == .subagentStop }
        #expect(subagentHooks.map(\.commandRaw) == ["review.sh", "explore.sh"])
        #expect(subagentHooks.map(\.name) == [
            "lifecycle:subagent_stop[0].hooks[0]",
            "lifecycle:subagent_stop[1].hooks[0]",
        ])

        let reviewer = try #require(subagentHooks.first?.matcher)
        let explorer = try #require(subagentHooks.last?.matcher)
        #expect(reviewer.isMatch("reviewer"))
        #expect(!reviewer.isMatch("explore"))
        #expect(explorer.isMatch("explore"))
        #expect(!explorer.isMatch("reviewer"))

        let toolHooks = result.specs.filter { $0.event == .preToolUse }
        #expect(toolHooks.map(\.commandRaw) == ["read.sh", "shell.sh"])
    }

    @Test("invalid subagent matchers are rejected while ignored Stop matchers survive")
    func subagentMatcherValidationDoesNotDisableSiblingGroups() throws {
        let document = #"""
        {
          "hooks": {
            "Stop": [{"matcher":"[invalid","hooks":[{"type":"command","command":"stop.sh"}]}],
            "SubagentStop": [{"matcher":"[invalid","hooks":[{"type":"command","command":"broken.sh"}]}],
            "SubagentEnd": [{"matcher":"explore","hooks":[{"type":"command","command":"valid.sh"}]}]
          }
        }
        """#

        let result = parseHookFile(document, path: URL(fileURLWithPath: "/tmp/validation.json"))
        #expect(result.errors.count == 1)
        #expect(result.specs.map(\.commandRaw) == ["stop.sh", "valid.sh"])

        let stop = try #require(result.specs.first { $0.event == .stop })
        #expect(stop.configuredMatcher == "[invalid")
        #expect(stop.matcher == nil)

        let subagent = try #require(result.specs.first { $0.event == .subagentStop })
        #expect(subagent.name == "validation:subagent_stop[1].hooks[0]")
        let matcher = try #require(subagent.matcher)
        #expect(matcher.isMatch("explore"))
    }

    @Test("canonical subagent stop aliases deduplicate identical registrations")
    func canonicalSubagentStopAliasesDeduplicateByContent() {
        let hooks: HookJSONValue = .object([
            "SubagentStop": hookGroup(matcher: "reviewer", command: "review.sh"),
            "SubagentEnd": hookGroup(matcher: "reviewer", command: "review.sh"),
        ])
        let parsed = parseHooksFromValue(hooks, sourceName: "deduplicated")
        #expect(parsed.errors.isEmpty)
        #expect(parsed.specs.count == 2)

        let registry = HookDiscovery.registryFromSpecsDeduped(parsed.specs)
        let hooksForStop = registry.hooksForCanonical(.subagentStop)
        #expect(hooksForStop.count == 1)
        #expect(hooksForStop.first?.name == "deduplicated:subagent_stop[0].hooks[0]")
    }

    @Test("subagent stop gates dispatch only hooks matching the live agent type")
    func subagentStopDispatchHonorsAgentType() async throws {
        let hooks: HookJSONValue = .object([
            "SubagentStop": hookGroup(
                matcher: "reviewer",
                command: #"printf '{"decision":"block","reason":"review required"}'"#
            ),
            "SubagentEnd": hookGroup(
                matcher: "explore",
                command: #"printf '{"decision":"block","reason":"exploration required"}'"#
            ),
        ])
        let parsed = parseHooksFromValue(
            hooks,
            sourceName: "lifecycle",
            sourceDirectory: URL(fileURLWithPath: "/tmp")
        )
        #expect(parsed.errors.isEmpty)
        #expect(parsed.specs.count == 2)

        let gate = HookPermissionGate(
            dispatcher: HookDispatcher(
                registry: HookDiscovery.registryFromSpecsDeduped(parsed.specs),
                disabledNames: []
            ),
            context: HookSessionContext(
                sessionId: "session-1",
                workspaceRoot: URL(fileURLWithPath: "/tmp")
            )
        )

        let review = await gate.runStop(
            event: .subagentStop,
            promptId: "review-turn",
            payload: [
                "subagentType": .string("reviewer"),
                "reason": .string("end_turn"),
            ]
        )
        #expect(review.blocks.map(\.reason) == ["review required"])
        #expect(review.results.count == 1)

        let exploration = await gate.runStop(
            event: .subagentStop,
            promptId: "explore-turn",
            payload: [
                "subagentType": .string("explore"),
                "reason": .string("end_turn"),
            ]
        )
        #expect(exploration.blocks.map(\.reason) == ["exploration required"])
        #expect(exploration.results.count == 1)

        let unmatched = await gate.runStop(
            event: .subagentStop,
            promptId: "other-turn",
            payload: ["subagentType": .string("other")]
        )
        #expect(unmatched.blocks.isEmpty)
        #expect(unmatched.results.isEmpty)
    }

    @Test("StopCancelled aliases load as observe hooks and match the cancellation reason")
    func stopCancelledConfigurationAndDispatch() async throws {
        for spelling in ["StopCancelled", "stop_cancelled", "stopCancelled"] {
            let hooks: HookJSONValue = .object([
                spelling: hookGroup(
                    matcher: "user_interrupt",
                    command: "printf cancelled"
                )
            ])
            let parsed = parseHooksFromValue(
                hooks,
                sourceName: "cancel",
                sourceDirectory: URL(fileURLWithPath: "/tmp")
            )
            #expect(parsed.errors.isEmpty)
            #expect(parsed.specs.count == 1)

            let spec = try #require(parsed.specs.first)
            #expect(spec.event == .stopCancelled)
            #expect(spec.timeoutMs == defaultHookTimeoutMs)
            let matcher = try #require(spec.matcher)
            #expect(matcher.isMatch("user_interrupt"))

            let gate = HookPermissionGate(
                dispatcher: HookDispatcher(registry: HookRegistry(specs: [spec]), disabledNames: []),
                context: HookSessionContext(
                    sessionId: "session-1",
                    workspaceRoot: URL(fileURLWithPath: "/tmp")
                )
            )
            let matched = await gate.dispatchObserve(
                event: .stopCancelled,
                promptId: "cancelled-turn",
                payload: [
                    "reason": .string("user_interrupt"),
                    "cancelledBy": .string("user"),
                    "subagentType": .string("explore"),
                ]
            )
            #expect(matched.map(\.state) == [.success])

            let unmatched = await gate.dispatchObserve(
                event: .stopCancelled,
                promptId: "runtime-cancelled-turn",
                payload: ["reason": .string("max_turns")]
            )
            #expect(unmatched.isEmpty)
        }
    }

    @Test("TOML StopCancelled hooks reach the session loader")
    func stopCancelledTOMLConfigurationLoadsIntoSession() throws {
        let document = try parseTOMLTable(#"hooks = { StopCancelled = [{ matcher = "user_interrupt", hooks = [{ type = "command", command = "cancel.sh" }] }] }"#)
        let result = HookSessionLoader.load(
            configDocument: .table(document),
            configPath: URL(fileURLWithPath: "/tmp/config.toml"),
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            environment: [:],
            includeFileDiscovery: false
        )

        #expect(result.errors.isEmpty)
        #expect(result.skippedEvents.isEmpty)
        let spec = try #require(result.registry.hooks(for: .stopCancelled).first)
        #expect(spec.name == "config/config:stop_cancelled[0].hooks[0]")
        let matcher = try #require(spec.matcher)
        #expect(matcher.isMatch("user_interrupt"))
        #expect(!matcher.isMatch("max_turns"))
    }

    @Test("lifecycle matchers select their event-specific payload field")
    func eventSpecificMatcherValues() {
        let sharedPayload: [String: HookJSONValue] = [
            "toolName": .string("run_terminal_command"),
            "notificationType": .string("permission_prompt"),
            "subagentType": .string("explore"),
            "source": .string("resume"),
            "reason": .string("user_interrupt"),
            "error": .string("authentication_failed"),
        ]

        let cases: [(HookEvent, String?)] = [
            (.preToolUse, "run_terminal_command"),
            (.postToolUse, "run_terminal_command"),
            (.postToolUseFailure, "run_terminal_command"),
            (.permissionDenied, "run_terminal_command"),
            (.notification, "permission_prompt"),
            (.subagentStart, "explore"),
            (.subagentStop, "explore"),
            (.sessionStart, "resume"),
            (.preCompact, "resume"),
            (.postCompact, "resume"),
            (.sessionEnd, "user_interrupt"),
            (.stopCancelled, "user_interrupt"),
            (.stopFailure, "authentication_failed"),
            (.stop, nil),
            (.userPromptSubmit, nil),
        ]

        for (event, expected) in cases {
            let envelope = HookEventEnvelope(
                hookEventName: event,
                sessionId: "session-1",
                cwd: "/tmp",
                workspaceRoot: "/tmp",
                payload: sharedPayload
            )
            #expect(envelope.matchValue == expected)
        }

        let empty = HookEventEnvelope(
            hookEventName: .subagentStop,
            sessionId: "session-1",
            cwd: "/tmp",
            workspaceRoot: "/tmp",
            payload: ["subagentType": .string(""), "reason": .string("end_turn")]
        )
        #expect(empty.matchValue == nil)
    }

    private func hookGroup(matcher: String, command: String) -> HookJSONValue {
        .array([
            .object([
                "matcher": .string(matcher),
                "hooks": .array([
                    .object([
                        "type": .string("command"),
                        "command": .string(command),
                    ])
                ]),
            ])
        ])
    }
}
