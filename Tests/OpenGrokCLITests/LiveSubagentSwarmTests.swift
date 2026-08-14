// LiveSubagentSwarmTests.swift
//
// `agent_swarm` through the LIVE seam (AGENTS.md §3): the composition the
// executable runs — `makeSessionFoundation`, the real production sampler
// factory against the mock inference server, and real `LiveToolExecutor`
// dispatch — plus unit pins on the planner, the env grammar, and the XML
// renderer, each mirroring the upstream test of the same behavior
// (agent_swarm/mod.rs tests, pin 650c1db7).
//
// Covered, in order:
//   * advertisement: `agent_swarm` reaches the model exactly when the
//     spawn surface does (builder.rs:848-869; `requires_expr` demands the
//     Task tool, agent_swarm/mod.rs:237-239), with the upstream description
//     pins;
//   * planner/env/XML unit pins with byte-identical error copy;
//   * end-to-end: one `agent_swarm` call spawns a real cohort whose member
//     turns run against the mock server, members cannot see any spawn
//     surface (the flat-tree strip), and the results aggregate into the
//     `<agent_swarm_result>` shape in slot order;
//   * the orchestration wait: raised while the cohort runs, restored after,
//     and a cancelled swarm kills every member at the host;
//   * `resume_agent_ids`: a completed member's transcript seeds the resumed
//     member, `mode="resume"` lands in the XML;
//   * resume cwd: `resume_agent_ids` inherits a custom-cwd source child's
//     effective directory (same-process bookkeeping; swarm schema has no
//     per-member cwd of its own); recorded-but-missing worktree selects
//     Shared/parent over a still-existing childCWD (pure pin — same helpers
//     as spawn);
//   * fail-fast validation copy through the live dispatch.

import Foundation
import Testing
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokTestSupport
import OpenGrokToolTypes
@testable import OpenGrokCLI

// MARK: - Fixture (the spawn-test fixture, file-private there)

private struct SwarmFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init(extraEnvironment: [String: String] = [:], userConfig: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-swarm-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        var config = """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """
        if let userConfig {
            config += "\n\n" + userConfig
        }
        try config.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path] + arguments
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }

    func makeFoundation(_ arguments: [String] = ["--model", "grok-4.5"]) async throws
        -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: launchOptions(arguments),
            context: context(),
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: OpenGrokLiveSampler.production(configuration:)
            )
        )
    }

    func responsesRequests() -> [LogEntry] {
        server.requests().filter { $0.method == "POST" && $0.path.contains("responses") }
    }

    static func bodyText(_ entry: LogEntry) -> String {
        (try? entry.body?.encodeString()) ?? ""
    }
}

private func toolNames(in entry: LogEntry) -> [String] {
    entry.body?["tools"].arrayValue?.compactMap { $0["name"].stringValue } ?? []
}

/// `pwd`-equivalent absolute path. Foundation's `resolvingSymlinksInPath` leaves
/// the macOS firmlink `/var` → `/private/var` alone; shell `pwd` and
/// `PathSecurity.canonicalize` (`realpath`) physicalize it.
private func physicalPath(_ url: URL) throws -> String {
    try PathSecurity.canonicalize(url).path
}

/// Await `toolExecutor.shutdown` after `operation` succeeds or throws.
/// Scoped to the resumed-CWD test — historical suites keep their fire-and-forget
/// `defer { Task { … } }` so this change stays local.
private func withAwaitedToolExecutorShutdown(
    _ foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await foundation.toolExecutor.shutdown()
        throw error
    }
    await foundation.toolExecutor.shutdown()
}

/// Decoded string leaves from a logged Responses body.
///
/// `SwarmFixture.bodyText` re-encodes via `JSONSerialization`, which escapes
/// `/` as `\/`. Searching that raw text for absolute paths therefore fails even
/// when production emitted the correct physical path; path-identity checks must
/// run against these decoded values instead.
private func decodedBodyStrings(_ entry: LogEntry) -> [String] {
    // Encode through Data + JSONSerialization rather than naming the
    // OpenGrokTestSupport JSONValue type: that qualifier is ambiguous
    // (module enum `OpenGrokTestSupport` vs module-qualified type) once
    // OpenGrokShared's JSONValue is also in scope.
    guard let body = entry.body,
          let data = try? body.encode(),
          let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return [] }
    var out: [String] = []
    appendDecodedStrings(from: root, into: &out)
    return out
}

private func appendDecodedStrings(from value: Any, into out: inout [String]) {
    if let string = value as? String {
        out.append(string)
        return
    }
    if let items = value as? [Any] {
        for item in items {
            appendDecodedStrings(from: item, into: &out)
        }
        return
    }
    if let object = value as? [String: Any] {
        for child in object.values {
            appendDecodedStrings(from: child, into: &out)
        }
    }
}

