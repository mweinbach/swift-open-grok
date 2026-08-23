import Foundation
import OpenGrokAgentCoordinator
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokToolRegistry
import OpenGrokWorkflow

/// Provenance is assigned by the caller which actually resolved a workflow.
/// Script text, workflow names and project paths can never assert this fact.
enum LiveWorkflowSourceProvenance: Sendable, Equatable {
    case untrusted
    case trustedBuiltIn
}

/// Internal authority accompanies a launch outside the model-facing task JSON.
struct LiveWorkflowSubagentInvocation: Sendable {
    let runID: String
    let parentSessionID: String
    let sourceProvenance: LiveWorkflowSourceProvenance
    let forkContext: Bool
}

/// Workflow children must be genuine root-session subagents: only that host
/// owns provider-scoped credentials, sandbox authority, worktrees, durable
/// child sessions, and provider-rotation cancellation.
struct LiveWorkflowSubagentBridge: Sendable {
    let host: LiveSubagentHost
    let parentSessionID: String
    let sourceProvenance: LiveWorkflowSourceProvenance

    private struct ValidatedOptions {
        let capability: ToolCapabilityMode
        let reasoningEffort: ReasoningEffort?
        let schema: LiveWorkflowSchemaContract?
    }

    func run(
        runID: String,
        agentID: String,
        options: RhaiAgentOptions,
        environment: LiveWorkflowAgentEnvironment,
        cancellation: RhaiCancellationToken,
        emit: @Sendable @escaping (LiveWorkflowAgentEvent) async -> Void
    ) async throws -> RhaiAgentResult {
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw RhaiHostError.cancelled
        }
        let validated = try validate(options: options, environment: environment)
        // The host allocates this globally unique identifier before publishing
        // progress. Keep the dashboard row, coordinator task, and durable child
        // session on that one identity; a correction retry gets its own child.
        let originalChildID = agentID
        await emit(.started(agentID: agentID, label: options.label, phase: options.phase))

        var childID = originalChildID
        var prompt = validated.schema?.prompt(for: options.prompt) ?? options.prompt
        var resumeFrom = options.resumeFrom
        var forkContext = options.forkContext && resumeFrom == nil
        var totalTokens: UInt64 = 0
        var totalDuration: UInt64 = 0
        var attempts = 0

