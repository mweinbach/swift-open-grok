// CollaborationToolGateTests.swift
//
// The collaboration tools are locked to subagent enablement: present exactly
// when `task` is, absent when it is not.
//
// Rust provenance (pin `9ed09e2a`):
//   * crates/codegen/xai-grok-agent/src/builder.rs:839-897 (commit 7957721e,
//     reformatted by cfa55b25) — the strip/append block.
//   * crates/codegen/xai-grok-agent/src/builder.rs:1802-1813 (commit ad95b111)
//     — `assert_eq!(names.contains(&collaboration_tool), *subagents)` for each
//     of the four tool names, which this suite mirrors.
//   * crates/codegen/xai-grok-tools/src/implementations/grok_build/task/types.rs:1387-1424
//     — nested-spawn stripping keeps the mailbox: "spawn tools must go,
//     mailbox collaboration must remain".

import Foundation
import OpenGrokToolTypes
import Testing

@testable import OpenGrokSubagentResolution

@Suite("CollaborationToolGate")
struct CollaborationToolGateTests {
    private let collaborationNames = ["list_agents", "send_message", "followup_task", "wait_agent"]

    private var baseline: [String] {
        [
            "read_file", "grep", "run_terminal_command",
            // `spawn_subagent` is this product's name for the `task` surface;
            // both spellings are gated (`isNestedSpawnTool`), so the baseline
            // carries both.
            "spawn_subagent", "task", "agent_swarm", "workflow",
            "get_task_output", "kill_task",
        ] + collaborationNames
    }

    @Test("collaboration tool presence tracks subagents_enabled")
    func presenceTracksEnablement() {
        for enabled in [true, false] {
            let names = applySubagentEnablement(toolNames: baseline, subagentsEnabled: enabled)
            for tool in collaborationNames {
                #expect(
                    names.contains(tool) == enabled,
                    "\(tool) presence should match subagents_enabled=\(enabled); got \(names)"
                )
            }
            // The three orchestration surfaces are stripped together with the
            // mailbox, and each by its own id.
            for surface in AgentOrchestrationSurface.allCases {
                #expect(names.contains(surface.toolID) == enabled)
            }
            #expect(names.contains("spawn_subagent") == enabled)
            // Non-subagent tools are untouched either way.
            #expect(names.contains("read_file"))
            #expect(names.contains("run_terminal_command"))
        }
    }

    @Test("enabling backfills collaboration tools a toolset omitted")
    func enablingBackfillsMissingTools() {
        let sparse = ["read_file", "spawn_subagent"]
        let names = applySubagentEnablement(toolNames: sparse, subagentsEnabled: true)
        #expect(names.prefix(2) == ["read_file", "spawn_subagent"])
        for tool in collaborationNames {
            #expect(names.contains(tool))
        }
        // Idempotent: a second pass adds nothing.
        #expect(applySubagentEnablement(toolNames: names, subagentsEnabled: true) == names)
    }

    @Test("qualified ids are gated by their short name")
    func qualifiedIdsAreGated() {
        let qualified = ["GrokBuild:read_file", "GrokBuild:task", "GrokBuild:send_message"]
        let stripped = applySubagentEnablement(toolNames: qualified, subagentsEnabled: false)
        #expect(stripped == ["GrokBuild:read_file"])

        // Already-present qualified ids are not duplicated by the short name.
        let kept = applySubagentEnablement(
            toolNames: ["GrokBuild:send_message"], subagentsEnabled: true
        )
        #expect(kept.filter { $0.hasSuffix("send_message") }.count == 1)
    }

    @Test("nested-spawn stripping keeps the mailbox")
    func nestedSpawnStrippingKeepsMailbox() {
        // A child agent loses the spawn surfaces but keeps peer messaging —
        // the Rust assertion at task/types.rs:1412-1421.
        for surface in AgentOrchestrationSurface.allCases {
            #expect(isNestedSpawnTool(surface.toolID))
        }
        for tool in AgentCollaborationTool.allCases {
            #expect(!isNestedSpawnTool(tool.toolID))
            #expect(isCollaborationTool(tool.toolID))
        }
    }
}