/// `RESUME_CWD=` value from a decoded `function_call_output` / content string.
/// Only absolute shell output lines (`RESUME_CWD=/…`) count — the tool-call
/// arguments leaf also contains `RESUME_CWD=$(pwd)` and must be ignored.
private func resumeCWD(listedIn entry: LogEntry) -> String? {
    let prefix = "RESUME_CWD="
    for text in decodedBodyStrings(entry) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("RESUME_CWD=/") else { continue }
            return String(trimmed.dropFirst(prefix.count))
        }
    }
    return nil
}

private func decodedBodyContains(_ entry: LogEntry, _ needle: String) -> Bool {
    decodedBodyStrings(entry).contains { $0.contains(needle) }
}

/// Every `agent_id="…"` attribute value in an `agent_swarm_result` payload,
/// in document order.
private func agentIDs(in xml: String) -> [String] {
    xml.components(separatedBy: "agent_id=\"").dropFirst().compactMap {
        $0.components(separatedBy: "\"").first
    }
}

// MARK: - Resume cwd precedence (shared with spawn)

@Suite("agent_swarm resume cwd precedence")
struct AgentSwarmResumeCWDPrecedenceTests {
    /// Swarm resume selection uses the same helpers as spawn. A recorded
    /// worktree that is gone must not fall through to a still-existing
    /// `childCWD` (`resume_inherited_cwd` / `worktree_path.is_some()`,
    /// subagent/mod.rs:1621; `ResumeWorktreeAction::Shared`).
    @Test("missing recorded worktree selects parent over existing source childCWD")
    func missingRecordedWorktreeSelectsParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-swarm-resume-cwd-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let childCWD = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childCWD, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordedWorktree = root.appendingPathComponent("missing-wt", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: recordedWorktree.path))

        let reusable = LiveSubagentHost.resumeWorktreePath(recordedWorktree)
        #expect(reusable == nil)
        let override = LiveSubagentHost.resumeInheritedCWD(
            sourceCWD: childCWD,
            recordedWorktreePath: recordedWorktree
        )
        #expect(override == nil)
        let selected = LiveSubagentHost.resolveChildCWD(
            worktreePath: reusable,
            overrideCWD: override,
            parentCWD: parent
        )
        #expect(selected.standardizedFileURL == parent.standardizedFileURL)
    }
}

// MARK: - Planner / env / XML unit pins

@Suite("agent_swarm planner and grammar")
struct AgentSwarmPlannerTests {
    private func input(
        items: [String]? = nil,
        resumes: [(String, String)]? = nil,
        template: String? = nil
    ) -> AgentSwarmToolInput {
        AgentSwarmToolInput(
            description: "work",
            promptTemplate: template,
            items: items,
            resumeAgentIds: resumes.map { OrderedResumeAgentMap(entries: $0) }
        )
    }

