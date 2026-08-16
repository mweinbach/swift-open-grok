// LiveSubagentSwarm.swift
//
// `agent_swarm` — foreground, ramped parallel subagent orchestration —
// wired into the live subagent host. The Swift port of
// `xai-grok-tools/src/implementations/grok_build/agent_swarm/mod.rs`
// (pin 650c1db7), driving the SAME coordinator and the SAME `runChild`
// runner as `spawn_subagent`, so every swarm member is a real child:
// visible to `/tasks`, retrievable through `get_task_output`, killable
// through `kill_task`, and resumable through `resume_agent_ids`.
//
// Ported faithfully: the fail-fast validation ladder and its error copy,
// the 128-member cap, the 5-member initial burst with the 700 ms ramp,
// the `OPENGROK_AGENT_SWARM_MAX_CONCURRENCY` / `OPENGROK_SUBAGENT_TIMEOUT_MS`
// env grammar (with the KIMI fallbacks), per-member timeout with cancel,
// resume slots launching first with pinned prior models, slot-ordered
// aggregation, and the `<agent_swarm_result>` XML shape byte for byte.
//
// Deliberately NOT ported (recorded in the slice report): the adaptive
// rate-limit machinery (`AdaptiveCapacity` shrink/recover, `RateLimitGate`
// pacing, `SubagentStatusEvent` retry decisions, agent_swarm/mod.rs:86-203,
// 600-680) — the port's child runner has no provider rate-limit status
// channel to feed it, so a port would be a scheduler reacting to events
// that can never fire. The cost: a provider 429 fails the member instead
// of parking and retrying it; capacity never shrinks under pressure.

import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokSubagentResolution
import OpenGrokToolTypes

// MARK: - Foreground wait state

/// What the running turn is parked on — the port of the shell's
/// `BlockingWaitState` (tools/tool_context.rs:76-117). `agent_swarm` raises
/// the orchestration depth around its cohort; the interactive controller's
/// send-now path reads it and promotes the arriving prompt WITHOUT
/// cancelling the turn, because cancelling would kill every live member
/// (prompt_queue.rs:222-233).
final class LiveForegroundWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var interruptibleDepth = 0
    private var orchestrationCount = 0

    /// Interruptible waits the turn is parked in (tool_context.rs:87-94).
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return interruptibleDepth
    }

    /// Orchestration waits the turn is parked in (tool_context.rs:95-103).
    /// Non-zero means an arriving prompt must not abort the turn.
    var orchestrationDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return orchestrationCount
    }

    func enter(_ kind: ForegroundWaitKind) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .interruptible: interruptibleDepth += 1
        case .orchestration: orchestrationCount += 1
        }
    }

    func exit(_ kind: ForegroundWaitKind) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .interruptible: interruptibleDepth = max(0, interruptibleDepth - 1)
        case .orchestration: orchestrationCount = max(0, orchestrationCount - 1)
        }
    }
}

// MARK: - Swarm mode session state

/// The session's live swarm-mode tracker — the port of the `SwarmModeTracker`
/// field on `SessionActor` state (acp_session.rs:320), isolated the way the
/// session-state mutex isolates it upstream. Shared by the `/swarm` slash
/// path, the `agent_swarm` tool-trigger arm, and the turn loop's reminder
/// injection, so all three can never disagree about the session's mode.
actor LiveSwarmModeState {
    private var tracker = SwarmModeTracker()

    var enabled: Bool { tracker.enabled }
    var currentTrigger: SwarmModeTrigger? { tracker.currentTrigger }

    @discardableResult
    func enter(_ trigger: SwarmModeTrigger) -> SwarmModeTrigger {
        tracker.enter(trigger)
    }

    func exit() {
        tracker.exit()
    }

    /// Exit and report whether the mode had been on — the manual-disable arm
    /// of `SessionCommand::SetSwarmMode` needs the before-state to decide
    /// whether a `SwarmModeChanged { enabled: false }` broadcast is owed
    /// (run_loop.rs:1124-1136).
    @discardableResult
    func exitReportingChange() -> Bool {
        let wasEnabled = tracker.enabled
        tracker.exit()
        return wasEnabled
    }

    @discardableResult
    func exitIfTrigger(_ trigger: SwarmModeTrigger) -> Bool {
        tracker.exitIfTrigger(trigger)
    }

    @discardableResult
    func autoExitTurn() -> Bool {
        tracker.autoExitTurn()
    }

    /// Take both pending reminders under one isolation hop, exit first —
    /// the order `maybe_inject_swarm_reminder` reads them (reminders.rs:580-586).
    func takeReminders() -> (exit: Bool, inject: Bool) {
        (tracker.takeExitReminder(), tracker.takeReminder())
    }
}

// MARK: - Planner types

/// One planned swarm slot. Mirrors Rust `PlannedMember`
/// (agent_swarm/mod.rs:50-57); `isResume` carries `MemberMode`.
struct PlannedSwarmMember: Sendable, Equatable {
    var index: Int
    var item: String?
    var prompt: String
    var resumeFrom: String?
    var isResume: Bool
}

/// Mirrors Rust `MemberOutcome` (agent_swarm/mod.rs:59-74); raw values are
/// the rendered `outcome` attribute strings.
enum SwarmMemberOutcome: String, Sendable, Equatable {
    case completed
    case failed
    case aborted
}

