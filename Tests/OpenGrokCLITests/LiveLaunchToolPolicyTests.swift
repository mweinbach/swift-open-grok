// LiveLaunchToolPolicyTests.swift
//
// Pure resolver coverage for CLI `--tools` / `--disallowed-tools` →
// `LiveAgentToolPolicy`, plus a live-seam parse that the flags land on
// `CLIAgentOptions` and feed the same resolver (AGENTS.md §3).

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Launch tool policy resolver")
struct LiveLaunchToolPolicyTests {
    @Test("parseCommaSeparatedToolNames trims and drops empties")
    func parsesCommaList() {
        #expect(
            LiveAgentToolPolicy.parseCommaSeparatedToolNames("read_file, grep , ,run_terminal_cmd")
                == ["read_file", "grep", "run_terminal_cmd"]
        )
        #expect(LiveAgentToolPolicy.parseCommaSeparatedToolNames(nil) == nil)
        #expect(LiveAgentToolPolicy.parseCommaSeparatedToolNames("  ,  ") == [])
    }

    @Test("--tools alone allowlists those names and rejects others")
    func toolsAllowlist() throws {
        let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: "read_file,grep",
            disallowedTools: nil,
            profile: nil
        )
        let resolved = try #require(policy)
        #expect(resolved.configuredTools == ["read_file", "grep"])
        #expect(resolved.allowlist == ["read_file", "grep"])
        #expect(resolved.denylist.isEmpty)
        #expect(resolved.allows(liveToolName: "read_file"))
        #expect(resolved.allows(liveToolName: "grep"))
        #expect(!resolved.allows(liveToolName: "run_terminal_cmd"))
    }

    @Test("--disallowed-tools alone keeps wildcard configuredTools and denies listed")
    func disallowedOnly() throws {
        let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: nil,
            disallowedTools: "run_terminal_cmd",
            profile: nil
        )
        let resolved = try #require(policy)
        #expect(resolved.configuredTools == [LiveAgentToolPolicy.wildcard])
        #expect(resolved.allowlist.isEmpty)
        #expect(resolved.denylist == ["run_terminal_cmd"])
        #expect(resolved.allows(liveToolName: "read_file"))
        #expect(!resolved.allows(liveToolName: "run_terminal_cmd"))
    }

    @Test("both flags: allowlist from --tools, denylist from --disallowed-tools")
    func bothFlags() throws {
        let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: "read_file,grep,run_terminal_cmd",
            disallowedTools: "run_terminal_cmd",
            profile: nil
        )
        let resolved = try #require(policy)
        #expect(resolved.allows(liveToolName: "read_file"))
        #expect(resolved.allows(liveToolName: "grep"))
        #expect(!resolved.allows(liveToolName: "run_terminal_cmd"))
    }

    @Test("neither flag returns the profile unchanged; neither at all returns nil")
    func absentFlags() {
        #expect(
            LiveAgentToolPolicy.resolveLaunchPolicy(
                tools: nil,
                disallowedTools: nil,
                profile: nil
            ) == nil
        )
        let profile = LiveAgentToolPolicy(unrestrictedWith: .all)
        let resolved = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: nil,
            disallowedTools: nil,
            profile: profile
        )
        #expect(resolved == profile)
    }

    @Test("CLI --tools replaces profile allowlist; CLI disallowed unions with profile denylist")
    func mergesWithProfile() throws {
        let profile = LiveAgentToolPolicy(unrestrictedWith: .execute)
        // Start from unrestricted, then deny grep via a synthetic "profile"
        // denylist by resolving once with disallowed-only against unrestricted.
        let narrowed = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: nil,
            disallowedTools: "grep",
            profile: profile
        )
        let withCLI = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: "read_file,grep",
            disallowedTools: "run_terminal_cmd",
            profile: narrowed
        )
        let resolved = try #require(withCLI)
        #expect(resolved.configuredTools == ["read_file", "grep"])
        #expect(resolved.allowlist == ["read_file", "grep"])
        #expect(Set(resolved.denylist) == Set(["grep", "run_terminal_cmd"]))
        #expect(resolved.capabilityMode == .execute)
        #expect(resolved.allows(liveToolName: "read_file"))
        // In allowlist but also denylisted via profile union.
        #expect(!resolved.allows(liveToolName: "grep"))
        #expect(!resolved.allows(liveToolName: "run_terminal_cmd"))
    }

    @Test("live seam: parsed --tools/--disallowed-tools feed resolveLaunchPolicy")
    func liveSeamParseFeedsResolver() throws {
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "hi",
            "--tools", "read_file,grep",
            "--disallowed-tools", "run_terminal_cmd",
        ])
        guard case .launch(let options) = command else {
            Issue.record("expected launch command, got \(command)")
            return
        }
        #expect(options.agentOptions.tools == "read_file,grep")
        #expect(options.agentOptions.disallowedTools == "run_terminal_cmd")

        let policy = LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: options.agentOptions.tools,
            disallowedTools: options.agentOptions.disallowedTools,
            profile: nil
        )
        let resolved = try #require(policy)
        #expect(resolved.allows(liveToolName: "read_file"))
        #expect(resolved.allows(liveToolName: "grep"))
        #expect(!resolved.allows(liveToolName: "run_terminal_cmd"))
    }
}