    // Upstream `validation_requires_two_items_without_resume` (:950-953).
    @Test("two items are required without resumes")
    func requiresTwoItems() {
        guard case .failure(let error) = validateAndPlanSwarm(
            input(items: ["a"], template: "{{item}}")
        ) else {
            Issue.record("a one-item swarm must be rejected")
            return
        }
        #expect(error.message
            == "agent_swarm requires at least 2 items unless resume_agent_ids is supplied")
    }

    // Upstream `validation_uses_ordered_resume_prompt_mapping_exactly`
    // (:955-968): resumes first, ids trimmed, prompt bytes preserved.
    @Test("resume slots launch first with exact prompt bytes")
    func resumeSlotsFirst() throws {
        let plan = try validateAndPlanSwarm(input(
            items: ["a", "b"],
            resumes: [(" old ", "  exact resume prompt  "), ("next", "p2")],
            template: "do {{item}}"
        )).get()
        #expect(plan[0].resumeFrom == "old")
        #expect(plan[0].prompt == "  exact resume prompt  ")
        #expect(plan[0].isResume)
        #expect(plan[1].prompt == "p2")
        #expect(plan[2].item == "a")
        #expect(plan[2].prompt == "do a")
        #expect(!plan[2].isResume)
        #expect(plan.map(\.index) == [0, 1, 2, 3])
    }

    // Upstream
    // `validation_rejects_missing_template_duplicate_expansion_and_empty_resume_id`
    // (:970-975), with the byte-identical copy pinned per arm.
    @Test("missing template, duplicate expansion and empty resume ids are rejected")
    func rejectionCopy() {
        func message(_ input: AgentSwarmToolInput) -> String? {
            guard case .failure(let error) = validateAndPlanSwarm(input) else { return nil }
            return error.message
        }
        #expect(message(input(items: ["a", "b"]))
            == "prompt_template is required when items is supplied")
        #expect(message(input(items: ["a", "b"], template: "no placeholder"))
            == "prompt_template must contain literal {{item}} when items is supplied")
        #expect(message(input(items: ["a", "a"], template: "{{item}}"))
            == "prompt_template must expand to distinct prompts for each item")
        #expect(message(input(resumes: [(" ", "prompt")]))
            == "resume_agent_ids must not contain empty or placeholder agent IDs")
        #expect(message(input(items: (0..<129).map(String.init), template: "{{item}}"))
            == "agent_swarm supports at most 128 total members")
    }

    /// `.success` payload, or `.failure` surfaced as a recorded issue.
    private func cap(_ environment: [String: String]) -> Int? {
        switch swarmConcurrencyFromEnvironment(environment) {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("cap must parse: \(error.message)")
            return nil
        }
    }

    private func timeout(_ environment: [String: String]) -> UInt64? {
        switch swarmSubagentTimeoutFromEnvironment(environment) {
        case .success(let value): return value
        case .failure(let error):
            Issue.record("timeout must parse: \(error.message)")
            return nil
        }
    }

    // Upstream `positive_cap_parser_rejects_invalid_nonempty_values`
    // (:1002-1008) through the two-variable fallback grammar (:525-529).
    @Test("concurrency env grammar")
    func concurrencyEnvGrammar() {
        #expect(cap([:]) == nil)
        #expect(cap(["OPENGROK_AGENT_SWARM_MAX_CONCURRENCY": "3"]) == 3)
        #expect(cap(["OPENGROK_AGENT_SWARM_MAX_CONCURRENCY": " "]) == nil)
        #expect(cap(["KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY": "2"]) == 2)
        guard case .failure(let zero) = swarmConcurrencyFromEnvironment(
            ["OPENGROK_AGENT_SWARM_MAX_CONCURRENCY": "0"]
        ) else {
            Issue.record("zero must be rejected")
            return
        }
        #expect(zero.message
            == "OPENGROK_AGENT_SWARM_MAX_CONCURRENCY must be a positive integer when set")
        guard case .failure(let bad) = swarmConcurrencyFromEnvironment(
            ["KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY": "bad"]
        ) else {
            Issue.record("a non-integer must be rejected")
            return
        }
        #expect(bad.message
            == "KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY must be a positive integer when set")
    }

    // Upstream `subagent_timeout_from_env` arms (:531-546).
    @Test("timeout env grammar: default two hours, zero disables")
    func timeoutEnvGrammar() {
        #expect(timeout([:]) == 2 * 60 * 60 * 1_000)
        #expect(timeout(["OPENGROK_SUBAGENT_TIMEOUT_MS": "  "]) == 2 * 60 * 60 * 1_000)
        #expect(timeout(["OPENGROK_SUBAGENT_TIMEOUT_MS": "1500"]) == 1_500)
        #expect(timeout(["KIMI_SUBAGENT_TIMEOUT_MS": "800"]) == 800)
        #expect(timeout(["OPENGROK_SUBAGENT_TIMEOUT_MS": "0"]) == nil,
                "an explicit 0 disables the timeout")
        guard case .failure(let error) = swarmSubagentTimeoutFromEnvironment(
            ["OPENGROK_SUBAGENT_TIMEOUT_MS": "soon"]
        ) else {
            Issue.record("a non-integer must be rejected")
            return
        }
        #expect(error.message
            == "OPENGROK_SUBAGENT_TIMEOUT_MS must be a non-negative integer when set")
    }

    // Upstream `initial_launches_respect_cap_and_uncapped_burst` (:1010-1015).
    @Test("initial burst respects the cap and the uncapped ceiling")
    func initialBurst() {
        #expect(swarmInitialLaunchCount(total: 128, concurrencyCap: nil) == 5)
        #expect(swarmInitialLaunchCount(total: 128, concurrencyCap: 2) == 2)
        #expect(swarmInitialLaunchCount(total: 128, concurrencyCap: 99) == 5)
        #expect(swarmInitialLaunchCount(total: 3, concurrencyCap: nil) == 3)
    }

    // Upstream `xml_is_ordered_escaped_and_only_hints_incomplete_members`
    // (:1238-1279).
    @Test("XML is ordered, escaped, and only hints incomplete members")
    func xmlShape() {
        let xml = renderSwarmXML([
            SwarmMemberResult(
                index: 0, item: nil, agentID: "resume&",
                outcome: .failed, isResume: true, body: "<failure>"
            ),
            SwarmMemberResult(
                index: 1, item: "<item>", agentID: "done",
                outcome: .completed, isResume: false, body: "<&>"
            ),
        ])
        #expect(xml.hasPrefix("<agent_swarm_result>"))
        #expect(xml.contains("<summary>completed=1 failed=1 aborted=0</summary>"))
        #expect(xml.contains(
            "<resume_hint>Call agent_swarm with resume_agent_ids mapping unfinished agent_id values to continuation prompts.</resume_hint>"
        ))
        #expect(xml.contains(
            "agent_id=\"resume&amp;\" outcome=\"failed\" state=\"started\" mode=\"resume\""
        ))
        #expect(xml.contains("item=\"&lt;item&gt;\""))
        #expect(xml.contains("&lt;&amp;&gt;"))
        if let resumeAt = xml.range(of: "resume&amp;"),
           let doneAt = xml.range(of: "agent_id=\"done\"") {
            #expect(resumeAt.lowerBound < doneAt.lowerBound)
        } else {
            Issue.record("both members must render")
        }
        #expect(!xml.contains("<output>"))

        let complete = renderSwarmXML([
            SwarmMemberResult(
                index: 0, item: nil, agentID: "done",
                outcome: .completed, isResume: false, body: "ok"
            ),
        ])
        #expect(!complete.contains("resume_hint"))
    }
}

