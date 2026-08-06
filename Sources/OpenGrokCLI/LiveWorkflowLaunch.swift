// LiveWorkflowLaunch.swift
//
// Binds an already-composed live session to the background workflow registry.
//
// By the time this runs the launcher has resolved everything a child agent
// needs — provider, model, workspace root, agent profile, process backend — so
// this file does not compose anything of its own. That is the point: a workflow
// agent runs against exactly the session the user launched, not a parallel
// stack that could drift from it.

import Foundation
import OpenGrokAgentDefinitions
import OpenGrokFileTools
import OpenGrokSessionPersistence
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokToolRegistry
import OpenGrokWorkflow

enum LiveWorkflowLaunch {
    /// Everything the launcher already holds, gathered so the signature does
    /// not grow a dozen loose parameters.
    struct Session: Sendable {
        let sampler: OpenGrokLiveSampler
        let model: String
        let workspaceRoot: URL
        let sessionID: String
        let openGrokHome: URL
        let telemetryBootstrapContext: LiveTelemetryBootstrapContext
        let systemPrompt: String?
        let toolPolicy: LiveAgentToolPolicy?
        let fileAccessPolicy: FileToolAccessPolicy
        let makeProcessBackend: @Sendable () -> any ShellProcessBackend
        let environment: [String: String]
    }

    /// The parent session's capability ceiling. A workflow child can narrow it
    /// and can never widen it.
    static func parentCapabilityMode(for policy: LiveAgentToolPolicy?) -> ToolCapabilityMode {
        switch policy?.capabilityMode {
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        case .execute: return .execute
        case .all: return .all
        case nil: return .readWrite
        }
    }

    static func agentCapability(_ mode: ToolCapabilityMode) -> AgentCapabilityMode {
        switch mode {
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        case .execute: return .execute
        case .all: return .all
        }
    }

    /// A registry rooted at this session's `OPENGROK_HOME`, sharing the manifest
    /// and journals with every other process on the same home.
    static func makeRegistry(openGrokHome: URL) -> RhaiWorkflowRunRegistry {
        RhaiWorkflowRunRegistry(store: WorkflowSessionStore(directory: openGrokHome))
    }

    /// Start `script` in the background. Returns the run's record immediately;
    /// the run itself proceeds on the registry's own task.
    @discardableResult
    static func start(
        script: String,
        workflowName: String? = nil,
        arguments: JSONValue = .object([:]),
        agentBudget: UInt64 = rhaiDefaultAgentBudget,
        maxConcurrentAgents: Int = 8,
        registry: RhaiWorkflowRunRegistry,
        session: Session
    ) async throws -> WorkflowRunRecord {
        try await registry.start(
            script: script,
            workflowName: workflowName,
            arguments: arguments,
            agentBudget: agentBudget,
            hostFactory: hostFactory(
                session: session,
                maxConcurrentAgents: maxConcurrentAgents
            )
        )
    }

    /// How a run gets its host.
    ///
    /// Tool surfaces are built lazily, inside the host, and torn down when the
    /// run ends — a workflow that never spawns an agent never starts an MCP
    /// server, and one that does releases them at its terminal outcome rather
    /// than at process exit.
    static func hostFactory(
        session: Session,
        maxConcurrentAgents: Int = 8
    ) -> RhaiWorkflowHostFactory {
        let teardown = LiveWorkflowTeardownRegistry()
        return RhaiWorkflowHostFactory(
            make: { context in
                let scratchRoot = session.openGrokHome
                    .appendingPathComponent("workflow-scratch", isDirectory: true)
                    .appendingPathComponent(context.runID, isDirectory: true)
                let environment = LiveWorkflowAgentEnvironment(
                    sampler: session.sampler,
                    model: session.model,
                    workspaceRoot: session.workspaceRoot,
                    systemPrompt: session.systemPrompt,
                    parentCapabilityMode: parentCapabilityMode(for: session.toolPolicy),
                    makeInvoker: { mode in
                        let executor = try await LiveToolExecutor(
                            processBackend: session.makeProcessBackend(),
                            // Child agents get their own session id so their
                            // background tasks and hook state never collide
                            // with the parent's.
                            sessionID: "\(session.sessionID)-wf-\(context.runID)-\(mode.rawValue)",
                            workingDirectory: session.workspaceRoot,
                            toolPolicy: clampedPolicy(session.toolPolicy, to: mode),
                            telemetryBootstrapContext: session.telemetryBootstrapContext,
                            fileAccessPolicy: session.fileAccessPolicy,
                            environment: session.environment
                        )
                        await teardown.add(runID: context.runID, executor: executor)
                        return executor
                    }
                )
                return LiveWorkflowHost(
                    context: context,
                    environment: environment,
                    scratchRoot: scratchRoot,
                    maxConcurrentAgents: maxConcurrentAgents
                )
            },
            finish: { context in
                await teardown.shutdown(runID: context.runID)
            }
        )
    }

    /// The parent's policy with its capability mode replaced by the clamped
    /// one. Every allow/deny list is carried through unchanged, so a child is
    /// always a subset of the parent by construction rather than by a second
    /// filter that could drift.
    static func clampedPolicy(
        _ policy: LiveAgentToolPolicy?,
        to mode: ToolCapabilityMode
    ) -> LiveAgentToolPolicy? {
        guard let policy else {
            // No agent profile means no configured tool list to intersect with.
            // A narrowed mode still has to bite, so it is expressed as a policy
            // whose only constraint is the capability mode.
            guard mode != .readWrite else { return nil }
            return LiveAgentToolPolicy(unrestrictedWith: agentCapability(mode))
        }
        return policy.withCapabilityMode(agentCapability(mode))
    }
}

/// Tool executors a run built, so they can be shut down when it ends.
actor LiveWorkflowTeardownRegistry {
    private var executors: [String: [LiveToolExecutor]] = [:]

    func add(runID: String, executor: LiveToolExecutor) {
        executors[runID, default: []].append(executor)
    }

    func shutdown(runID: String) async {
        let pending = executors.removeValue(forKey: runID) ?? []
        for executor in pending {
            await executor.shutdown()
        }
    }
}
