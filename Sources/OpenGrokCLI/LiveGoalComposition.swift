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
// Not ported: the independent goal verifier. At the pinned Rust reference,
// `goal.rs:176-185` pauses an active goal for infrastructure reasons when that
// verifier is unavailable; it never accepts the worker model's completion
// claim as independent evidence. Preserve that fail-closed boundary until the
// actual verifier exists.

import Foundation
import OpenGrokFileUtils
import OpenGrokGoalState
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokToolsAPI

enum LiveGoalPersistenceError: Error, Sendable, CustomStringConvertible {
    case invalidSessionDirectory(String)
    case stateOutsideRoot(path: String, root: String)
    case symbolicLink(String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case invalidTransition(String)

    var description: String {
        switch self {
        case .invalidSessionDirectory(let reason):
            return "goal session storage is unavailable: \(reason)"
        case .stateOutsideRoot(let path, let root):
            return "goal state path \(path) escapes the session state root \(root)"
        case .symbolicLink(let path):
            return "goal state refuses to follow a symbolic link at \(path)"
        case .readFailed(let path, let reason):
            return "goal state could not be read at \(path): \(reason)"
        case .writeFailed(let path, let reason):
            return "goal state could not be persisted at \(path): \(reason)"
        case .invalidTransition(let reason):
            return reason
        }
    }
}

/// Serializes access to the tracker and persists it across turns.
///
/// `GoalTracker` is a `mutating`-heavy struct, so it needs a single owner; an
/// actor is that owner. The snapshot is written to the session directory after
/// every mutation so a goal survives a crash mid-pursuit, which is when a goal
/// is most worth surviving.
actor LiveGoalCoordinator {
    static let verificationUnavailableMessage =
        "Goal verification is unavailable. Resume after enabling the verifier."

    private var tracker: GoalTracker
    private let stateRoot: URL
    private let stateURL: URL
    private let initializationError: LiveGoalPersistenceError?

    init(
        sessionDirectory: URL,
        stateRoot: URL? = nil,
        initializationError: LiveGoalPersistenceError? = nil
    ) {
        let directory = sessionDirectory.standardizedFileURL
        let root = (stateRoot ?? directory).standardizedFileURL
        let stateURL = directory
            .appendingPathComponent("goal", isDirectory: true)
            .appendingPathComponent("state.json")
        self.stateRoot = root
        self.stateURL = stateURL
        // Restore rather than start empty: `GoalTracker.fromSnapshot` also
        // applies the resume rules (an active goal comes back user-paused, any
        // in-flight phase is cleared), which is what keeps a resumed session
        // from believing a subagent is still running.
        if let initializationError {
            self.tracker = GoalTracker(sessionDirectory: directory)
            self.initializationError = initializationError
            return
        }

        do {
            try Self.validateExistingStatePath(stateURL, under: root)
            let data = try PathSecurity.readNoFollow(
                stateURL,
                maximumBytes: 8 * 1_024 * 1_024,
                requireOwnerOnly: true
            )
            let snapshot = try JSONDecoder().decode(GoalOrchestration.self, from: data)
            self.tracker = GoalTracker.fromSnapshot(
                sessionDirectory: directory,
                snapshot: snapshot
            )
            self.initializationError = nil
        } catch FileUtilsError.notFound {
            self.tracker = GoalTracker(sessionDirectory: directory)
            self.initializationError = nil
        } catch {
            self.tracker = GoalTracker(sessionDirectory: directory)
            self.initializationError = .readFailed(
                path: stateURL.path,
                reason: String(describing: error)
            )
        }
    }

    var isActive: Bool { tracker.isActive }
    var objective: String? { tracker.objective }
    var status: GoalStatus? { tracker.status }
    var snapshot: GoalOrchestration? { tracker.snapshotValue }

    /// Start pursuing `objective`. Backs `/goal <objective>`.
    @discardableResult
    func createGoal(objective: String) -> Result<Void, Error> {
        let previous = tracker
        do {
            try ensureStorageAvailable()
            // GoalTracker creates its goal directory internally. Establish the
            // owner-only, no-symlink boundary before that unguarded creation.
            try prepareStateDirectory()
            tracker.createGoal(
                goalID: UUID().uuidString,
                objective: objective
            )
            try persist()
            return .success(())
        } catch {
            tracker = previous
            return .failure(error)
        }
    }

    @discardableResult
    func pause() -> Result<Void, Error> {
        mutateAndPersist { tracker in
            guard tracker.pause(.user) else {
                throw LiveGoalPersistenceError.invalidTransition("goal is not active")
            }
        }
    }

    @discardableResult
    func resume() -> Result<Void, Error> {
        mutateAndPersist { tracker in
            guard tracker.resume() else {
                throw LiveGoalPersistenceError.invalidTransition("goal is not paused")
            }
        }
    }

    @discardableResult
    func clear() -> Result<Void, Error> {
        mutateAndPersist { tracker in
            tracker.clear()
        }
    }

    /// Apply one `update_goal` call and report the verdict the model sees.
    func applyUpdate(_ input: UpdateGoalInput) -> Result<GoalUpdateOutcome, Error> {
        let previous = tracker
        do {
            try ensureStorageAvailable()
            try input.validate()

            let outcome: GoalUpdateOutcome
            if input.completed == true {
                guard tracker.isActive else {
                    throw GoalUpdateValidationError.nonActiveGoal
                }
                guard tracker.pauseWithMessage(
                    .infra,
                    message: Self.verificationUnavailableMessage
                ) else {
                    throw GoalUpdateValidationError.nonActiveGoal
                }
                outcome = .accepted(
                    summary: "Goal cannot be completed: \(Self.verificationUnavailableMessage)"
                )
            } else {
                outcome = try tracker.applyUpdate(input)
            }

            try persist()
            return .success(outcome)
        } catch {
            tracker = previous
            return .failure(error)
        }
    }

    private func mutateAndPersist(
        _ mutation: (inout GoalTracker) throws -> Void
    ) -> Result<Void, Error> {
        let previous = tracker
        do {
            try ensureStorageAvailable()
            try mutation(&tracker)
            try persist()
            return .success(())
        } catch {
            tracker = previous
            return .failure(error)
        }
    }

    private func ensureStorageAvailable() throws {
        if let initializationError {
            throw initializationError
        }
    }

    private func persist() throws {
        guard let snapshot = tracker.snapshotValue else {
            try Self.validateExistingStatePath(stateURL, under: stateRoot)
            guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: stateURL)
                try AtomicFile.fsyncDirectory(at: stateURL.deletingLastPathComponent())
            } catch {
                throw LiveGoalPersistenceError.writeFailed(
                    path: stateURL.path,
                    reason: String(describing: error)
                )
            }
            return
        }