// MARK: - Advertisement

@Suite("agent_swarm advertisement", .serialized)
struct LiveAgentSwarmAdvertisementTests {
    @Test("a default session advertises agent_swarm and swarm_wait beside the spawn surface")
    func advertisesSwarmTool() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let advertised = Set(foundation.toolExecutor.tools.map(\.name))
        #expect(advertised.contains("spawn_subagent"))
        #expect(advertised.contains("agent_swarm"))
        #expect(advertised.contains("swarm_wait"))

        // The upstream description pins, from its own test
        // (`tool_description_pins_swarm_workflow_and_flat_tree`,
        // agent_swarm/mod.rs:1037-1046).
        let spec = foundation.toolExecutor.tools.first { $0.name == "agent_swarm" }
        #expect(spec?.description?.contains("literal {{item}}") == true)
        #expect(spec?.description?.contains("capped at 128") == true)
        #expect(spec?.description?.contains("only tool call") == true)
        #expect(spec?.description?.contains("Keep the tree flat") == true)
        #expect(spec?.description?.contains("reasoning_effort") == true)

        let waitSpec = foundation.toolExecutor.tools.first { $0.name == "swarm_wait" }
        #expect(waitSpec?.description?.contains("swarm_id") == true)
        #expect(waitSpec?.description?.contains("timeout_ms") == true)
    }

    @Test("--no-subagents strips agent_swarm and swarm_wait together with the spawn surface")
    func noSubagentsStripsSwarm() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--no-subagents"])
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let advertised = Set(foundation.toolExecutor.tools.map(\.name))
        #expect(!advertised.contains("agent_swarm"))
        #expect(!advertised.contains("swarm_wait"))

        // The unadvertised surface is also undispatchable — absence of the
        // tool must mean absence, not a tool that errors differently.
        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-swarm-1",
                name: "agent_swarm",
                arguments: #"{"description":"d","prompt_template":"{{item}}","items":["a","b"]}"#
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("a stripped surface must not dispatch")
            return
        }
        #expect(error.description.contains("unknown tool"))

        let waitResult = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-wait-1",
                name: "swarm_wait",
                arguments: #"{}"#
            )
        )
        guard case .failure(let waitError) = waitResult else {
            Issue.record("a stripped surface must not dispatch")
            return
        }
        #expect(waitError.description.contains("unknown tool"))
    }
}

// MARK: - Detached Swarm & Registry

@Suite("detached swarm & registry", .serialized)
struct DetachedSwarmAndRegistryTests {
    @Test("detached XML shapes matching expected summary and states")
    func detachedXMLShape() {
        let xml = renderDetachedSwarmXML(
            swarmID: "swarm-123",
            description: "test <desc>",
            expectedMembers: 3,
            slots: [
                SwarmMemberResult(
                    index: 0,
                    item: "item0",
                    agentID: "agent-0",
                    outcome: .completed,
                    isResume: false,
                    body: "all done"
                ),
                nil,
                SwarmMemberResult(
                    index: 2,
                    item: "item2",
                    agentID: "agent-2",
                    outcome: .failed,
                    isResume: true,
                    body: "failed"
                ),
            ]
        )
        #expect(xml.hasPrefix("<agent_swarm_result state=\"detached\" swarm_id=\"swarm-123\" description=\"test &lt;desc&gt;\">"))
        #expect(xml.contains("<summary>completed=1 failed=1 aborted=0 running=1 expected=3</summary>"))
        #expect(xml.contains("<detach_hint>Members keep running. Call swarm_wait with swarm_id=\"swarm-123\" to collect the full result, or keep working and wait later.</detach_hint>"))
        #expect(xml.contains("<subagent agent_id=\"agent-0\" item=\"item0\" outcome=\"completed\" state=\"started\">all done</subagent>"))
        #expect(xml.contains("<subagent index=\"1\" outcome=\"running\" state=\"running\"></subagent>"))
        #expect(xml.contains("<subagent agent_id=\"agent-2\" item=\"item2\" outcome=\"failed\" state=\"started\" mode=\"resume\">failed</subagent>"))
        #expect(xml.hasSuffix("</agent_swarm_result>"))
    }

