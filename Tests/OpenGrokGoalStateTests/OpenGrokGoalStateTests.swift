import Foundation
import Testing
@testable import OpenGrokGoalState

@Suite("Goal state lifecycle")
struct OpenGrokGoalStateTests {
    @Test("create, cancel, resume, and complete preserve deterministic lifecycle state")
    func lifecycleTransitions() throws {
        let sessionDirectory = temporaryDirectory("goal-lifecycle")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var tracker = GoalTracker(sessionDirectory: sessionDirectory)
        tracker.createGoal(goalID: "goal-1", objective: "ship it", tokenBaseline: 10, createdAt: "2026-01-01T00:00:00Z")

        let created = try #require(tracker.snapshot())
        #expect(created.status == .active)
        #expect(created.phase == .executing)
        #expect(created.lastSessionTokensSeen == 10)
        #expect(created.history.last?.event == .goalCreated)
        #expect(created.scratchDirectoryReady)

        tracker.setCurrentSubagent(id: "worker-1", role: "implementer")
        let cancelled = tracker.cancel()
        #expect(cancelled)
        #expect(tracker.status == .userPaused)
        #expect(tracker.snapshot()?.phase == .executing)
        #expect(tracker.snapshot()?.history.last?.detail == "user")

        let resumedGoal = tracker.resume()
        #expect(resumedGoal)
        #expect(tracker.status == .active)
        #expect(tracker.snapshot()?.pauseMessage == nil)
        #expect(tracker.snapshot()?.currentSubagentID == "worker-1")

        let completedGoal = tracker.complete()
        #expect(completedGoal)
        #expect(tracker.status == .complete)
        #expect(tracker.phase == .idle)
        #expect(tracker.currentSubagentID == nil)
        #expect(tracker.snapshot()?.history.last?.event == .goalCompleted)
        let completedAgain = tracker.complete()
        #expect(!completedAgain)
        #expect(!FileManager.default.fileExists(atPath: scratchDirectory(for: created.verifierID).path))
    }

    @Test("pause reasons, blocked messages, and terminal transitions clear state symmetrically")
    func pauseAndTerminalState() throws {
        let sessionDirectory = temporaryDirectory("goal-pause")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var tracker = GoalTracker(sessionDirectory: sessionDirectory)
        tracker.createGoal(goalID: "goal-2", objective: "diagnose", createdAt: "2026-01-01T00:00:00Z")
        let planBaselinePath = tracker.planBaselinePath()
        let strategyPath = tracker.strategyPath()
        tracker.modifySnapshot { snapshot in
            snapshot.skeptic0SessionID = "skeptic-0"
            snapshot.skepticModelAssignment = [GoalRoleModel(model: "model-a", agentType: "skeptic")]
            snapshot.planBaselineFile = planBaselinePath
            snapshot.lastStrategyPath = strategyPath
            snapshot.lastStrategyRecommendation = "split the work"
            snapshot.consecutiveNotAchieved = 4
            snapshot.lastStrategistFiredAt = 4
            snapshot.strategistCapBonus = goalStrategistCapBonus
            snapshot.evaluatorBlockerKey = "missing-access"
            snapshot.evaluatorBlockedStreak = 2
        }

        let infraPaused = tracker.pauseWithMessage(.infra, message: "rate limited")
        #expect(infraPaused)
        #expect(tracker.status == .infraPaused)
        #expect(tracker.snapshot()?.pauseMessage == "rate limited")
        let resumedAfterInfraPause = tracker.resume()
        #expect(resumedAfterInfraPause)
        let resumed = try #require(tracker.snapshot())
        #expect(resumed.status == .active)
        #expect(resumed.pauseMessage == nil)
        #expect(resumed.classifierRunsAttempted == 0)
        #expect(resumed.roundsSinceVerify == 0)
        #expect(resumed.consecutiveNotAchieved == 0)
        #expect(resumed.lastStrategistFiredAt == 0)
        #expect(resumed.strategistCapBonus == 0)
        #expect(resumed.lastStrategyPath == nil)
        #expect(resumed.lastStrategyRecommendation == nil)
        #expect(resumed.evaluatorBlockerKey == nil)
        #expect(resumed.evaluatorBlockedStreak == 0)

        let verificationPaused = tracker.pause(.verification)
        #expect(verificationPaused)
        #expect(tracker.status == .blocked)
        let completedAfterVerificationPause = tracker.complete()
        #expect(completedAfterVerificationPause)
        #expect(tracker.status == .complete)
        #expect(tracker.snapshot()?.pauseMessage == nil)
        #expect(tracker.snapshot()?.skeptic0SessionID == nil)
        #expect(tracker.snapshot()?.skepticModelAssignment.isEmpty == true)
        #expect(tracker.snapshot()?.planBaselineFile == nil)
    }

