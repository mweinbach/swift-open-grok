// WorkflowManifestVersionTests.swift
//
// Golden fixtures for workflow-run manifest version handling at pin 80dff0a9.
//
// Provenance:
//   * `WORKFLOW_RUN_MANIFEST_VERSION`, `MAX_RESTORED_WORKFLOW_RUNS` —
//     `crates/codegen/xai-grok-shell/src/session/workflow/store.rs:13-16`
//   * range check `1..=WORKFLOW_RUN_MANIFEST_VERSION` —
//     `crates/codegen/xai-grok-shell/src/session/storage/jsonl/mod.rs:714-723`
//   * outdated-manifest downgrade — store.rs:100-112

import Foundation
import Testing
@testable import OpenGrokSessionPersistence
import OpenGrokShared

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wf-manifest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeManifest(_ dir: URL, _ json: String) throws {
    try Data(json.utf8).write(to: dir.appendingPathComponent(WorkflowSessionStore.manifestName))
}

@Suite("Workflow manifest version constants")
struct WorkflowManifestVersionConstantTests {
    /// store.rs:13. Bumping this in Swift without bumping Rust would make
    /// Swift-written manifests unreadable by the reference implementation.
    @Test("current version and supported range match the Rust constants")
    func constants() {
        #expect(workflowRunManifestVersion == 4)
        #expect(supportedWorkflowRunManifestVersions == 1...4)
    }

    /// The check is a **range**, not equality: versions 1 through 4 all load,
    /// 0 and 5 do not (jsonl/mod.rs:714-717).
    @Test("version 0 and a future version are outside the supported range")
    func rangeBoundaries() {
        #expect(!supportedWorkflowRunManifestVersions.contains(0))
        #expect(supportedWorkflowRunManifestVersions.contains(1))
        #expect(supportedWorkflowRunManifestVersions.contains(4))
        #expect(!supportedWorkflowRunManifestVersions.contains(5))
    }
}

@Suite("Workflow manifest load")
struct WorkflowManifestLoadTests {
    /// A manifest written by a newer build must be skipped, not loaded — this
    /// is what stops this build reinterpreting a future schema under its own
    /// assumptions (jsonl/mod.rs:714-723).
    @Test("an out-of-range version is skipped while in-range siblings load")
    func outOfRangeSkipped() async throws {
        let dir = try tempDir()
        try writeManifest(dir, """
        [
          {"version":4,"run_id":"ok","workflow_name":"w","script_hash":"s",
           "arguments_hash":"a","status":"paused","agent_budget":8,"agents_used":1,
           "revision":2,"completion_delivered":false,"created_at_ms":100},
          {"version":5,"run_id":"future","workflow_name":"w","script_hash":"s",
           "arguments_hash":"a","status":"paused","agent_budget":8,"agents_used":1,
           "revision":2,"completion_delivered":false,"created_at_ms":200},
          {"version":0,"run_id":"unversioned","workflow_name":"w","script_hash":"s",
           "arguments_hash":"a","status":"paused","agent_budget":8,"agents_used":1,
           "revision":2,"completion_delivered":false,"created_at_ms":300}
        ]
        """)
        let store = WorkflowSessionStore(directory: dir)
        let loaded = try await store.load()
        #expect(loaded.map(\.runID) == ["ok"])
    }