    @Test("SwarmRegistry resolves single, explicit, missing, and ambiguous swarms")
    func registryResolution() throws {
        let registry = SwarmRegistry()
        let sessionA = "session-a"

        #expect(throws: OpenGrokShellToolRuntimeError.self) {
            _ = try registry.resolve(swarmID: nil, parentSessionID: sessionA)
        }

        let swarm1 = DetachedSwarm(
            swarmID: "swarm-1",
            description: "first",
            parentSessionID: sessionA,
            expectedMembers: 2
        )
        registry.insert(swarm1)

        let resolvedSingle = try registry.resolve(swarmID: nil, parentSessionID: sessionA)
        #expect(resolvedSingle.swarmID == "swarm-1")

        let resolvedExplicit = try registry.resolve(swarmID: "swarm-1", parentSessionID: sessionA)
        #expect(resolvedExplicit.swarmID == "swarm-1")

        #expect(throws: OpenGrokShellToolRuntimeError.self) {
            _ = try registry.resolve(swarmID: "swarm-999", parentSessionID: sessionA)
        }

        let swarm2 = DetachedSwarm(
            swarmID: "swarm-2",
            description: "second",
            parentSessionID: sessionA,
            expectedMembers: 1
        )
        registry.insert(swarm2)

        // Multiple active for sessionA -> ambiguous error when swarmID omitted
        #expect(throws: OpenGrokShellToolRuntimeError.self) {
            _ = try registry.resolve(swarmID: nil, parentSessionID: sessionA)
        }

        // But explicit succeeds
        #expect(try registry.resolve(swarmID: "swarm-2", parentSessionID: sessionA).swarmID == "swarm-2")

        // Remove swarm1
        registry.remove("swarm-1")
        #expect(try registry.resolve(swarmID: nil, parentSessionID: sessionA).swarmID == "swarm-2")
    }

    @Test("DetachedSwarm completion notification and slot collection")
    func detachedSwarmCompletion() async {
        let swarm = DetachedSwarm(
            swarmID: "s1",
            description: "desc",
            parentSessionID: "p1",
            expectedMembers: 2
        )
        #expect(!swarm.isFinished)
        #expect(swarm.takeComplete() == nil)

        swarm.store(
            index: 0,
            result: SwarmMemberResult(
                index: 0, item: "i0", agentID: "a0",
                outcome: .completed, isResume: false, body: "res0"
            )
        )
        #expect(!swarm.isFinished)
        #expect(swarm.takeComplete() == nil)

        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            swarm.store(
                index: 1,
                result: SwarmMemberResult(
                    index: 1, item: "i1", agentID: "a1",
                    outcome: .completed, isResume: false, body: "res1"
                )
            )
        }

        await swarm.waitFinished()
        #expect(swarm.isFinished)
        let complete = swarm.takeComplete()
        #expect(complete?.count == 2)
        #expect(complete?[0].body == "res0")
        #expect(complete?[1].body == "res1")
    }

    @Test("swarm_wait tool execution on detached swarm non-blocking poll and completion")
    func swarmWaitToolExecution() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        guard let host = foundation.subagentHost else {
            Issue.record("subagentHost must be present")
            return
        }

        let swarm = DetachedSwarm(
            swarmID: "test-detached-swarm",
            description: "test swarm wait",
            parentSessionID: foundation.sessionID,
            expectedMembers: 1
        )
        host.swarmRegistry.insert(swarm)

        // Poll non-blocking (timeout_ms: 0) while running
        let pollResult = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-wait-poll",
                name: "swarm_wait",
                arguments: #"{"swarm_id":"test-detached-swarm","timeout_ms":0}"#
            )
        )
        guard case .success(let output) = pollResult else {
            Issue.record("poll should succeed")
            return
        }
        #expect(output.promptText.contains("state=\"detached\""))
        #expect(output.promptText.contains("running=1"))

        // Complete the swarm
        swarm.store(
            index: 0,
            result: SwarmMemberResult(
                index: 0,
                item: "itemA",
                agentID: "agent-a",
                outcome: .completed,
                isResume: false,
                body: "finished item A"
            )
        )

        // Wait and collect completed swarm
        let waitResult = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-wait-complete",
                name: "swarm_wait",
                arguments: #"{"swarm_id":"test-detached-swarm","timeout_ms":1000}"#
            )
        )
        guard case .success(let waitOutput) = waitResult else {
            Issue.record("wait should succeed")
            return
        }
        #expect(!waitOutput.promptText.contains("state=\"detached\""))
        #expect(waitOutput.promptText.contains("<summary>completed=1 failed=0 aborted=0</summary>"))
        #expect(waitOutput.promptText.contains("finished item A"))

        // Swarm should be removed from registry on complete collection
        #expect(host.swarmRegistry.get("test-detached-swarm") == nil)
    }
}

