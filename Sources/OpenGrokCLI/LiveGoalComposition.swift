// LiveGoalComposition.swift
//
// Registers `update_goal` and gives `Sources/OpenGrokGoalState/` a call site.
//
// The problem this closes is narrower and sharper than "goals are missing".
// `Sources/OpenGrokToolsAPI/SlashCommands.swift` declares
// `updateGoalToolName = "update_goal"` and a `goalInstruction(_:)` block whose
// text tells the model, in so many words, to call
// `update_goal(completed:)` / `update_goal(blocked_reason:)` /
// `update_goal(message:)`. Neither symbol had a single reference anywhere else
// in the tree. So the moment anything wired `/goal` up, the model would be
// handed instructions to call a tool that does not exist — and a model told to
// call a missing tool does not degrade gracefully, it retries.
//
// Registering the tool is the fix that leaves the instruction text honest.
// `GoalTracker.applyUpdate` in `Sources/OpenGrokGoalState/` already ports the
// whole Rust verdict machine — the three-strike blocked streak, the
// non-active-goal rejections, the completion path — so this file is a
// registration and a persistence shim, not a reimplementation.
//
// Rust reference: `xai-grok-tools/src/implementations/grok_build/update_goal/`
// for the schema, and `xai-grok-shell/src/session/acp_session_impl/goal.rs` for
// the drain loop the tool blocks on.
//
// Not ported: the classifier. Rust verifies a `completed: true` claim by
// running a separate model pass that decides whether the goal was actually
// achieved, with its own cap, stall detection and fail-open rules. This port
// has no classifier, so `applyUpdate` takes the model at its word — which is
// exactly the `CompletedWithoutClassifier` branch Rust itself falls back to
// when the classifier policy is disabled. The behaviour is a documented Rust
// mode, not an invention.

import Foundation
import OpenGrokGoalState
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolsAPI

