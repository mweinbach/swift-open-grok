// LiveAutoModeComposition.swift
//
// Wires the Rust LLM auto-mode classifier onto a live PermissionHandle.
// Reference: `wire_permission_auto_llm_classifier` (sampler_turn.rs:915-1037)
// and `LlmPermissionClassifier` (auto_mode.rs:1483-1601) at pin 650c1db7.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokWorkspace

enum LiveAutoModeComposition {
    /// Install `LlmPermissionClassifier` with a side-query through the session's
    /// auxiliary sampler route. Call whenever auto mode is turned on.
    static func installLLMClassifier(
        on permissions: PermissionHandle,
        sessionID: String,
        modelSwitch: LiveModelSwitchCoordinator,
        timeoutSeconds: TimeInterval = 30
    ) async {
        let classifier = LlmPermissionClassifier(
            classifyText: { messages in
                try await sampleClassifier(
                    messages: messages,
                    sessionID: sessionID,
                    modelSwitch: modelSwitch,
                    timeoutSeconds: timeoutSeconds
                )
            },
            promptType: .full
        )
        await permissions.setClassifier(classifier)
        await permissions.setAutoMode(true)
    }

    /// Drop back to the heuristic-only classifier when auto is turned off.
    static func uninstallLLMClassifier(on permissions: PermissionHandle) async {
        await permissions.setAutoMode(false)
        await permissions.setClassifier(HeuristicPermissionClassifier())
    }

    /// Compact recent conversation into the classifier transcript blob.
    ///
    /// MVP of `build_classifier_turns` (laziness_classifier.rs:487-545): keep
    /// genuine user turns and assistant tool-use names, capped per turn.
    static func transcript(from items: [ConversationItem], maxTurns: Int = 16) -> String {
        var lines: [String] = []
        for item in items.reversed() {
            if lines.count >= maxTurns { break }
            switch item {
            case .user(let user) where user.syntheticReason == nil:
                let text = user.content
                    .compactMap { part -> String? in
                        if case .text(let value) = part { return value }
                        return nil
                    }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("User: \(truncate(text, limit: 400))")
            case .assistant(let assistant):
                let calls = assistant.toolCalls.map(\.name)
                if !calls.isEmpty {
                    lines.append("Assistant tools: \(calls.joined(separator: ", "))")
                }
            default:
                continue
            }
        }
        return lines.reversed().joined(separator: "\n")
    }

    private static func sampleClassifier(
        messages: [ClassifierMessage],
        sessionID: String,
        modelSwitch: LiveModelSwitchCoordinator,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let route = await modelSwitch.auxiliaryRecapRoute(explicitModelID: nil)
        // Snapshot Sendable locals before the racing timeout task so the
        // region checker does not treat the sampler closure as capturing
        // mutable / non-sending state from this frame.
        let sampler = route.sampler
        let model = route.configuration.model
        let prompt = messages.last?.text ?? ""
        let schema = classifierOutputJSONSchema()
        let items: [ConversationItem] = messages.map { message in
            switch message.role {
            case .system: return .system(message.text)
            case .user: return .user(message.text)
            }
        }
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let response = try await sampler.sample(
                        OpenGrokLiveSamplingRequest(
                            sessionID: sessionID,
                            turnID: "xai-auto-classifier-\(UUID().uuidString)",
                            model: model,
                            prompt: prompt,
                            items: items,
                            tools: [],
                            jsonSchema: schema
                        )
                    ) { _ in }
                    return response.output
                }
                group.addTask {
                    let nanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                    throw ClassifierFailure.timeout
                }
                guard let first = try await group.next() else {
                    throw ClassifierFailure.transportError("classifier returned no text")
                }
                group.cancelAll()
                return first
            }
        } catch let failure as ClassifierFailure {
            throw failure
        } catch is CancellationError {
            throw ClassifierFailure.timeout
        } catch {
            throw ClassifierFailure.transportError(String(describing: error))
        }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end])
    }
}