// MARK: - End-to-end cohort

@Suite("agent_swarm end-to-end", .serialized)
struct LiveAgentSwarmEndToEndTests {
    @Test("a two-item cohort runs real member turns and aggregates in slot order")
    func cohortRunsAndAggregates() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let marker = UUID().uuidString
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(
                text: "member answer one", model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(
                text: "member answer two", model: "grok-4.5"
            ))
        )
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-swarm-1",
                name: "agent_swarm",
                arguments: #"{"description":"probe","subagent_type":"general-purpose","prompt_template":"investigate {{item}} \#(marker)","items":["alpha","beta"]}"#
            )
        )
        guard case .success(let output) = result else {
            Issue.record("swarm failed: \(result)")
            return
        }
        let xml = output.promptText
        #expect(xml.hasPrefix("<agent_swarm_result>"))
        #expect(xml.contains("<summary>completed=2 failed=0 aborted=0</summary>"))
        #expect(!xml.contains("resume_hint"), "a fully-completed swarm carries no resume hint")
        // Slot order is input order: alpha's element precedes beta's.
        if let alphaAt = xml.range(of: "item=\"alpha\""),
           let betaAt = xml.range(of: "item=\"beta\"") {
            #expect(alphaAt.lowerBound < betaAt.lowerBound)
        } else {
            Issue.record("both item attributes must render: \(xml)")
        }
        #expect(xml.contains("outcome=\"completed\" state=\"started\""))
        #expect(xml.contains("member answer one"))
        #expect(xml.contains("member answer two"))

        // Each member's own turn ran against the mock server with the
        // expanded prompt, and — the flat-tree strip
        // (handle_request.rs:121, `!is_swarm`) — no spawn surface of any
        // spelling.
        let requests = fixture.responsesRequests()
        #expect(requests.count == 2)
        let bodies = requests.map(SwarmFixture.bodyText)
        #expect(bodies.contains { $0.contains("investigate alpha \(marker)") })
        #expect(bodies.contains { $0.contains("investigate beta \(marker)") })
        for request in requests {
            let tools = toolNames(in: request)
            #expect(!tools.isEmpty)
            #expect(!tools.contains("spawn_subagent"))
            #expect(!tools.contains("task"))
            #expect(!tools.contains("agent_swarm"))
            #expect(!tools.contains("workflow"))
        }

        // Members are real children of the session: both ids are known to
        // the background-task family, in the XML's own vocabulary.
        let ids = agentIDs(in: xml)
        #expect(ids.count == 2)
        let known = await foundation.subagentHost?.knownSubagentIDs() ?? []
        #expect(Set(ids).isSubset(of: Set(known)))
    }

    @Test("resume_agent_ids continues a member's transcript with mode=\"resume\"")
    func resumeContinuesMemberTranscript() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let marker = UUID().uuidString
        for text in ["first member answer", "second member answer", "resumed member answer"] {
            try fixture.server.enqueueResponse(
                path: "/v1/responses",
                response: .sse(SseEvents.responsesApiEventsExact(text: text, model: "grok-4.5"))
            )
        }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let first = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-swarm-1",
                name: "agent_swarm",
                arguments: #"{"description":"probe","prompt_template":"probe {{item}} \#(marker)","items":["one","two"]}"#
            )
        )
        guard case .success(let firstOutput) = first else {
            Issue.record("first swarm failed: \(first)")
            return
        }
        let ids = agentIDs(in: firstOutput.promptText)
        #expect(ids.count == 2)
        guard let resumeID = ids.first else { return }

        let resumed = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-swarm-2",
                name: "agent_swarm",
                arguments: #"{"description":"probe","resume_agent_ids":{"\#(resumeID)":"continue \#(marker)"}}"#
            )
        )
        guard case .success(let resumedOutput) = resumed else {
            Issue.record("resume swarm failed: \(resumed)")
            return
        }
        #expect(resumedOutput.promptText.contains("mode=\"resume\""))
        #expect(resumedOutput.promptText.contains("<summary>completed=1 failed=0 aborted=0</summary>"))
        #expect(resumedOutput.promptText.contains("resumed member answer"))

        // The resumed member's request carries the source transcript plus
        // the continuation prompt — the continuation the tool description
        // promises.
        let requests = fixture.responsesRequests()
        #expect(requests.count == 3)
        let resumedBody = SwarmFixture.bodyText(requests[2])
        #expect(resumedBody.contains("probe one \(marker)") || resumedBody.contains("probe two \(marker)"))
        #expect(resumedBody.contains("continue \(marker)"))
    }

    /// `resume_agent_ids` can resume a completed `spawn_subagent` child that
    /// ran under a custom cwd (Rust sets swarm `cwd: None` and lets
    /// `handle_request` inherit via `select_override_cwd`). Proves the
    /// resumed member's shell tool sees the source directory — not a silent
    /// parent-workspace fallback from missing bookkeeping.
    @Test("resume_agent_ids inherits a custom-cwd source child's directory")
    func resumeInheritsCustomSourceCWD() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }

        let sourceDir = fixture.home.deletingLastPathComponent()
            .appendingPathComponent("swarm-source-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let firstPrompt = "swarm cwd source \(UUID().uuidString)"
        let resumePrompt = "swarm cwd resume \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "source child answer", model: "grok-4.5"))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                reasoning: "Checking cwd.",
                callId: "call-swarm-pwd-1",
                name: "run_terminal_cmd",
                arguments: #"{"command":"echo RESUME_CWD=$(pwd)","timeout_ms":5000}"#,
                model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "resumed swarm answer", model: "grok-4.5"))
        )

        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--yolo"])
        try await withAwaitedToolExecutorShutdown(foundation) {
            let first = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-1",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(firstPrompt)","description":"cwd source","subagent_type":"general-purpose","background":false,"cwd":"\#(sourceDir.path)"}"#
                )
            )
            guard case .success(let firstResult) = first else {
                Issue.record("source spawn failed: \(first)")
                return
            }
            guard let sourceID = firstResult.value["subagent_id"]?.stringValue else {
                Issue.record("source spawn carried no subagent_id: \(firstResult.value)")
                return
            }

            let resumed = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-swarm-resume-1",
                    name: "agent_swarm",
                    arguments: #"{"description":"cwd resume","resume_agent_ids":{"\#(sourceID)":"\#(resumePrompt)"}}"#
                )
            )
            guard case .success(let resumedOutput) = resumed else {
                Issue.record("swarm resume failed: \(resumed)")
                return
            }
            #expect(resumedOutput.promptText.contains("mode=\"resume\""))
            #expect(resumedOutput.promptText.contains("resumed swarm answer"))

            let requests = fixture.responsesRequests()
            #expect(requests.count == 3)
            // Decode string leaves first — raw `bodyText` escapes `/` as `\/`.
            // Physicalize expected dirs: macOS `pwd` prints `/private/var/...`
            // while temp URLs often stay at `/var/...`.
            let resumePath = try #require(resumeCWD(listedIn: requests[2]))
            let sourcePath = try physicalPath(sourceDir)
            let parentPath = try physicalPath(foundation.cwd)
            #expect(resumePath == sourcePath)
            #expect(resumePath != parentPath)
            #expect(!decodedBodyContains(requests[2], "RESUME_CWD=\(parentPath)"))
            #expect(decodedBodyContains(requests[2], resumePrompt))
        }
    }

    @Test("an unknown resume id fails that member, not the whole swarm")
    func unknownResumeIDFailsTheMember() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-swarm-1",
                name: "agent_swarm",
                arguments: #"{"description":"probe","resume_agent_ids":{"nosuchagent":"continue"}}"#
            )
        )
        guard case .success(let output) = result else {
            Issue.record("a member failure must not fail the tool call: \(result)")
            return
        }
        #expect(output.promptText.contains("<summary>completed=0 failed=1 aborted=0</summary>"))
        // The member body is XML-escaped inside <subagent> (apostrophes
        // become &apos;) — assert the bytes the model actually receives.
        #expect(output.promptText.contains(
            "Cannot resume from subagent &apos;nosuchagent&apos;: not found."
        ))
        #expect(output.promptText.contains("resume_hint"))
    }
}