/// Serializes access to the tracker and persists it across turns.
///
/// `GoalTracker` is a `mutating`-heavy struct, so it needs a single owner; an
/// actor is that owner. The snapshot is written to the session directory after
/// every mutation so a goal survives a crash mid-pursuit, which is when a goal
/// is most worth surviving.
actor LiveGoalCoordinator {
    private var tracker: GoalTracker
    private let stateURL: URL

    init(sessionDirectory: URL) {
        let directory = sessionDirectory.standardizedFileURL
        self.stateURL = directory
            .appendingPathComponent("goal", isDirectory: true)
            .appendingPathComponent("state.json")
        // Restore rather than start empty: `GoalTracker.fromSnapshot` also
        // applies the resume rules (an active goal comes back user-paused, any
        // in-flight phase is cleared), which is what keeps a resumed session
        // from believing a subagent is still running.
        if let data = try? Data(contentsOf: stateURL),
           let snapshot = try? JSONDecoder().decode(GoalOrchestration.self, from: data) {
            self.tracker = GoalTracker.fromSnapshot(
                sessionDirectory: directory,
                snapshot: snapshot
            )
        } else {
            self.tracker = GoalTracker(sessionDirectory: directory)
        }
    }

    var isActive: Bool { tracker.isActive }
    var objective: String? { tracker.objective }
    var status: GoalStatus? { tracker.status }
    var snapshot: GoalOrchestration? { tracker.snapshotValue }

    /// Start pursuing `objective`. Backs `/goal <objective>`.
    func createGoal(objective: String) {
        tracker.createGoal(
            goalID: UUID().uuidString,
            objective: objective
        )
        persist()
    }

    func pause() {
        _ = tracker.pause(.user)
        persist()
    }

    func resume() {
        _ = tracker.resume()
        persist()
    }

    func clear() {
        tracker.clear()
        persist()
    }

    /// Apply one `update_goal` call and report the verdict the model sees.
    func applyUpdate(_ input: UpdateGoalInput) -> Result<GoalUpdateOutcome, Error> {
        do {
            let outcome = try tracker.applyUpdate(input)
            persist()
            return .success(outcome)
        } catch {
            return .failure(error)
        }
    }

    private func persist() {
        guard let snapshot = tracker.snapshotValue else {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

/// The `update_goal` tool: schema, gating, and dispatch.
enum LiveGoalTools {
    /// Reuses the name `SlashCommands.swift` already declares, so the string
    /// the prompt text names and the string the tool registers under cannot
    /// drift apart. That coupling is the point.
    static var toolName: String { updateGoalToolName }

    /// The tool is advertised **only while a goal is active**.
    ///
    /// Rust advertises it under the same gate. Advertising it unconditionally
    /// would put a tool in every session's tool list that rejects every call
    /// with "no active goal", which trains the model to ignore rejections.
    static func toolSpecs(goalIsActive: Bool) -> [ToolSpec] {
        guard goalIsActive else { return [] }
        return [
            ToolSpec(
                name: toolName,
                description: """
                Report progress on the active goal. Call with completed: true \
                ONLY when the goal is fully achieved.
                """,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "completed": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                """
                                Set to true ONLY when the goal is fully achieved. \
                                This ends goal mode. Use together with `message` to \
                                include a completion summary.
                                """
                            ),
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Optional short message logged as progress."
                            ),
                        ]),
                        "blocked_reason": .object([
                            "type": .string("string"),
                            "description": .string(
                                """
                                Set only when truly stuck after 3+ consecutive failed \
                                attempts. If set, the goal is paused as blocked. This \
                                is a FAILURE signal.
                                """
                            ),
                        ]),
                    ]),
                ])
            ),
        ]
    }

    /// Decode, apply, and render the tool result.
    ///
    /// `completed` accepts loose forms (`"true"`, `1`) because Rust's
    /// deserializer does: a model that emits a stringified boolean should not
    /// have its completion claim silently read as "no".
    static func invoke(
        arguments: JSONValue,
        coordinator: LiveGoalCoordinator?
    ) async -> String {
        guard let coordinator else {
            return "No goal is active. Set one with /goal <objective> before calling update_goal."
        }
        guard case .object(let fields) = arguments else {
            return "update_goal arguments must be a JSON object."
        }
        let input = UpdateGoalInput(
            completed: fields["completed"].flatMap(looseBool),
            message: stringValue(fields["message"]),
            blockedReason: stringValue(fields["blocked_reason"])
        )
        switch await coordinator.applyUpdate(input) {
        case .success(let outcome):
            switch outcome {
            case .accepted(let summary), .blocked(let summary), .completed(let summary):
                return summary
            }
        case .failure(let error):
            // The instruction block tells the model to keep working and report
            // in its reply when this tool errors, so the error text is the
            // model's cue rather than a turn-ending failure.
            return "update_goal was not applied: \(error)"
        }
    }

    private static func looseBool(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number.doubleValue != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Handler bodies for `/goal` and its reserved subcommands.
///
/// Returns either text to show or a prompt to submit on the user's behalf —
/// setting a goal seeds the model with `goalInstruction(_:)`, which is a turn,
/// not a message.
enum LiveGoalCommands {
    enum Outcome: Sendable, Equatable {
        case message(String)
        case submitPrompt(String)
    }

    static func run(
        argument: String,
        coordinator: LiveGoalCoordinator
    ) async -> Outcome {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .message(await statusText(coordinator: coordinator))
        }
        // Reserved subcommands are matched only as a bare single word, so
        // `/goal status of the parser` sets a goal rather than being read as a
        // status query.
        if goalReservedSubcommands.contains(trimmed.lowercased()) {
            switch trimmed.lowercased() {
            case "status":
                return .message(await statusText(coordinator: coordinator))
            case "pause":
                await coordinator.pause()
                return .message("Goal paused.")
            case "resume":
                await coordinator.resume()
                return .message("Goal resumed.")
            case "clear":
                await coordinator.clear()
                return .message("Goal cleared.")
            case "edit":
                return .message("Editing a goal in place is not supported; use /goal <objective> to replace it.")
            default:
                break
            }
        }
        await coordinator.createGoal(objective: trimmed)
        return .submitPrompt(goalInstruction(trimmed))
    }

    static func statusText(coordinator: LiveGoalCoordinator) async -> String {
        guard let objective = await coordinator.objective else {
            return goalUsageMessage()
        }
        let status = await coordinator.status?.rawValue ?? "unknown"
        return "Goal (\(status)): \(objective)"
    }
}