        do {
            while true {
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    throw RhaiHostError.cancelled
                }
                attempts += 1
                await emit(.status(agentID: agentID, "sampling"))
                let result = try await spawn(
                    childID: childID,
                    runID: runID,
                    prompt: prompt,
                    options: options,
                    validated: validated,
                    resumeFrom: resumeFrom,
                    forkContext: forkContext
                )
                totalTokens = totalTokens.addingReportingOverflow(result.tokensUsed).overflow
                    ? UInt64.max : totalTokens + result.tokensUsed
                totalDuration = totalDuration.addingReportingOverflow(result.durationMS).overflow
                    ? UInt64.max : totalDuration + result.durationMS

                if result.cancelled || cancellation.isCancelled {
                    throw RhaiHostError.cancelled
                }

                guard result.success else {
                    await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
                    return RhaiAgentResult(
                        agentID: originalChildID,
                        success: false,
                        output: .string(result.error ?? result.output),
                        tokensUsed: totalTokens,
                        durationMS: totalDuration
                    )
                }

                guard let schema = validated.schema else {
                    await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
                    return RhaiAgentResult(
                        agentID: originalChildID,
                        success: true,
                        output: .string(result.output),
                        tokensUsed: totalTokens,
                        durationMS: totalDuration
                    )
                }

                switch schema.validate(finalText: result.output) {
                case .success(let output):
                    await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
                    return RhaiAgentResult(
                        agentID: originalChildID,
                        success: true,
                        output: output,
                        tokensUsed: totalTokens,
                        durationMS: totalDuration
                    )
                case .failure(let message) where attempts == 1:
                    resumeFrom = result.id
                    childID = UUID().uuidString.lowercased()
                    forkContext = false
                    prompt = "Your final message did not satisfy the output contract: \(message)\n"
                        + "Reply with a single ```json fenced block containing one JSON "
                        + "value conforming to the schema from <output-contract>, and "
                        + "nothing else."
                case .failure(let message):
                    await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
                    return RhaiAgentResult(
                        agentID: originalChildID,
                        success: false,
                        output: .string("structured output validation failed: \(message)"),
                        tokensUsed: totalTokens,
                        durationMS: totalDuration
                    )
                }
            }
        } catch let error as RhaiHostError {
            await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
            throw error
        } catch is CancellationError {
            await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
            throw RhaiHostError.cancelled
        } catch {
            await emit(.finished(agentID: agentID, tokensUsed: totalTokens))
            throw RhaiHostError.failed("workflow child could not start: \(error)")
        }
    }

    private func validate(
        options: RhaiAgentOptions,
        environment: LiveWorkflowAgentEnvironment
    ) throws -> ValidatedOptions {
        guard options.prompt.utf8.count <= 1_048_576 else {
            throw RhaiHostError.failed("agent prompt exceeds 1048576 bytes")
        }
        // Rust checks authorization before clearing fork_context for resume.
        if options.forkContext, sourceProvenance != .trustedBuiltIn {
            throw RhaiHostError.unsupported(
                "fork_context is restricted to built-in workflows"
            )
        }
        if (options.label?.utf8.count ?? 0) > 256
            || (options.phase?.utf8.count ?? 0) > 256 {
            throw RhaiHostError.failed(
                "agent label and phase must each be at most 256 bytes"
            )
        }
        let capability = try LiveWorkflowCapability.clamp(
            requested: options.capabilityMode,
            parent: environment.parentCapabilityMode
        )
        let reasoningEffort = try LiveWorkflowChildAgent.normalizedReasoningEffort(
            options.reasoningEffort
        )
        if reasoningEffort != nil {
            if let model = options.model, model != environment.model {
                throw RhaiHostError.unsupported(
                    "reasoning_effort cannot be validated for workflow model '\(model)'"
                )
            }
            guard environment.supportsReasoningEffort else {
                throw RhaiHostError.unsupported(
                    "reasoning_effort is not supported by the active workflow model"
                )
            }
        }
        let contract = try options.outputSchema.map(LiveWorkflowSchemaContract.init)
        return ValidatedOptions(
            capability: capability,
            reasoningEffort: reasoningEffort,
            schema: contract
        )
    }

    private func spawn(
        childID: String,
        runID: String,
        prompt: String,
        options: RhaiAgentOptions,
        validated: ValidatedOptions,
        resumeFrom: String?,
        forkContext: Bool
    ) async throws -> OpenGrokChildResult {
        var arguments: [String: JSONValue] = [
            "task_id": .string(childID),
            "prompt": .string(prompt),
            "description": .string(options.label ?? options.phase ?? "workflow agent"),
            "subagent_type": .string(options.agentType ?? "general-purpose"),
            "run_in_background": .bool(false),
            "capability_mode": .string(validated.capability.rawValue),
        ]
        if options.isolationWorktree {
            arguments["isolation"] = .string("worktree")
        }
        if let resumeFrom { arguments["resume_from"] = .string(resumeFrom) }
        if let model = options.model { arguments["model"] = .string(model) }
        if let effort = validated.reasoningEffort {
            arguments["reasoning_effort"] = .string(effort.rawValue)
        }

        let outcome = await host.spawn(
            args: .object(arguments),
            toolCallID: "workflow-\(childID)",
            workflow: LiveWorkflowSubagentInvocation(
                runID: runID,
                parentSessionID: parentSessionID,
                sourceProvenance: sourceProvenance,
                forkContext: forkContext
            )
        )
        let completed = await host.coordinator.listCompleted()
            .first { $0.request.id == childID }
        if let completed {
            guard completed.request.owner == .workflow,
                  completed.request.workflowRunID == runID,
                  completed.request.parentSessionID == parentSessionID,
                  let result = completed.result
            else {
                throw RhaiHostError.failed("workflow child ownership could not be verified")
            }
            return result
        }

        switch outcome {
        case .success:
            throw RhaiHostError.failed("workflow child did not produce a durable result")
        case .failure(.cancelled):
            throw RhaiHostError.cancelled
        case .failure(.invalidCall(let message)),
             .failure(.failed(let message)),
             .failure(.denied(let message)):
            throw RhaiHostError.failed(message)
        case .failure(.unsupported(let message)):
            throw RhaiHostError.unsupported(message)
        }
    }
}

private struct LiveWorkflowSchemaContract: Sendable {
    private let schemaText: String
    private let validator: JSONSchemaValidator