// MARK: - Orchestration wait and cancel

@Suite("agent_swarm orchestration wait", .serialized)
struct LiveAgentSwarmOrchestrationTests {
    /// The cohort parks the turn in an orchestration wait; a cancelled
    /// swarm kills every member at the host. Members park inside a real
    /// `sleep` (their own tool call through their own clamped surface), so
    /// the cancel lands on genuinely running children.
    @Test("the wait is raised while the cohort runs and cancel kills the members")
    func orchestrationWaitAndCancel() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let marker = UUID().uuidString
        for callID in ["call-sleep-1", "call-sleep-2"] {
            try fixture.server.enqueueResponse(
                path: "/v1/responses",
                response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                    reasoning: "Working \(marker).",
                    callId: callID,
                    name: "run_terminal_cmd",
                    arguments: #"{"command":"sleep 30","timeout_ms":30000}"#,
                    model: "grok-4.5"
                ))
            )
        }
        // `--yolo` so the members' own `run_terminal_cmd` passes the
        // permission pipeline without a prompter.
        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--yolo"])
        defer { Task { await foundation.toolExecutor.shutdown() } }
        guard let host = foundation.subagentHost else {
            Issue.record("the default session must have a subagent host")
            return
        }
        #expect(host.foregroundWait.orchestrationDepth == 0)

        let executor = foundation.toolExecutor
        let sessionID = foundation.sessionID
        let cwd = foundation.cwd
        let swarmTask = Task {
            await executor.invoke(
                sessionID: sessionID,
                workingDirectory: cwd,
                call: ToolCall(
                    id: "call-swarm-1",
                    name: "agent_swarm",
                    arguments: #"{"description":"parking probe","prompt_template":"park {{item}} \#(marker)","items":["one","two"]}"#
                )
            )
        }

        // The wait must be up while the cohort is live — this is the state
        // the controller's send-now exemption reads.
        var sawWait = false
        var sawBothMembers = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if host.foregroundWait.orchestrationDepth == 1 { sawWait = true }
            let active = await host.coordinator.listActive(parentSessionID: sessionID)
            if sawWait && active.count == 2 {
                sawBothMembers = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sawWait, "the swarm must raise the orchestration depth")
        #expect(sawBothMembers, "both members must be live children of the session")

        // Cancel the turn's tool call: upstream forwards the tool
        // cancellation into every member (agent_swarm/mod.rs:381-388);
        // here structured cancellation reaches the per-member forwarders.
        swarmTask.cancel()
        let result = await swarmTask.value
        guard case .failure(.cancelled) = result else {
            Issue.record("a cancelled swarm must report cancellation, got \(result)")
            return
        }

        // Every member dies with the cohort, and the wait is restored.
        let drainDeadline = Date().addingTimeInterval(20)
        var activeCount = -1
        while Date() < drainDeadline {
            activeCount = await host.coordinator.listActive(parentSessionID: sessionID).count
            if activeCount == 0 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(activeCount == 0, "cancelling the swarm must kill every live member")
        #expect(host.foregroundWait.orchestrationDepth == 0,
                "the orchestration wait must be restored after the swarm ends")
    }
}