/// Mirrors Rust `MemberResult` (agent_swarm/mod.rs:76-84).
struct SwarmMemberResult: Sendable, Equatable {
    var index: Int
    var item: String?
    var agentID: String
    var outcome: SwarmMemberOutcome
    var isResume: Bool
    var body: String
}

// MARK: - Validation and environment grammar

/// Fail-fast validation and slot planning: resume slots first in map order,
/// then item slots in array order. Mirrors Rust `validate_and_plan`
/// (agent_swarm/mod.rs:430-502); every error string is byte-identical.
func validateAndPlanSwarm(
    _ input: AgentSwarmToolInput
) -> Result<[PlannedSwarmMember], SubagentArgumentError> {
    let resumes = input.resumeAgentIds?.entries ?? []
    let items = input.items ?? []
    let total = resumes.count + items.count
    if total > LiveSubagentHost.swarmMaxMembers {
        return .failure(SubagentArgumentError(
            "agent_swarm supports at most \(LiveSubagentHost.swarmMaxMembers) total members"
        ))
    }
    if resumes.isEmpty && items.count < 2 {
        return .failure(SubagentArgumentError(
            "agent_swarm requires at least 2 items unless resume_agent_ids is supplied"
        ))
    }
    var itemTemplate: String?
    if !items.isEmpty {
        guard let template = input.promptTemplate else {
            return .failure(SubagentArgumentError(
                "prompt_template is required when items is supplied"
            ))
        }
        guard template.contains("{{item}}") else {
            return .failure(SubagentArgumentError(
                "prompt_template must contain literal {{item}} when items is supplied"
            ))
        }
        let expanded = Set(items.map {
            template.replacingOccurrences(of: "{{item}}", with: $0)
        })
        guard expanded.count == items.count else {
            return .failure(SubagentArgumentError(
                "prompt_template must expand to distinct prompts for each item"
            ))
        }
        itemTemplate = template
    }

    var members: [PlannedSwarmMember] = []
    members.reserveCapacity(total)
    for entry in resumes {
        guard isNotSentinel(entry.key) else {
            return .failure(SubagentArgumentError(
                "resume_agent_ids must not contain empty or placeholder agent IDs"
            ))
        }
        members.append(PlannedSwarmMember(
            index: members.count,
            item: nil,
            // Preserve user-provided prompt bytes exactly. Unlike IDs,
            // prompts are task content rather than an optional/sentinel
            // argument (agent_swarm/mod.rs:482-484).
            prompt: entry.value,
            resumeFrom: entry.key.trimmingCharacters(in: .whitespacesAndNewlines),
            isResume: true
        ))
    }
    for item in items {
        members.append(PlannedSwarmMember(
            index: members.count,
            item: item,
            prompt: itemTemplate!.replacingOccurrences(of: "{{item}}", with: item),
            resumeFrom: nil,
            isResume: false
        ))
    }
    return .success(members)
}

/// Mirrors Rust `parse_positive_value` (agent_swarm/mod.rs:512-523):
/// empty/whitespace reads as unset, anything else must parse positive.
private func parsePositiveEnvValue(
    _ name: String,
    _ value: String?
) -> Result<Int?, SubagentArgumentError> {
    guard let value else { return .success(nil) }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .success(nil) }
    guard let parsed = Int(trimmed), parsed > 0 else {
        return .failure(SubagentArgumentError(
            "\(name) must be a positive integer when set"
        ))
    }
    return .success(parsed)
}

/// `nil` means no active-member cap; the initial burst and ramp still apply.
/// Mirrors Rust `swarm_concurrency_from_env` (agent_swarm/mod.rs:525-529).
func swarmConcurrencyFromEnvironment(
    _ environment: [String: String]
) -> Result<Int?, SubagentArgumentError> {
    switch parsePositiveEnvValue(
        "OPENGROK_AGENT_SWARM_MAX_CONCURRENCY",
        environment["OPENGROK_AGENT_SWARM_MAX_CONCURRENCY"]
    ) {
    case .failure(let error): return .failure(error)
    case .success(.some(let cap)): return .success(cap)
    case .success(nil):
        return parsePositiveEnvValue(
            "KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY",
            environment["KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY"]
        )
    }
}

/// Per-member wall-clock ceiling. Absent/empty reads as the 2-hour default;
/// an explicit `0` disables the timeout. Mirrors Rust
/// `subagent_timeout_from_env` (agent_swarm/mod.rs:531-546).
func swarmSubagentTimeoutFromEnvironment(
    _ environment: [String: String]
) -> Result<UInt64?, SubagentArgumentError> {
    let value = environment["OPENGROK_SUBAGENT_TIMEOUT_MS"]
        ?? environment["KIMI_SUBAGENT_TIMEOUT_MS"]
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .success(LiveSubagentHost.swarmDefaultTimeoutMS)
    }
    guard let ms = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return .failure(SubagentArgumentError(
            "OPENGROK_SUBAGENT_TIMEOUT_MS must be a non-negative integer when set"
        ))
    }
    return .success(ms == 0 ? nil : ms)
}

// MARK: - Result XML

/// Size of the only burst the scheduler ever performs. Mirrors Rust
/// `initial_launch_count` (agent_swarm/mod.rs:693-697).
func swarmInitialLaunchCount(total: Int, concurrencyCap: Int?) -> Int {
    min(
        total,
        LiveSubagentHost.swarmInitialLaunches,
        concurrencyCap ?? LiveSubagentHost.swarmInitialLaunches
    )
}

