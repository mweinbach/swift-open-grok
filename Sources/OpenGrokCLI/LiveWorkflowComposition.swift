// LiveWorkflowComposition.swift
//
// The `open-grok workflow …` route and the `--workflow <file>` launch flag.
//
// Both read and write the same two artifacts the background registry owns —
// `<OPENGROK_HOME>/workflow-runs.json` and the per-run journal — so a run
// launched by `--workflow` is visible to `workflow list` from any later
// process, and the `/workflows` overlay in a live session shows the same rows.

import Foundation
import OpenGrokSessionPersistence
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWorkflow

public enum LiveWorkflowComposition {
    public static let routeName = "workflow"

    /// Subcommands this route accepts. `run` is here for symmetry with
    /// `--workflow`, and both go through the same background registry: a
    /// foreground workflow does not exist in this design, matching upstream.
    public static let actions: Set<String> = ["list", "show", "run", "cancel", "resume", "validate"]

    public static func handles(_ command: CLICommand) -> Bool {
        if case .workflow = command { return true }
        return false
    }

    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .workflow(let options) = command else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try await run(options: options, environment: context.environment, streams: context.streams)
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    // MARK: - Route

    static func run(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams
    ) async throws {
        let home = workflowStateDirectory(environment: environment)
        let registry = RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: home))

        switch options.action {
        case "list":
            let views = try await registry.views()
            if options.json {
                streams.out(renderJSON(.array(views.map(runJSON))))
            } else {
                streams.out(renderList(views))
            }

        case "show":
            guard let target = options.target else {
                throw CLIApplicationError.failed("workflow show requires a run id")
            }
            let view = try await registry.view(runID: target)
            if options.json {
                streams.out(renderJSON(runJSON(view)))
            } else {
                streams.out(renderDetail(view))
            }

        case "validate":
            guard let target = options.target else {
                throw CLIApplicationError.failed("workflow validate requires a script path")
            }
            let script = try readScript(at: target)
            switch await RhaiWorkflowValidator.validate(script: script) {
            case .success(let report):
                streams.out("\(report.name): \(report.phases) phase(s) — \(report.outcomeSummary)\n")
            case .failure(let error):
                throw CLIApplicationError.failed("workflow validation failed: \(error.description)")
            }

        case "cancel":
            guard let target = options.target else {
                throw CLIApplicationError.failed("workflow cancel requires a run id")
            }
            try await registry.cancel(runID: target)
            streams.out("cancelled \(target)\n")

        case "run", "resume":
            // Launching needs a provider, a workspace, and a tool surface —
            // everything the interactive launcher composes. Routing it through
            // `--workflow` keeps exactly one construction path for a live run
            // rather than a second, subtly different one here.
            throw CLIApplicationError.failed(
                "use `open-grok --workflow <file>` to launch a workflow; "
                    + "`workflow \(options.action)` only inspects existing runs"
            )

        default:
            throw CLIApplicationError.failed(
                "unknown workflow action '\(options.action)'; expected one of "
                    + actions.sorted().joined(separator: ", ")
            )
        }
    }

    /// Runs live beside the rest of the CLI's state, under `OPENGROK_HOME`.
    static func workflowStateDirectory(environment: [String: String]) -> URL {
        if let raw = environment["OPENGROK_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".opengrok", isDirectory: true)
            .standardizedFileURL
    }

    static func readScript(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIApplicationError.failed("cannot read workflow script \(path): \(error)")
        }
    }

    // MARK: - Rendering

    static func renderList(_ views: [RhaiWorkflowRunView]) -> String {
        guard !views.isEmpty else { return "no workflow runs\n" }
        var out = ""
        for view in views {
            let record = view.record
            let agents = view.agents
            let done = agents.filter { $0.state != .running }.count
            var line = "\(record.runID)  \(record.workflowName)  \(record.status.rawValue)"
            line += "  agents \(done)/\(record.agentBudget == 0 ? "-" : String(record.agentBudget))"
            if let phase = view.currentPhase { line += "  phase: \(phase)" }
            out += line + "\n"
        }
        return out
    }

    static func renderDetail(_ view: RhaiWorkflowRunView) -> String {
        let record = view.record
        var out = "run \(record.runID)\n"
        out += "  workflow: \(record.workflowName)\n"
        out += "  status:   \(record.status.rawValue)\n"
        out += "  agents:   \(record.agentsUsed) used of \(record.agentBudget)\n"
        if let path = record.journalPath { out += "  journal:  \(path)\n" }
        if let message = record.message { out += "  message:  \(message)\n" }
        if !view.phases.isEmpty {
            out += "  phases:\n"
            for phase in view.phases { out += "    - \(phase)\n" }
        }
        if !view.agents.isEmpty {
            out += "  agent roster:\n"
            for agent in view.agents {
                let name = agent.label ?? agent.agentID ?? "seq \(agent.seq)"
                out += "    - \(name): \(agent.state.label)"
                if agent.tokensUsed > 0 { out += " (~\(agent.tokensUsed) tokens)" }
                out += "\n"
            }
        }
        if let result = record.result {
            out += "  result:   \(RhaiCanonicalJSON.string(result))\n"
        }
        return out
    }

    static func runJSON(_ view: RhaiWorkflowRunView) -> JSONValue {
        let record = view.record
        return .object([
            "run_id": .string(record.runID),
            "workflow_name": .string(record.workflowName),
            "status": .string(record.status.rawValue),
            "agent_budget": .number(.uint64(record.agentBudget)),
            "agents_used": .number(.uint64(record.agentsUsed)),
            "journal_path": record.journalPath.map(JSONValue.string) ?? .null,
            "message": record.message.map(JSONValue.string) ?? .null,
            "result": record.result ?? .null,
            "current_phase": view.currentPhase.map(JSONValue.string) ?? .null,
            "phases": .array(view.phases.map(JSONValue.string)),
            "agents": .array(view.agents.map { agent in
                .object([
                    "seq": .number(.uint64(agent.seq)),
                    "agent_id": agent.agentID.map(JSONValue.string) ?? .null,
                    "label": agent.label.map(JSONValue.string) ?? .null,
                    "state": .string(agent.state.label),
                    "tokens_used": .number(.uint64(agent.tokensUsed)),
                ])
            }),
        ])
    }

    static func renderJSON(_ value: JSONValue) -> String {
        RhaiCanonicalJSON.string(value) + "\n"
    }
}