        try prepareStateDirectory()
        try Self.rejectSymbolicLinkIfPresent(stateURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(snapshot)
            try AtomicFile.write(stateURL, data: data, options: .ownerOnly)
        } catch {
            throw LiveGoalPersistenceError.writeFailed(
                path: stateURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func prepareStateDirectory() throws {
        let destination = stateURL.deletingLastPathComponent()
        let rootComponents = stateRoot.pathComponents
        let destinationComponents = destination.pathComponents
        guard destinationComponents.starts(with: rootComponents) else {
            throw LiveGoalPersistenceError.stateOutsideRoot(
                path: destination.path,
                root: stateRoot.path
            )
        }

        var directory = stateRoot
        try prepareOwnerOnlyDirectory(directory)
        for component in destinationComponents.dropFirst(rootComponents.count) {
            directory.appendPathComponent(component, isDirectory: true)
            try prepareOwnerOnlyDirectory(directory)
        }
    }

    private func prepareOwnerOnlyDirectory(_ directory: URL) throws {
        try Self.rejectSymbolicLinkIfPresent(directory)
        do {
            try RelocationFS.createDirectoryDurable(directory, stateRoot: stateRoot)
            try RelocationFS.requireDirectory(directory)
        } catch {
            throw LiveGoalPersistenceError.writeFailed(
                path: stateURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static func validateExistingStatePath(_ path: URL, under root: URL) throws {
        let rootComponents = root.pathComponents
        let pathComponents = path.pathComponents
        guard pathComponents.starts(with: rootComponents) else {
            throw LiveGoalPersistenceError.stateOutsideRoot(
                path: path.path,
                root: root.path
            )
        }

        var componentPath = root
        try rejectSymbolicLinkIfPresent(componentPath)
        for component in pathComponents.dropFirst(rootComponents.count) {
            componentPath.appendPathComponent(component)
            try rejectSymbolicLinkIfPresent(componentPath)
        }
    }

    private static func rejectSymbolicLinkIfPresent(_ path: URL) throws {
        do {
            if try PathSecurity.isSymlink(path) {
                throw LiveGoalPersistenceError.symbolicLink(path.path)
            }
        } catch FileUtilsError.notFound {
            return
        }
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
                return operationOutcome(
                    await coordinator.pause(),
                    success: "Goal paused.",
                    failure: "Goal was not paused"
                )
            case "resume":
                return operationOutcome(
                    await coordinator.resume(),
                    success: "Goal resumed.",
                    failure: "Goal was not resumed"
                )
            case "clear":
                return operationOutcome(
                    await coordinator.clear(),
                    success: "Goal cleared.",
                    failure: "Goal was not cleared"
                )
            case "edit":
                return .message("Editing a goal in place is not supported; use /goal <objective> to replace it.")
            default:
                break
            }
        }
        switch await coordinator.createGoal(objective: trimmed) {
        case .success:
            return .submitPrompt(goalInstruction(trimmed))
        case .failure(let error):
            return .message("Goal was not created: \(error)")
        }
    }

    static func statusText(coordinator: LiveGoalCoordinator) async -> String {
        guard let snapshot = await coordinator.snapshot else {
            return goalUsageMessage()
        }
        let summary = "Goal (\(snapshot.status.rawValue)): \(snapshot.objective)"
        guard let pauseMessage = snapshot.pauseMessage, !pauseMessage.isEmpty else {
            return summary
        }
        return "\(summary)\n\(pauseMessage)"
    }

    private static func operationOutcome(
        _ result: Result<Void, Error>,
        success: String,
        failure: String
    ) -> Outcome {
        switch result {
        case .success:
            return .message(success)
        case .failure(let error):
            return .message("\(failure): \(error)")
        }
    }
}