/// Mirrors Rust `xml_escape` (agent_swarm/mod.rs:847-854) — `&` first.
private func swarmXMLEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

/// Slot-ordered aggregation the model receives back. Mirrors Rust
/// `render_xml` (agent_swarm/mod.rs:856-902) byte for byte.
func renderSwarmXML(_ results: [SwarmMemberResult]) -> String {
    let completed = results.filter { $0.outcome == .completed }.count
    let failed = results.filter { $0.outcome == .failed }.count
    let aborted = results.filter { $0.outcome == .aborted }.count
    let hasResumeTarget = results.contains {
        $0.outcome != .completed && !$0.agentID.isEmpty
    }
    var xml = "<agent_swarm_result><summary>completed=\(completed) failed=\(failed) aborted=\(aborted)</summary>"
    if hasResumeTarget {
        xml += "<resume_hint>Call agent_swarm with resume_agent_ids mapping unfinished agent_id values to continuation prompts.</resume_hint>"
    }
    for result in results {
        xml += "<subagent"
        xml += " agent_id=\"\(swarmXMLEscape(result.agentID))\""
        if let item = result.item {
            xml += " item=\"\(swarmXMLEscape(item))\""
        }
        // Only members submitted to the backend can produce a rendered
        // result. Cancellation before scheduling fails the whole tool call,
        // so the stable output state for every result is `started`.
        xml += " outcome=\"\(result.outcome.rawValue)\" state=\"started\""
        if result.isResume {
            xml += " mode=\"resume\""
        }
        xml += ">"
        xml += swarmXMLEscape(result.body)
        xml += "</subagent>"
    }
    xml += "</agent_swarm_result>"
    return xml
}

/// Partial XML returned when the cohort was detached by a mid-swarm steer.
/// Mirrors Rust `render_detached_xml` (agent_swarm/mod.rs:1045-1073).
func renderDetachedSwarmXML(
    swarmID: String,
    description: String,
    expectedMembers: Int,
    slots: [SwarmMemberResult?]
) -> String {
    let completed = slots.compactMap { $0 }.filter { $0.outcome == .completed }.count
    let failed = slots.compactMap { $0 }.filter { $0.outcome == .failed }.count
    let aborted = slots.compactMap { $0 }.filter { $0.outcome == .aborted }.count
    let running = slots.filter { $0 == nil }.count
    var xml = "<agent_swarm_result state=\"detached\" swarm_id=\"\(swarmXMLEscape(swarmID))\" description=\"\(swarmXMLEscape(description))\">"
    xml += "<summary>completed=\(completed) failed=\(failed) aborted=\(aborted) running=\(running) expected=\(expectedMembers)</summary>"
    xml += "<detach_hint>Members keep running. Call swarm_wait with swarm_id=\"\(swarmXMLEscape(swarmID))\" to collect the full result, or keep working and wait later.</detach_hint>"
    for (index, slot) in slots.enumerated() {
        if let result = slot {
            xml += "<subagent"
            xml += " agent_id=\"\(swarmXMLEscape(result.agentID))\""
            if let item = result.item {
                xml += " item=\"\(swarmXMLEscape(item))\""
            }
            xml += " outcome=\"\(result.outcome.rawValue)\" state=\"started\""
            if result.isResume {
                xml += " mode=\"resume\""
            }
            xml += ">"
            xml += swarmXMLEscape(result.body)
            xml += "</subagent>"
        } else {
            xml += "<subagent index=\"\(index)\" outcome=\"running\" state=\"running\"></subagent>"
        }
    }
    xml += "</agent_swarm_result>"
    return xml
}

// MARK: - Swarm Registry & Detached Swarm

final class SwarmRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var swarms: [String: DetachedSwarm] = [:]
    private var archived: [String: DetachedSwarm] = [:]
    private var archiveOrder: [String] = []

    init() {}

    func insert(_ swarm: DetachedSwarm) {
        lock.lock()
        defer { lock.unlock() }
        swarms[swarm.swarmID] = swarm
    }

    func get(_ swarmID: String) -> DetachedSwarm? {
        lock.lock()
        defer { lock.unlock() }
        return swarms[swarmID]
    }

    func resolve(swarmID: String?, parentSessionID: String) throws -> DetachedSwarm {
        lock.lock()
        defer { lock.unlock() }
        if let swarmID {
            guard let swarm = swarms[swarmID] else {
                throw OpenGrokShellToolRuntimeError.invalidCall("no detached swarm found with id '\(swarmID)'")
            }
            return swarm
        }
        let matching = swarms.values.filter { $0.parentSessionID == parentSessionID }
        if matching.isEmpty {
            throw OpenGrokShellToolRuntimeError.invalidCall("no detached swarms active for this session")
        }
        if matching.count > 1 {
            throw OpenGrokShellToolRuntimeError.invalidCall("multiple detached swarms active; supply swarm_id to select which to join")
        }
        return matching[0]
    }

    func remove(_ swarmID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let swarm = swarms.removeValue(forKey: swarmID) {
            archived[swarmID] = swarm
            archiveOrder.removeAll { $0 == swarmID }
            archiveOrder.append(swarmID)
            while archiveOrder.count > 32 {
                archived.removeValue(forKey: archiveOrder.removeFirst())
            }
        }
    }

    func transcriptSnapshots(parentSessionID: String) -> [LiveSwarmTranscriptSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let active = swarms.values
            .filter { $0.parentSessionID == parentSessionID }
            .map { LiveSwarmTranscriptSnapshot(swarm: $0, isActive: true) }
        let completed = archiveOrder.compactMap { archived[$0] }
            .filter { $0.parentSessionID == parentSessionID }
            .map { LiveSwarmTranscriptSnapshot(swarm: $0, isActive: false) }
        return (completed + active).sorted { $0.swarmID < $1.swarmID }
    }
}