    /// A file predating the `version` field decodes as version 1 — the oldest
    /// supported version — rather than 0, which would be unloadable.
    @Test("a manifest with no version field decodes as version 1")
    func absentVersionIsOne() async throws {
        let dir = try tempDir()
        try writeManifest(dir, """
        [{"run_id":"legacy","workflow_name":"w","script_hash":"s","arguments_hash":"a",
          "status":"paused","agent_budget":8,"agents_used":1,"revision":0,
          "completion_delivered":false,"created_at_ms":100}]
        """)
        let store = WorkflowSessionStore(directory: dir)
        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].version == 1)
        #expect(loaded[0].versionIsSupported)
    }

    /// Keys this build does not model must survive a load/store round trip,
    /// so a Swift session cannot silently strip fields a Rust build wrote.
    @Test("unknown manifest keys survive a load and re-persist")
    func unknownKeysPreserved() async throws {
        let dir = try tempDir()
        try writeManifest(dir, """
        [{"version":4,"run_id":"r1","workflow_name":"w","script_hash":"s","arguments_hash":"a",
          "status":"paused","agent_budget":8,"agents_used":1,"revision":0,
          "completion_delivered":false,"created_at_ms":100,
          "script_revision":3,"future_knob":{"nested":true}}]
        """)
        let store = WorkflowSessionStore(directory: dir)
        let loaded = try await store.load()
        #expect(loaded[0].extra["script_revision"]?.doubleValue == 3)
        #expect(loaded[0].extra["future_knob"] != nil)

        var record = loaded[0]
        record.message = "touched"
        try await store.update(record)

        let reloaded = try await WorkflowSessionStore(directory: dir).load()
        #expect(reloaded[0].extra["script_revision"]?.doubleValue == 3)
        #expect(reloaded[0].extra["future_knob"] != nil)
    }
}

@Suite("Workflow manifest restore")
struct WorkflowManifestRestoreTests {
    /// store.rs:100-112: a manifest below the current version predates
    /// agent-count accounting. It is loadable but must not be resumed, and
    /// its usage figures must be cleared and marked incomplete rather than
    /// trusted.
    @Test("an outdated but in-range manifest is interrupted, not resumed")
    func outdatedIsInterrupted() async throws {
        let dir = try tempDir()
        try writeManifest(dir, """
        [{"version":3,"run_id":"old","workflow_name":"w","script_hash":"s","arguments_hash":"a",
          "status":"paused","agent_budget":8,"agents_used":5,"revision":2,
          "completion_delivered":false,"created_at_ms":100}]
        """)
        let store = WorkflowSessionStore(directory: dir)
        let restored = try await store.restore()

        #expect(restored.count == 1)
        let r = restored[0]
        #expect(r.status == .interrupted)
        #expect(!r.status.isResumable)
        #expect(r.message == workflowManifestPredatesAgentAccountingMessage)
        #expect(r.agentBudget == 0)
        #expect(r.agentsUsed == 0)
        #expect(r.agentUsageIncomplete)
        #expect(r.version == workflowRunManifestVersion)
        #expect(r.revision == 3)
        #expect(r.completionDelivered)
    }

    /// A current-version run keeps the pre-existing active-run behaviour: it
    /// is interrupted because the session ended, with the session-ended
    /// message rather than the version message.
    @Test("a current-version active run keeps the session-ended message")
    func currentVersionActiveRun() async throws {
        let dir = try tempDir()
        try writeManifest(dir, """
        [{"version":4,"run_id":"live","workflow_name":"w","script_hash":"s","arguments_hash":"a",
          "status":"active","agent_budget":8,"agents_used":5,"revision":0,
          "completion_delivered":false,"created_at_ms":100}]
        """)
        let restored = try await WorkflowSessionStore(directory: dir).restore()
        #expect(restored[0].status == .interrupted)
        #expect(restored[0].message != workflowManifestPredatesAgentAccountingMessage)
        #expect(!restored[0].agentUsageIncomplete)
        #expect(restored[0].agentBudget == 8)
    }

    /// A current-version paused run is untouched by restore and stays
    /// resumable.
    @Test("a current-version paused run stays resumable")
    func currentVersionPausedRun() async throws {
        let dir = try tempDir()
        try writeManifest(dir, """
        [{"version":4,"run_id":"paused","workflow_name":"w","script_hash":"s","arguments_hash":"a",
          "status":"paused","agent_budget":8,"agents_used":5,"revision":1,
          "completion_delivered":false,"created_at_ms":100}]
        """)
        let restored = try await WorkflowSessionStore(directory: dir).restore()
        #expect(restored[0].status == .paused)
        #expect(restored[0].status.isResumable)
        #expect(restored[0].revision == 1)
    }
}
