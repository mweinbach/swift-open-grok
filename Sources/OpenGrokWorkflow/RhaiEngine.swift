// RhaiEngine.swift
//
// The run entry point — port of `run_workflow` (engine.rs:103) and the
// dry-run validator (validate.rs).

import Foundation
import OpenGrokShared

public struct RhaiWorkflowRunParameters: Sendable {
    public var script: String
    public var arguments: JSONValue
    public var journal: RhaiJournal
    public var host: any RhaiWorkflowHost
    public var cancellation: RhaiCancellationToken
    public var limits: RhaiInterpreterLimits

    public init(
        script: String,
        arguments: JSONValue = .object([:]),
        journal: RhaiJournal,
        host: any RhaiWorkflowHost,
        cancellation: RhaiCancellationToken = RhaiCancellationToken(),
        limits: RhaiInterpreterLimits = RhaiInterpreterLimits()
    ) {
        self.script = script
        self.arguments = arguments
        self.journal = journal
        self.host = host
        self.cancellation = cancellation
        self.limits = limits
    }
}

public enum RhaiWorkflowEngine {
    /// engine.rs:103 — compile, then run to a terminal outcome.
    ///
    /// Resume is not a separate entry point: a run resumes by being started
    /// again with the journal it left behind. Every host call replays from that
    /// journal until the run catches up with itself, at which point calls go
    /// live again.
    public static func run(_ parameters: RhaiWorkflowRunParameters) async -> RhaiWorkflowOutcome {
        let program: RhaiProgram
        do {
            program = try RhaiParser.parse(parameters.script)
        } catch let error as RhaiParseError {
            return .failed(error: rhaiWithHint("script failed to compile: \(error.description)"))
        } catch {
            return .failed(error: "script failed to compile: \(error)")
        }

        let interpreter = RhaiInterpreter(
            program: program,
            arguments: parameters.arguments,
            host: parameters.host,
            journal: parameters.journal,
            cancellation: parameters.cancellation,
            limits: parameters.limits
        )
        return await interpreter.run()
    }
}

// MARK: - Validation

/// validate.rs:5 — what a successful dry run reports.
public struct RhaiValidationReport: Sendable, Hashable {
    public var name: String
    public var phases: Int
    public var outcomeOK: Bool
    public var outcomeSummary: String
}

/// validate.rs:13
public enum RhaiValidationError: Error, Sendable, CustomStringConvertible {
    case meta(RhaiMetaError)
    case run(String)

    public var description: String {
        switch self {
        case .meta(let error): return "meta: \(error.description)"
        case .run(let summary): return "dry-run: \(summary)"
        }
    }
}

public enum RhaiWorkflowValidator {
    /// validate.rs:20 — the stub arguments a probe run supplies, chosen so the
    /// bundled workflows and the authoring examples all reach their real paths.
    public static func defaultProbeArguments() -> JSONValue {
        .object([
            "objective": .string("stub objective"),
            "query": .string("stub query"),
            "breadth": .number(.int64(2)),
            "target": .string("stub target"),
            "skeptic_count": .number(.int64(1)),
            "max_verify_attempts": .number(.int64(1)),
            "baseline_commit": .string(""),
            "test_command": .string("cargo test"),
            "diff_summary": .string("stub diff"),
            "since_commit": .string("abc123"),
        ])
    }

    /// validate.rs:42 — validate the meta block, then dry-run the whole script
    /// against a stub host. A run that pauses counts as valid: pausing is a
    /// designed outcome, not a defect.
    public static func validate(
        script: String,
        arguments: JSONValue? = nil,
        agentBudget: UInt64 = rhaiDefaultAgentBudget
    ) async -> Result<RhaiValidationReport, RhaiValidationError> {
        let meta: RhaiWorkflowMeta
        do {
            meta = try RhaiMeta.extract(from: script)
        } catch let error as RhaiMetaError {
            return .failure(.meta(error))
        } catch {
            return .failure(.meta(.parse(String(describing: error))))
        }

        let outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
            script: script,
            arguments: arguments ?? defaultProbeArguments(),
            journal: RhaiJournal(),
            host: RhaiProbeHost(agentBudget: agentBudget),
            limits: {
                var limits = RhaiInterpreterLimits()
                limits.maxOperations = 10_000_000
                return limits
            }()
        ))

        let summary: String
        let ok: Bool
        switch outcome {
        case .completed(let result):
            ok = true
            summary = "completed: \(truncate(RhaiCanonicalJSON.string(result)))"
        case .paused(let kind, let message):
            ok = true
            summary = "paused (\(kind.rawValue)): \(truncate(message))"
        case .budgetExceeded(let message):
            ok = false
            summary = "budget exceeded: \(message)"
        case .cancelled:
            ok = false
            summary = "cancelled"
        case .failed(let error):
            ok = false
            summary = "failed: \(error)"
        }

        guard ok else { return .failure(.run(summary)) }
        return .success(RhaiValidationReport(
            name: meta.name,
            phases: meta.phases.count,
            outcomeOK: true,
            outcomeSummary: summary
        ))
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > 200 else { return text }
        return String(text.prefix(200)) + "…"
    }
}