struct LiveSwarmTranscriptSnapshot: Sendable, Equatable {
    var swarmID: String
    var description: String
    var expectedMembers: Int
    var slots: [SwarmMemberResult?]
    var isActive: Bool
    var isFinished: Bool

    init(swarm: DetachedSwarm, isActive: Bool) {
        self.swarmID = swarm.swarmID
        self.description = swarm.description
        self.expectedMembers = swarm.expectedMembers
        self.slots = swarm.snapshot()
        self.isActive = isActive
        self.isFinished = swarm.isFinished
    }
}

final class DetachedSwarm: @unchecked Sendable {
    let swarmID: String
    let description: String
    let parentSessionID: String
    let expectedMembers: Int
    private let lock = NSLock()
    private var slots: [SwarmMemberResult?]
    private var isFinishedFlag: Bool = false
    private var finishContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        swarmID: String,
        description: String,
        parentSessionID: String,
        expectedMembers: Int
    ) {
        self.swarmID = swarmID
        self.description = description
        self.parentSessionID = parentSessionID
        self.expectedMembers = expectedMembers
        self.slots = [SwarmMemberResult?](repeating: nil, count: expectedMembers)
    }

    func store(index: Int, result: SwarmMemberResult) {
        lock.lock()
        if index < slots.count {
            slots[index] = result
        }
        let allDone = !slots.contains { $0 == nil }
        var toResume: [CheckedContinuation<Void, Never>] = []
        if allDone && !isFinishedFlag {
            isFinishedFlag = true
            toResume = finishContinuations
            finishContinuations.removeAll()
        }
        lock.unlock()
        for cont in toResume {
            cont.resume()
        }
    }

    func snapshot() -> [SwarmMemberResult?] {
        lock.lock()
        defer { lock.unlock() }
        return slots
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinishedFlag
    }

    func takeComplete() -> [SwarmMemberResult]? {
        lock.lock()
        defer { lock.unlock() }
        if slots.contains(where: { $0 == nil }) {
            return nil
        }
        return slots.compactMap { $0 }
    }

    func waitFinished() async {
        if isFinished { return }
        await withCheckedContinuation { cont in
            lock.lock()
            if isFinishedFlag {
                lock.unlock()
                cont.resume()
            } else {
                finishContinuations.append(cont)
                lock.unlock()
            }
        }
    }
}

// MARK: - The tool

extension LiveSubagentHost {
    nonisolated static let swarmToolName = "agent_swarm"
    nonisolated static let swarmWaitToolName = "swarm_wait"
    /// Rust `MAX_MEMBERS` (agent_swarm/mod.rs:34).
    nonisolated static let swarmMaxMembers = 128
    /// Rust `INITIAL_LAUNCHES` (:35).
    nonisolated static let swarmInitialLaunches = 5
    /// Rust `RAMP_INTERVAL` (:36).
    nonisolated static let swarmRampIntervalMS: UInt64 = 700
    /// Rust `DEFAULT_TIMEOUT` (:37).
    nonisolated static let swarmDefaultTimeoutMS: UInt64 = 2 * 60 * 60 * 1_000

    /// Verbatim copy of the Rust `description_template`
    /// (agent_swarm/mod.rs:214-235).
    nonisolated static let swarmToolDescription: String =
        "Launch multiple foreground subagents from one prompt template, existing agent "
        + "resumes, or both. Use agent_swarm when many subagents should run the same kind of "
        + "task over different inputs. The placeholder is exactly {{item}}. For a few "
        + "differently-shaped tasks, use ordinary task calls instead. Use resume_agent_ids to "
        + "continue unfinished or timed-out subagents by mapping each agent_id to its exact "
        + "continuation prompt, often 'continue'. You may combine resume_agent_ids with items, "
        + "but do not duplicate resumed work in items; resume slots launch first. Validation "
        + "is fail-fast before any child starts: provide at least 2 items unless "
        + "resume_agent_ids is supplied; items require prompt_template containing literal "
        + "{{item}}; expanded prompts must be distinct; and total members are capped at 128. "
        + "Pass model to run every new member on a specific available model slug (resumed "
        + "members keep their prior model); if the slug is rejected, report the error instead "
        + "of re-running the swarm on a different model. Pass reasoning_effort to select one "
        + "canonical effort for every new or resumed member. "
        + "Results return together in input slot order as agent_swarm_result XML with resume "
        + "hints for unfinished members. agent_swarm must be the only tool call in the model "
        + "response. Keep the tree flat: swarm members cannot launch further task or "
        + "agent_swarm tools."

    nonisolated static let swarmWaitToolDescription =
        "Wait for a previously detached agent_swarm cohort to finish and return its full "
        + "agent_swarm_result XML. Pass swarm_id from the detached result when more than one "
        + "swarm is outstanding; omit it when only one detached swarm is active. timeout_ms "
        + "defaults to 600000 (10 minutes); pass 0 to poll the current partial state without "
        + "blocking. A user message arriving while this wait is held detaches again so you can "
        + "keep working; call swarm_wait later to rejoin."