    @Test("restore makes in-flight active goals idle and safely paused")
    func restoreNormalizesInFlightState() throws {
        let sessionDirectory = temporaryDirectory("goal-restore")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var snapshot = GoalOrchestration(
            goalID: "goal-3",
            objective: "resume safely",
            status: .active,
            phase: .planning,
            createdAt: "2026-01-01T00:00:00Z",
            currentSubagentID: "old-worker",
            currentSubagentRole: "planner",
            verifierID: "abcdef012345",
            planningInFlight: true,
            verifyingInFlight: true
        )
        snapshot.skeptic0SessionID = "old-skeptic"

        let tracker = GoalTracker.fromSnapshot(sessionDirectory: sessionDirectory, snapshot: snapshot)
        let restored = try #require(tracker.snapshot())
        #expect(restored.status == .userPaused)
        #expect(restored.phase == .idle)
        #expect(restored.currentSubagentID == nil)
        #expect(restored.currentSubagentRole == nil)
        #expect(restored.skeptic0SessionID == nil)
        #expect(!restored.planningInFlight)
        #expect(!restored.verifyingInFlight)
        #expect(restored.scratchDirectoryReady)
        try? FileManager.default.removeItem(at: scratchDirectory(for: restored.verifierID))
    }

    @Test("history and token breakdowns retain bounded deterministic ordering")
    func boundedHistoryAndTokenOrdering() throws {
        let sessionDirectory = temporaryDirectory("goal-ordering")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var tracker = GoalTracker(sessionDirectory: sessionDirectory)
        tracker.createGoal(goalID: "goal-4", objective: "measure", createdAt: "2026-01-01T00:00:00Z")
        for index in 0..<70 {
            tracker.appendHistory(GoalHistoryEntry(timestamp: "\(index)", event: .workerCompleted))
        }
        let history = try #require(tracker.snapshot()?.history)
        #expect(history.count == goalHistoryMax)
        #expect(history.first?.timestamp == "6")
        #expect(history.last?.timestamp == "69")

        let sorted = GoalTracker.sortedTokenBreakdown([
            GoalTokenBreakdown(modelID: "zeta", tokens: 5),
            GoalTokenBreakdown(modelID: "alpha", tokens: 5),
            GoalTokenBreakdown(modelID: "zeta", tokens: 2),
            GoalTokenBreakdown(modelID: "beta", tokens: 8)
        ])
        #expect(sorted == [
            GoalTokenBreakdown(modelID: "beta", tokens: 8),
            GoalTokenBreakdown(modelID: "zeta", tokens: 7),
            GoalTokenBreakdown(modelID: "alpha", tokens: 5)
        ])

        let folded = GoalTracker.foldTokenBreakdown(
            records: [
                GoalTokenRecord(goalID: "goal-4", resumeAnchorCumulative: 10, lastCumulativeReported: 14, modelID: " model-a "),
                GoalTokenRecord(goalID: "goal-4", resumeAnchorCumulative: 0, lastCumulativeReported: 3, modelID: nil, finished: true),
                GoalTokenRecord(goalID: "goal-4", resumeAnchorCumulative: 4, lastCumulativeReported: 3, modelID: "model-b"),
                GoalTokenRecord(goalID: "other", resumeAnchorCumulative: 0, lastCumulativeReported: 100, modelID: "other")
            ],
            goalID: "goal-4",
            currentModelID: "current",
            includeFinished: false
        )
        #expect(folded == [GoalTokenBreakdown(modelID: "model-a", tokens: 4)])
    }

    @Test("progress update exposes live badges and classifier metadata")
    func progressUpdateMetadata() throws {
        let sessionDirectory = temporaryDirectory("goal-progress")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var tracker = GoalTracker(sessionDirectory: sessionDirectory)
        tracker.createGoal(goalID: "goal-5", objective: "report", createdAt: "2026-01-01T00:00:00Z")
        tracker.setCurrentSubagent(id: "worker", role: "implementer")
        tracker.modifySnapshot { snapshot in
            snapshot.liveSubagentTokens = 50
            snapshot.liveTokensByModel = [
                GoalTokenBreakdown(modelID: "model-b", tokens: 20),
                GoalTokenBreakdown(modelID: "model-a", tokens: 30)
            ]
            snapshot.liveContextPercent = 42
            snapshot.liveTurnCount = 3
            snapshot.liveToolCallCount = 7
            snapshot.lastClassifierDetailsPath = "/tmp/details.md"
            snapshot.planningInFlight = true
            snapshot.verifyingInFlight = true
        }
        let update = try #require(tracker.progressUpdate(tokensUsed: 100, finishedSubagentTokens: 25))
        #expect(update.currentSubagentRole == "implementer")
        #expect(update.liveTokensByModel.count == 2)
        #expect(update.lastClassifierDetailsPath == "/tmp/details.md")
        #expect(update.planning == true)
        #expect(update.verifyingCompletion == true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(update)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"phase\":\"executing\""))
        #expect(json.contains("\"current_subagent_role\":\"implementer\""))
        #expect(json.contains("\"last_classifier_details_path\":\"/tmp/details.md\""))
    }

    @Test("update input accepts Rust-compatible boolean forms and validates conflicts")
    func updateInputValidation() throws {
        let decoder = JSONDecoder()
        let truthyInputs = ["true", "\"true\"", "\" YES \"", "1", "1"]
        for raw in truthyInputs {
            let input = try decoder.decode(UpdateGoalInput.self, from: Data("{\"completed\":\(raw)}".utf8))
            #expect(input.completed == true)
        }
        let falseInput = try decoder.decode(UpdateGoalInput.self, from: Data(#"{"completed":null}"#.utf8))
        #expect(falseInput.completed == false)
        let missingInput = try decoder.decode(UpdateGoalInput.self, from: Data("{}".utf8))
        #expect(missingInput.completed == nil)
        #expect(throws: DecodingError.self) {
            try decoder.decode(UpdateGoalInput.self, from: Data(#"{"completed":"maybe"}"#.utf8))
        }

        #expect(throws: GoalUpdateValidationError.completionAndBlockConflict) {
            try UpdateGoalInput(completed: true, blockedReason: "blocked").validate()
        }
        #expect(throws: GoalUpdateValidationError.emptyBlockedReason) {
            try UpdateGoalInput(blockedReason: " \n ").validate()
        }
        #expect(UpdateGoalInput(completed: true, message: "done").summary == "Goal marked complete. done.")
    }

    @Test("apply update gates blocked attempts and completes only an active goal")
    func applyUpdateLifecycle() throws {
        let sessionDirectory = temporaryDirectory("goal-update")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var tracker = GoalTracker(sessionDirectory: sessionDirectory)
        tracker.createGoal(goalID: "goal-8", objective: "apply", createdAt: "2026-01-01T00:00:00Z")
        for attempt in 1...2 {
            let outcome = try tracker.applyUpdate(UpdateGoalInput(blockedReason: "same blocker"))
            if case .accepted = outcome {
                #expect(attempt < 3)
            } else {
                Issue.record("blocked attempt \(attempt) should remain accepted")
            }
        }
        let blocked = try tracker.applyUpdate(UpdateGoalInput(message: "no safe path", blockedReason: "same blocker"))
        if case .blocked(let summary) = blocked {
            #expect(summary == "Goal blocked: same blocker.")
        } else {
            Issue.record("third blocked attempt should pause the goal")
        }
        #expect(tracker.status == .blocked)
        #expect(throws: GoalUpdateValidationError.nonActiveGoal) {
            try tracker.applyUpdate(UpdateGoalInput(message: "late progress"))
        }

        let completingDirectory = temporaryDirectory("goal-update-complete")
        defer { try? FileManager.default.removeItem(at: completingDirectory) }
        var completingTracker = GoalTracker(sessionDirectory: completingDirectory)
        completingTracker.createGoal(goalID: "goal-9", objective: "finish", createdAt: "2026-01-01T00:00:00Z")
        let completed = try completingTracker.applyUpdate(UpdateGoalInput(completed: true, message: "all done"))
        if case .completed(let summary) = completed {
            #expect(summary == "Goal marked complete. all done.")
        } else {
            Issue.record("active completion update should complete the goal")
        }
        #expect(completingTracker.status == .complete)
        #expect(throws: GoalUpdateValidationError.nonActiveGoal) {
            try completingTracker.applyUpdate(UpdateGoalInput(completed: true))
        }
    }

    @Test("terminal rescue merges skeptic reports by attempt and index")
    func deterministicArtifactRescue() throws {
        let sessionDirectory = temporaryDirectory("goal-rescue")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var tracker = GoalTracker(sessionDirectory: sessionDirectory)
        tracker.createGoal(goalID: "goal-6", objective: "rescue", createdAt: "2026-01-01T00:00:00Z")
        let snapshot = try #require(tracker.snapshot())
        let root = scratchDirectory(for: snapshot.verifierID)
        let details = root.appendingPathComponent("goal-classifier-\(snapshot.verifierID)-2.md")
        try Data("canonical\n".utf8).write(to: details)
        try Data("attempt-1\n".utf8).write(to: root.appendingPathComponent("goal-classifier-\(snapshot.verifierID)-1-skeptic-0.md"))
        try Data("attempt-2-skeptic-1\n".utf8).write(to: root.appendingPathComponent("goal-classifier-\(snapshot.verifierID)-2-skeptic-1.md"))
        try Data("attempt-2-skeptic-0\n".utf8).write(to: root.appendingPathComponent("goal-classifier-\(snapshot.verifierID)-2-skeptic-0.md"))
        tracker.modifySnapshot { $0.lastClassifierDetailsPath = details.path }

        let completedForRescue = tracker.complete()
        #expect(completedForRescue)
        let completed = try #require(tracker.snapshot())
        let rescuedPath = try #require(completed.lastClassifierDetailsPath)
        let rescued = try String(contentsOfFile: rescuedPath, encoding: .utf8)
        #expect(rescued.contains("canonical"))
        #expect(rescued.range(of: "attempt-2-skeptic-0")!.lowerBound < rescued.range(of: "attempt-2-skeptic-1")!.lowerBound)
        #expect(rescued.range(of: "attempt-2-skeptic-1")!.lowerBound < rescued.range(of: "attempt-1")!.lowerBound)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("restore refuses a symlinked scratch root")
    func scratchSymlinkIsRejected() throws {
#if !os(Windows)
        let sessionDirectory = temporaryDirectory("goal-symlink")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let verifierID = "abcdef012346"
        let root = scratchDirectory(for: verifierID)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: sessionDirectory.path)

        let snapshot = GoalOrchestration(
            goalID: "goal-7",
            objective: "reject unsafe root",
            status: .active,
            createdAt: "2026-01-01T00:00:00Z",
            verifierID: verifierID
        )
        let tracker = GoalTracker.fromSnapshot(sessionDirectory: sessionDirectory, snapshot: snapshot)
        #expect(tracker.snapshot()?.scratchDirectoryReady == false)
#endif
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("open-grok-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func scratchDirectory(for verifierID: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("grok-goal-\(verifierID)", isDirectory: true)
    }
}