    init(_ schema: JSONValue) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(schema)
        } catch {
            throw RhaiHostError.failed("output_schema cannot be serialized: \(error)")
        }
        guard data.count <= 262_144 else {
            throw RhaiHostError.failed(
                "output_schema is too large (\(data.count) bytes; maximum is 262144)"
            )
        }
        try Self.validateSupportedKeywords(schema)
        do {
            validator = try JSONSchemaValidator(schema: schema)
        } catch {
            throw RhaiHostError.failed(
                "output_schema is not a valid self-contained JSON Schema: \(error)"
            )
        }
        schemaText = String(decoding: data, as: UTF8.self)
    }

    func prompt(for original: String) -> String {
        original + "\n\n<output-contract>\n"
            + "Do the work above with your tools first. Then end your final message "
            + "with a single ```json fenced block containing exactly one JSON value "
            + "that conforms to this JSON Schema (no prose inside the block):\n"
            + schemaText + "\n</output-contract>"
    }

    func validate(finalText: String) -> Result<JSONValue, String> {
        guard finalText.utf8.count <= 2_097_152 else {
            return .failure(
                "final message exceeds the 2097152 byte structured-output limit"
            )
        }
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if let opening = text.range(of: "```json", options: .backwards) {
            let body = text[opening.upperBound...]
            if let closing = body.range(of: "```") {
                candidates.append(String(body[..<closing.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        candidates.append(text)
        for (opening, closing) in [("{", "}"), ("[", "]")] {
            if let start = text.range(of: opening)?.lowerBound,
               let end = text.range(of: closing, options: .backwards)?.upperBound,
               start < end {
                candidates.append(String(text[start..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }
            return validator.validate(value: value)
        }
        return .failure(
            "final message did not contain valid JSON "
                + "(expected a ```json fenced block): parse error"
        )
    }

    private static func validateSupportedKeywords(_ value: JSONValue) throws {
        switch value {
        case .object(let object):
            if let rawReference = object["$ref"] {
                guard let reference = rawReference.stringValue else {
                    throw invalidKeyword("$ref", expected: "a string")
                }
                if !reference.hasPrefix("#") {
                    throw RhaiHostError.failed(
                        "output_schema is not a valid self-contained JSON Schema: "
                            + "external JSON Schema references are disabled: \(reference)"
                    )
                }
                throw RhaiHostError.failed(
                    "output_schema local JSON Schema references are not supported"
                )
            }

            if let type = object["type"] {
                let allowed = Set(["null", "boolean", "object", "array", "number", "string", "integer"])
                if let name = type.stringValue {
                    guard allowed.contains(name) else {
                        throw invalidKeyword("type", expected: "a valid JSON Schema type")
                    }
                } else if let names = type.arrayValue {
                    let strings = names.compactMap(\.stringValue)
                    guard !strings.isEmpty,
                          strings.count == names.count,
                          Set(strings).count == strings.count,
                          strings.allSatisfy(allowed.contains)
                    else {
                        throw invalidKeyword(
                            "type",
                            expected: "a non-empty array of unique valid JSON Schema types"
                        )
                    }
                } else {
                    throw invalidKeyword("type", expected: "a string or array of strings")
                }
            }
            if let enumeration = object["enum"] {
                guard let values = enumeration.arrayValue, !values.isEmpty else {
                    throw invalidKeyword("enum", expected: "a non-empty array")
                }
            }
            if let required = object["required"] {
                guard let names = required.arrayValue else {
                    throw invalidKeyword("required", expected: "an array of unique strings")
                }
                let strings = names.compactMap(\.stringValue)
                guard strings.count == names.count, Set(strings).count == strings.count else {
                    throw invalidKeyword("required", expected: "an array of unique strings")
                }
            }
            for keyword in ["properties", "$defs", "definitions"] {
                if let value = object[keyword], value.objectValue == nil {
                    throw invalidKeyword(keyword, expected: "an object of schemas")
                }
            }
            for keyword in ["items", "additionalProperties"] {
                if let nested = object[keyword],
                   nested.objectValue == nil,
                   nested.boolValue == nil {
                    throw invalidKeyword(keyword, expected: "a schema")
                }
            }
            for keyword in ["allOf", "anyOf", "oneOf"] {
                if let value = object[keyword] {
                    guard let schemas = value.arrayValue, !schemas.isEmpty else {
                        throw invalidKeyword(keyword, expected: "a non-empty array of schemas")
                    }
                }
            }
            for keyword in [
                "minProperties", "maxProperties", "minItems", "maxItems",
                "minLength", "maxLength",
            ] {
                if let value = object[keyword],
                   value.int64Value.map({ $0 >= 0 }) != true {
                    throw invalidKeyword(keyword, expected: "a non-negative integer")
                }
            }
            for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
                if let value = object[keyword], value.doubleValue == nil {
                    throw invalidKeyword(keyword, expected: "a number")
                }
            }
            for keyword in [
                "pattern", "patternProperties", "$dynamicRef", "$recursiveRef",
                "not", "if", "then", "else", "dependentSchemas", "dependentRequired",
                "contains", "minContains", "maxContains", "uniqueItems", "multipleOf",
                "prefixItems", "propertyNames", "unevaluatedProperties", "unevaluatedItems",
                "format", "contentEncoding", "contentMediaType", "contentSchema",
            ] {
                if object[keyword] != nil {
                    throw RhaiHostError.failed(
                        "output_schema keyword '\(keyword)' cannot be safely validated"
                    )
                }
            }
            for keyword in ["properties", "$defs", "definitions"] {
                if let definitions = object[keyword]?.objectValue {
                    for nested in definitions.values {
                        try validateSupportedKeywords(nested)
                    }
                }
            }
            for keyword in ["items", "additionalProperties"] {
                if let nested = object[keyword] {
                    try validateSupportedKeywords(nested)
                }
            }
            for keyword in ["allOf", "anyOf", "oneOf"] {
                if let schemas = object[keyword]?.arrayValue {
                    for nested in schemas {
                        try validateSupportedKeywords(nested)
                    }
                }
            }
        case .bool:
            break
        default:
            throw RhaiHostError.failed(
                "output_schema is not a valid self-contained JSON Schema: "
                    + "every schema must be an object or boolean"
            )
        }
    }

    private static func invalidKeyword(
        _ keyword: String,
        expected: String
    ) -> RhaiHostError {
        .failed(
            "output_schema is not a valid self-contained JSON Schema: "
                + "keyword '\(keyword)' must be \(expected)"
        )
    }
}