    nonisolated static var swarmWaitToolSpec: ToolSpec {
        ToolSpec(
            name: swarmWaitToolName,
            description: swarmWaitToolDescription,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "swarm_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Swarm id from a detached agent_swarm_result. Omit when only one detached swarm is active."
                        ),
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum wait in milliseconds. Omit for 600000 (10 min); pass 0 for a non-blocking poll."
                        ),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// The advertised spec. Parameter descriptions mirror the Rust schemars
    /// annotations on `AgentSwarmToolInput` (xai-tool-types task.rs:138-184).
    nonisolated static var swarmToolSpec: ToolSpec {
        ToolSpec(
            name: swarmToolName,
            description: swarmToolDescription,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Shared short description for every swarm member."),
                    ]),
                    "subagent_type": .object([
                        "type": .string("string"),
                        "description": .string("Name of the subagent type to launch."),
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional model slug applied to every new swarm member. If provided, it "
                            + "must resolve to one of the available model slugs, and its provider must have usable "
                            + "credentials. If omitted, members inherit the parent agent's model. Resumed members "
                            + "(resume_agent_ids) always keep their prior model. Never silently substitute a "
                            + "different model: if this slug is rejected, surface the error to the user instead of "
                            + "re-running the swarm on another model."
                        ),
                    ]),
                    "reasoning_effort": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional reasoning effort applied to every swarm member, including resumed "
                            + "members. Supported values are none, minimal, low, medium, high, xhigh, max, and ultra. "
                            + "If omitted, each member resolves effort from its subagent role or persona and then "
                            + "falls back to the parent session."
                        ),
                    ]),
                    "prompt_template": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Template used to construct each item member prompt. It must contain the "
                            + "literal `{{item}}` placeholder when `items` is supplied."
                        ),
                    ]),
                    "items": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "maxItems": .number(.int64(128)),
                        "description": .string("Ordered work items. At most 128 members are permitted in a swarm."),
                    ]),
                    "resume_agent_ids": .object([
                        "type": .string("object"),
                        "additionalProperties": .object(["type": .string("string")]),
                        "description": .string(
                            "Ordered completed child IDs to resume before launching item members. "
                            + "Each JSON-object key is a prior agent ID and its value is the exact "
                            + "prompt appended to that resumed conversation."
                        ),
                    ]),
                ]),
                "required": .array([.string("description")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// Execute one `agent_swarm` call. The validation ladder and its copy
    /// follow `AgentSwarmTool::run` (agent_swarm/mod.rs:272-410): plan
    /// fail-fast, env caps, eager type validation for new members, effort
    /// normalization, model validation — everything that can reject the
    /// call resolves before any child request reaches the coordinator.
    func runSwarm(
        args: JSONValue,
        toolCallID: String,
        rawArguments: String? = nil
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        _ = toolCallID
        guard case .object = args else {
            return .failure(.invalidCall("\(Self.swarmToolName) requires an object argument"))
        }
        var input: AgentSwarmToolInput
        do {
            input = try JSONDecoder().decode(
                AgentSwarmToolInput.self,
                from: JSONEncoder().encode(args)
            )
        } catch {
            return .failure(.invalidCall("\(Self.swarmToolName) arguments are invalid: \(error)"))
        }
        // Restore the resume map's JSON SOURCE order from the raw call
        // arguments: resumed members occupy slots in the order the model
        // wrote them (agent_swarm/mod.rs:977-990), and both the JSONValue
        // hop and Foundation's decoder lose object order.
        if let rawArguments, let resume = input.resumeAgentIds {
            input.resumeAgentIds = resume.reordered(bySourceOrderIn: rawArguments)
        }

        let members: [PlannedSwarmMember]
        switch validateAndPlanSwarm(input) {
        case .failure(let error): return .failure(.invalidCall(error.message))
        case .success(let planned): members = planned
        }
        let concurrencyCap: Int?
        switch swarmConcurrencyFromEnvironment(context.environment) {
        case .failure(let error): return .failure(.invalidCall(error.message))
        case .success(let cap): concurrencyCap = cap
        }
        let timeoutMS: UInt64?
        switch swarmSubagentTimeoutFromEnvironment(context.environment) {
        case .failure(let error): return .failure(.invalidCall(error.message))
        case .success(let timeout): timeoutMS = timeout
        }

        // Eager type validation — for the whole swarm, resume slots
        // included: the port's resume identity check requires the input
        // type to equal every source's type anyway, so an unresolvable
        // type can never produce a runnable member. (Upstream defers this
        // for resume-only swarms to per-member backend failures,
        // agent_swarm/mod.rs:316-355 — recorded divergence: this port
        // fails the call, which is fail-fast rather than fail-late.)
        let definition: AgentDefinition
        do {
            definition = try resolveAgentDefinition(
                subagentType: input.subagentType,
                context: context.definitionContext
            )
        } catch let error as ResolutionError {
            return .failure(.invalidCall(Self.validationMessage(error)))
        } catch {
            return .failure(.invalidCall("Cannot validate subagent '\(input.subagentType)'"))
        }

        // Same eager gate as the task tool: a rejected slug must reject the
        // whole swarm here, not spawn members that die at setup and
        // silently inherit the parent model (agent_swarm/mod.rs:357-375).
        let memberModel = OpenGrokToolTypes.sanitizeOptionalArg(input.model)
        let reasoningEffort: String?
        switch normalizeSubagentReasoningEffort(input.reasoningEffort) {
        case .failure(let error): return .failure(.invalidCall(error.message))
        case .success(let effort): reasoningEffort = effort
        }
        let hasNewMembers = members.contains { !$0.isResume }
        if hasNewMembers, let requested = memberModel,
           !context.modelSlugs.contains(requested) {
            return .failure(.invalidCall("subagent model \"\(requested)\" is unavailable"))
        }

        // One resolution for every new member: swarm input carries no
        // per-member capability/isolation/cwd, so the resolved runtime and
        // the stripped definition are cohort-wide facts. The strip keeps
        // the tree flat (`allowNestedSubagents: false`), the structural
        // half of upstream's `!is_swarm` gate (handle_request.rs:121).
        var runtime = resolveRuntimeConfig(
            subagentType: input.subagentType,
            overrides: SubagentRuntimeOverrides(
                model: memberModel,
                reasoningEffort: reasoningEffort,
                allowNestedSubagents: false
            ),
            roles: [:],
            // The same per-spawn map the task path feeds: swarm members go
            // through the identical shell resolution upstream
            // (handle_request.rs:300-306 receives `ctx.subagent_personas`
            // for every owner, swarm included). Swarm input carries no
            // persona name at the pin (agent_swarm/mod.rs:731 —
            // `persona: None`), so this map is consulted only if that ever
            // changes; feeding `[:]` here would make that change silently
            // resolve nothing.
            personas: effectiveSpawnPersonas(),
            cwd: context.workingDirectory,
            definition: definition,
            parent: ParentRuntimeDefaults(
                model: context.parentModel,
                capabilityMode: context.parentCapabilityCeiling
            )
        )
        // Any persona error aborts (handle_request.rs:308-315), same arm as
        // the task path — not only the fatal file-I/O case.
        if let personaError = runtime.personaError {
            return .failure(.invalidCall(personaError))
        }
        runtime.capabilityMode = intersectCapabilityModes(
            requested: runtime.capabilityMode,
            ceiling: definition.capabilityMode.map { mode in
                switch mode {
                case .readOnly: return OpenGrokSubagentResolution.SubagentCapabilityMode.readOnly
                case .readWrite: return .readWrite
                case .execute: return .execute
                case .all: return .all
                }
            }
        )
        var strippedDefinition = definition
        applyChildToolPolicy(
            definition: &strippedDefinition,
            capabilityMode: runtime.capabilityMode,
            allowNestedSubagents: false
        )
        strippedDefinition.capabilityMode = runtime.capabilityMode.map { mode in
            switch mode {
            case .readOnly: return AgentCapabilityMode.readOnly
            case .readWrite: return AgentCapabilityMode.readWrite
            case .execute: return AgentCapabilityMode.execute
            case .all: return AgentCapabilityMode.all
            }
        }

        let swarmID = UUID().uuidString.lowercased()
        let detachedSwarm = DetachedSwarm(
            swarmID: swarmID,
            description: input.description,
            parentSessionID: context.sessionID,
            expectedMembers: members.count
        )
        swarmRegistry.insert(detachedSwarm)

        // Orchestration, not interruptible: a prompt arriving mid-swarm
        // merges as an interjection and detaches the cohort into SwarmRegistry.
        foregroundWait.enter(.orchestration)
        defer { foregroundWait.exit(.orchestration) }

        let results = await runSwarmScheduler(
            members: members,
            input: input,
            definition: strippedDefinition,
            runtime: runtime,
            reasoningEffort: reasoningEffort,
            concurrencyCap: concurrencyCap,
            timeoutMS: timeoutMS,
            detachedSwarm: detachedSwarm
        )
        if Task.isCancelled {
            swarmRegistry.remove(swarmID)
            return .failure(.cancelled)
        }
        swarmRegistry.remove(swarmID)
        return .success(OpenGrokShellToolCallResult(
            value: .string(renderSwarmXML(results)),
            promptText: renderSwarmXML(results)
        ))
    }

    /// Rejoin or poll a detached `agent_swarm` cohort.
    /// Mirrors `SwarmWaitTool::run` (agent_swarm/wait.rs:99-183).
    func runSwarmWait(
        args: JSONValue,
        toolCallID: String
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        _ = toolCallID
        let swarmID = args["swarm_id"]?.stringValue
        let timeoutMS = args["timeout_ms"]?.uint64Value ?? 600_000
        let effectiveTimeoutMS = min(timeoutMS, 2 * 60 * 60 * 1000)

        let parentSessionID = context.sessionID
        let swarm: DetachedSwarm
        do {
            swarm = try swarmRegistry.resolve(swarmID: swarmID, parentSessionID: parentSessionID)
        } catch let err as OpenGrokShellToolRuntimeError {
            return .failure(err)
        } catch {
            return .failure(.invalidCall(error.localizedDescription))
        }

        if effectiveTimeoutMS == 0 {
            let slots = swarm.snapshot()
            let xml = renderDetachedSwarmXML(
                swarmID: swarm.swarmID,
                description: swarm.description,
                expectedMembers: swarm.expectedMembers,
                slots: slots
            )
            return .success(OpenGrokShellToolCallResult(value: .string(xml), promptText: xml))
        }

        if swarm.isFinished, let completed = swarm.takeComplete() {
            swarmRegistry.remove(swarm.swarmID)
            let xml = renderSwarmXML(completed)
            return .success(OpenGrokShellToolCallResult(value: .string(xml), promptText: xml))
        }

        foregroundWait.enter(.orchestration)
        defer { foregroundWait.exit(.orchestration) }

        _ = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await swarm.waitFinished()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: effectiveTimeoutMS * 1_000_000)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }

        if swarm.isFinished, let completed = swarm.takeComplete() {
            swarmRegistry.remove(swarm.swarmID)
            let xml = renderSwarmXML(completed)
            return .success(OpenGrokShellToolCallResult(value: .string(xml), promptText: xml))
        } else {
            let slots = swarm.snapshot()
            let xml = renderDetachedSwarmXML(
                swarmID: swarm.swarmID,
                description: swarm.description,
                expectedMembers: swarm.expectedMembers,
                slots: slots
            )
            return .success(OpenGrokShellToolCallResult(value: .string(xml), promptText: xml))
        }
    }

    // MARK: Scheduler

    /// Burst-then-ramp launching with slot-ordered collection. Mirrors the
    /// launch discipline of Rust `run_scheduler` (agent_swarm/mod.rs:548-686):
    /// the initial cohort is the only burst (min(total, 5, cap)); a later
    /// launch never occurs before the 700 ms ramp deadline, even if every
    /// initial member already completed; the active set never exceeds the
    /// configured cap. The rate-limit arms of the upstream select loop are
    /// the recorded divergence in the file header.
    private func runSwarmScheduler(
        members: [PlannedSwarmMember],
        input: AgentSwarmToolInput,
        definition: AgentDefinition,
        runtime: EffectiveRuntimeConfig,
        reasoningEffort: String?,
        concurrencyCap: Int?,
        timeoutMS: UInt64?,
        detachedSwarm: DetachedSwarm
    ) async -> [SwarmMemberResult] {
        var slots = [SwarmMemberResult?](repeating: nil, count: members.count)
        let capacity = max(1, min(concurrencyCap ?? members.count, members.count))
        let initialBurst = swarmInitialLaunchCount(
            total: members.count,
            concurrencyCap: concurrencyCap
        )
        let rampInterval = TimeInterval(Self.swarmRampIntervalMS) / 1_000

        enum SchedulerEvent: Sendable {
            case member(SwarmMemberResult)
            case rampTick
        }

        await withTaskGroup(of: SchedulerEvent.self) { group in
            var next = 0
            var active = 0
            var timerArmed = false

            func launch() {
                let member = members[next]
                // Upstream mints `Uuid::now_v7()`; the port shares the task
                // tool's v4 divergence (LiveSubagentHost.spawn).
                let agentID = UUID().uuidString.lowercased()
                group.addTask {
                    .member(await self.runSwarmMember(
                        member,
                        agentID: agentID,
                        input: input,
                        definition: definition,
                        runtime: runtime,
                        reasoningEffort: reasoningEffort,
                        timeoutMS: timeoutMS
                    ))
                }
                next += 1
                active += 1
            }

            while next < initialBurst { launch() }
            var nextLaunchAt = Date().addingTimeInterval(rampInterval)

            while next < members.count || active > 0 {
                if next < members.count, active < capacity {
                    let delay = nextLaunchAt.timeIntervalSinceNow
                    if delay <= 0 {
                        launch()
                        nextLaunchAt = Date().addingTimeInterval(rampInterval)
                        continue
                    }
                    if !timerArmed {
                        timerArmed = true
                        group.addTask {
                            try? await Task.sleep(
                                nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
                            )
                            return .rampTick
                        }
                    }
                }
                guard let event = await group.next() else { break }
                switch event {
                case .rampTick:
                    timerArmed = false
                case .member(let result):
                    slots[result.index] = result
                    detachedSwarm.store(index: result.index, result: result)
                    active -= 1
                }
            }
            // A ramp timer may still be sleeping after the last member
            // lands; cancel it rather than blocking scope exit on it.
            group.cancelAll()
        }

        return slots.enumerated().map { index, slot in
            // Reachable only if a member task died without a result (it
            // cannot: every runSwarmMember path returns one) — the loud
            // fallback keeps the slot-order contract visible.
            slot ?? SwarmMemberResult(
                index: index,
                item: members[index].item,
                agentID: "",
                outcome: .failed,
                isResume: members[index].isResume,
                body: "swarm member produced no result"
            )
        }
    }

    /// Run one member end to end through the coordinator: resume
    /// validation (spawn's own copy), bookkeeping, spawn, per-member
    /// timeout with cancel, and the outcome mapping of Rust
    /// `member_result` (agent_swarm/mod.rs:810-845).
    private func runSwarmMember(
        _ member: PlannedSwarmMember,
        agentID: String,
        input: AgentSwarmToolInput,
        definition: AgentDefinition,
        runtime: EffectiveRuntimeConfig,
        reasoningEffort: String?,
        timeoutMS: UInt64?
    ) async -> SwarmMemberResult {
        func failed(_ body: String) -> SwarmMemberResult {
            SwarmMemberResult(
                index: member.index,
                item: member.item,
                agentID: agentID,
                outcome: .failed,
                isResume: member.isResume,
                body: body
            )
        }

        var childModel = runtime.model ?? context.parentModel
        var resumeItems: [ConversationItem]?
        // Swarm input carries no per-member cwd (agent_swarm/mod.rs:742
        // `cwd: None`); fresh members run under the parent workspace. Resume
        // still inherits the SOURCE child's effective cwd/worktree through
        // the same helpers as `spawn` — upstream's SubagentRequest leaves
        // cwd unset and `handle_request` selects via `select_override_cwd`.
        var childCWD = context.workingDirectory
        var resumedWorktree: URL? = nil
        if let resumeID = member.resumeFrom {
            let activeIDs = await coordinator.listActive(parentSessionID: context.sessionID)
                .map { $0.request.id }
            if activeIDs.contains(resumeID) {
                return failed(
                    "Cannot resume from subagent '\(resumeID)': it is still running. Wait for it to complete before resuming."
                )
            }
            guard let source = bookkeeping[resumeID] else {
                return failed(Self.resumeNotFoundMessage(resumeID))
            }
            do {
                try validateResumeIdentity(
                    requestedType: input.subagentType,
                    requestedPersona: nil,
                    source: ResumeSourceData(
                        subagentID: resumeID,
                        subagentType: source.subagentType,
                        persona: source.persona,
                        modelID: source.model,
                        childCWD: source.childCWD?.path ?? "",
                        worktreePath: source.worktreePath,
                        childSessionID: resumeID
                    )
                )
            } catch {
                return failed(String(describing: error))
            }
            guard let record = try? await context.conversationStore.loadIfPresent(sessionID: resumeID) else {
                return failed(Self.resumeNotFoundMessage(resumeID))
            }
            resumeItems = record.items
            // Resumed members keep their prior model; the override applies
            // to new members only (agent_swarm/mod.rs:721-728).
            childModel = source.model
            // Same split as spawn: reusable URL vs recorded presence so a
            // missing worktree is Shared/parent, not stale `childCWD`
            // (`resume_inherited_cwd` / `worktree_path.is_some()`,
            // subagent/mod.rs:1621).
            resumedWorktree = Self.resumeWorktreePath(source.worktreePath)
            let overrideCWD = Self.resumeInheritedCWD(
                sourceCWD: source.childCWD,
                recordedWorktreePath: source.worktreePath
            )
            childCWD = Self.resolveChildCWD(
                worktreePath: resumedWorktree,
                overrideCWD: overrideCWD,
                parentCWD: context.workingDirectory
            )
        }

        bookkeeping[agentID] = Bookkeeping(
            startedAt: Date(),
            subagentType: input.subagentType,
            description: input.description,
            model: childModel,
            childCWD: childCWD,
            worktreePath: resumedWorktree
        )
        let request = OpenGrokChildRequest(
            id: agentID,
            parentSessionID: context.sessionID,
            owner: .swarm,
            runInBackground: false,
            awaitToCompletion: true,
            capabilityMode: runtime.capabilityMode?.rawValue,
            reasoningEffort: reasoningEffort ?? runtime.reasoningEffort,
            resumeFrom: member.resumeFrom,
            // The swarm scheduler, not the auto-wake drain, owns member
            // completion (agent_swarm/mod.rs:743-747).
            surfaceCompletion: false
        )
        let inheritedItems = resumeItems
        let memberPrompt = member.prompt
        let memberModel = childModel
        let memberCWD = childCWD
        do {
            // Swarm members are real coordinator children (`owner: .swarm`).
            // Rust `running_count` includes them when `workflow_run_id` is
            // absent; count each member once through the host helper so this
            // path cannot double-emit with `spawn`.
            try await coordinator.spawn(request) { [weak self] in
                guard let self else {
                    return OpenGrokChildResult(
                        id: agentID,
                        success: false,
                        error: "subagent host was torn down before the child ran"
                    )
                }
                return await self.withActiveBackgroundWorkCounting(for: request) {
                    await self.runChild(
                        childID: agentID,
                        prompt: memberPrompt,
                        definition: definition,
                        runtime: runtime,
                        model: memberModel,
                        cwd: memberCWD,
                        resumeItems: inheritedItems
                    )
                }
            }
        } catch let error as OpenGrokCoordinatorError {
            bookkeeping.removeValue(forKey: agentID)
            await emitActiveBackgroundWorkRemove(id: agentID)
            return failed(error.description)
        } catch {
            bookkeeping.removeValue(forKey: agentID)
            await emitActiveBackgroundWorkRemove(id: agentID)
            return failed("subagent \(agentID) could not be registered: \(error)")
        }

        let result: OpenGrokChildResult
        do {
            result = try await withTaskCancellationHandler {
                try await coordinator.awaitResult(agentID, timeoutMS: timeoutMS)
            } onCancel: { [coordinator] in
                Task { await coordinator.cancel(.childID(agentID)) }
            }
        } catch OpenGrokCoordinatorError.timeout {
            // Rust cancels the timed-out member and reports the fixed body
            // (agent_swarm/mod.rs:770-786).
            _ = await coordinator.cancel(.childID(agentID))
            return failed("subagent timed out")
        } catch is CancellationError {
            return SwarmMemberResult(
                index: member.index,
                item: member.item,
                agentID: agentID,
                outcome: .aborted,
                isResume: member.isResume,
                body: "Subagent was cancelled"
            )
        } catch {
            return failed("subagent \(agentID) did not produce a result: \(error)")
        }

        // `member_result` (agent_swarm/mod.rs:810-845). The auto-background
        // arm has no port analog: this host never backgrounds a foreground
        // await.
        let outcome: SwarmMemberOutcome = result.cancelled
            ? .aborted
            : (result.success ? .completed : .failed)
        let body = outcome == .completed
            ? result.output
            : (result.error ?? result.output)
        return SwarmMemberResult(
            index: member.index,
            item: member.item,
            agentID: agentID,
            outcome: outcome,
            isResume: member.isResume,
            body: body
        )
    }
}