// MARK: - Fail-fast validation through the live dispatch

@Suite("agent_swarm validation through dispatch", .serialized)
struct LiveAgentSwarmValidationTests {
    @Test("the fail-fast ladder rejects before any child spawns, copy byte-identical")
    func failFastLadder() async throws {
        let fixture = try SwarmFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        func failure(_ arguments: String) async -> String? {
            let result = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(id: "call-\(UUID().uuidString)", name: "agent_swarm", arguments: arguments)
            )
            guard case .failure(let error) = result else { return nil }
            return error.description
        }

        #expect(await failure(#"{"description":"d","items":["a"],"prompt_template":"{{item}}"}"#)?
            .contains("agent_swarm requires at least 2 items unless resume_agent_ids is supplied") == true)
        #expect(await failure(#"{"description":"d","items":["a","b"]}"#)?
            .contains("prompt_template is required when items is supplied") == true)
        #expect(await failure(#"{"description":"d","items":["a","b"],"prompt_template":"static"}"#)?
            .contains("prompt_template must contain literal {{item}} when items is supplied") == true)
        #expect(await failure(#"{"description":"d","items":["a","b"],"prompt_template":"{{item}}","subagent_type":"nosuchagent"}"#)?
            .contains("Unknown subagent type: nosuchagent") == true)
        #expect(await failure(#"{"description":"d","items":["a","b"],"prompt_template":"{{item}}","reasoning_effort":"turbo"}"#)?
            .contains("invalid reasoning_effort \"turbo\"") == true)
        #expect(await failure(#"{"description":"d","items":["a","b"],"prompt_template":"{{item}}","model":"nosuchmodel"}"#)?
            .contains("subagent model \"nosuchmodel\" is unavailable") == true)

        // Fail-fast means fail-fast: nothing spawned, nothing sampled.
        #expect(await foundation.subagentHost?.knownSubagentIDs().isEmpty == true)
        #expect(fixture.responsesRequests().isEmpty)
    }
}
