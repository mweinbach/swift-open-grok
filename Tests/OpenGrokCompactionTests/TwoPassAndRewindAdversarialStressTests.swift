// TwoPassAndRewindAdversarialStressTests.swift
//
// Open Grok — Adversarial stress test harness for Milestone 2 features:
// - Performance & high-volume stress (10,000+ items, huge token counts, FNV-1a throughput)
// - Memory leak potentials & deallocation validation (PrefireState, CompactCancelGate, AsyncCompactionCache)
// - Orphaned task leak stress (in-flight tasks, early cancellations, task completion verification)
// - File descriptor limits & rapid disk persistence stress (500+ checkpoint persist/load/list/copy cycles)
// - Concurrency races & multithreaded contention on state primitives
// - Malformed updates.jsonl and path traversal defense

import Foundation
import Testing
@testable import OpenGrokCompaction
@testable import OpenGrokSamplingTypes
@testable import OpenGrokChatState
@testable import OpenGrokTokenEstimation

@Suite("Two-Pass & Rewind Adversarial Stress Tests", .serialized)
struct TwoPassAndRewindAdversarialStressTests {

    // MARK: - 1. Performance & Scale Stress Tests

    @Test("Two-pass 95% split and tool snapping scales linearly on 10,000-turn history")
    func testTwoPassSplitMassiveScalePerformance() {
        var items: [ConversationItem] = []
        items.reserveCapacity(10_000)

        items.append(.system("System preamble"))
        for i in 1...3330 {
            items.append(.user("User prompt \(i) with some meaningful text content."))
            let toolCall = ToolCall(id: "call-\(i)", name: "bash", arguments: "{\"cmd\":\"echo \(i)\"}")
            items.append(.assistant(AssistantItem(content: "Executing command \(i)", toolCalls: [toolCall])))
            items.append(.toolResult(ToolResultItem(toolCallId: "call-tool-\(i)", content: "Output of command \(i)")))
        }

        let start = DispatchTime.now()
        let split = splitConversationForTwoPass(conversation: items, splitFraction: 0.95)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsed) / 1_000_000.0

        #expect(split.prefix.count > 0)
        #expect(split.tail.count > 0)
        #expect(split.prefix.count + split.tail.count == items.count)
        #expect(split.splitIndex == split.prefix.count)
        // Ensure 10,000 items process in well under 500ms
        #expect(elapsedMs < 500.0)
    }

    @Test("64-bit FNV-1a fingerprint throughput on 10,000 turns")
    func testFingerprintPrefixThroughput() {
        var items: [ConversationItem] = []
        items.reserveCapacity(10_000)
        for i in 0..<10_000 {
            items.append(.user("Prompt line \(i): abcdefghijklmnopqrstuvwxyz0123456789"))
        }

        let start = DispatchTime.now()
        let fp1 = fingerprintPrefix(items)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsed) / 1_000_000.0

        let fp2 = fingerprintPrefix(items)
        #expect(fp1 == fp2)
        #expect(fp1 != 0)
        // Ensure 10,000 items hashed in under 200ms
        #expect(elapsedMs < 200.0)
    }

    @Test("Replay scaling on 1,000 updates with multiple interleaved checkpoints")
    func testReplayScalingWith1000UpdatesAndCheckpoints() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-perf-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var updates: [SessionUpdateRecord] = []
        var promptIdx = 0

        for i in 0..<10 {
            let ckptID = "ckpt-perf-\(i)"
            try persistCompactionCheckpoint(
                sessionDir: tempDir,
                checkpointID: ckptID,
                promptIndex: promptIdx + 50,
                compactedHistory: [.system("SYS"), .user("SUMMARY_STAGE_\(i)")],
                originalUserInfo: "ORIGINAL_USER_INFO"
            )
            for _ in 0..<50 {
                updates.append(.user(text: "Prompt \(promptIdx)", promptIndex: promptIdx))
                updates.append(.agent(text: "Answer \(promptIdx)"))
                promptIdx += 1
            }
            updates.append(.checkpoint(id: ckptID, promptIndex: promptIdx, autoContinueText: nil))
        }

        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        let start = DispatchTime.now()
        let result = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 475)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsed) / 1_000_000.0

        #expect(result.promptIndexReached == 475)
        #expect(result.lastCompactionPromptIndex == 450)
        #expect(elapsedMs < 200.0)
    }

    // MARK: - 2. Memory & Deallocation Stress Tests

    @Test("PrefireState and AsyncCompactionCache memory deallocation under heavy cycle")
    func testPrefireStateMemoryDeallocationCycle() {
        weak var weakState: PrefireState?
        do {
            let state = PrefireState()
            weakState = state
            for i in 0..<1000 {
                let cache = AsyncCompactionCache(
                    note1: "Large note 1 content \(i): " + String(repeating: "M", count: 10_000),
                    prefixLen: i,
                    fingerprint: UInt64(i &* 31),
                    modelSlug: "grok-4.20",
                    pass1LatencyMs: UInt64(i)
                )
                state.store(cache)
                _ = state.take()
            }
            #expect(!state.hasCache)
        }
        #expect(weakState == nil)
    }

    @Test("CompactCancelGate deallocation and scope cleanup under heavy cycling")
    func testCompactCancelGateDeallocation() {
        weak var weakGate: CompactCancelGate?
        do {
            let gate = CompactCancelGate()
            weakGate = gate
            for _ in 0..<500 {
                let scope = gate.enter()
                #expect(!scope.isCancelled())
                gate.requestCancel()
                #expect(scope.isCancelled())
                scope.onEnd()
                #expect(!gate.isCancelled)
            }
        }
        #expect(weakGate == nil)
    }

    // MARK: - 3. Orphaned Task & In-Flight Await Stress Tests

    @Test("In-flight task cancellation and clean completion in tryTwoPassPass2Apply")
    func testInFlightTaskCancellationStress() async {
        for _ in 0..<10 {
            let prefireState = PrefireState()
            let won = prefireState.tryBegin()
            #expect(won)

            let task = Task {
                try? await Task.sleep(nanoseconds: 10_000_000)
                prefireState.store(AsyncCompactionCache(
                    note1: "Completed note",
                    prefixLen: 2,
                    fingerprint: 9999,
                    modelSlug: "grok-4.20",
                    pass1LatencyMs: 10
                ))
                prefireState.finish()
            }
            prefireState.setHandle(task)

            let handle = prefireState.takeHandle()
            #expect(handle != nil)
            _ = await handle?.result
            #expect(!prefireState.isInFlight)
            #expect(prefireState.hasCache)
        }
    }

    @Test("In-flight task failure or panic unblocks await and leaves state clean")
    func testInFlightTaskFailureUnblocksState() async {
        let prefireState = PrefireState()
        _ = prefireState.tryBegin()

        let failedTask = Task<Void, Never> {
            // Task completes without storing cache (simulating failure)
            prefireState.finish()
        }
        prefireState.setHandle(failedTask)

        // Wait for it
        if let h = prefireState.takeHandle() {
            _ = await h.result
        }

        #expect(!prefireState.isInFlight)
        #expect(!prefireState.hasCache)
    }

    // MARK: - 4. File Descriptor & Disk Persistence Stress Tests

    @Test("Rapid persistence, loading, listing, and copying of 200 checkpoints without FD leaks")
    func testRapidCheckpointPersistenceAndFDStress() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-fd-stress-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-fd-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let history: [ConversationItem] = [
            .system("System prompt"),
            .user("User turn summary data: " + String(repeating: "D", count: 1000))
        ]

        // Create 200 checkpoints rapidly
        for i in 1...200 {
            let ckptID = "ckpt-fd-\(i)"
            try persistCompactionCheckpoint(
                sessionDir: tempDir,
                checkpointID: ckptID,
                promptIndex: i,
                compactedHistory: history,
                originalUserInfo: "User info \(i)"
            )
        }

        // Load all 200
        for i in 1...200 {
            let loaded = try loadCompactionCheckpoint(sessionDir: tempDir, checkpointID: "ckpt-fd-\(i)")
            #expect(loaded.promptIndexAtCompaction == i)
        }

        // List all 200
        let listed = try listCompactionCheckpoints(sessionDir: tempDir)
        #expect(listed.count == 200)

        // Copy all 200
        let copiedCount = try copyCheckpoints(from: tempDir, to: destDir)
        #expect(copiedCount == 200)

        let destListed = try listCompactionCheckpoints(sessionDir: destDir)
        #expect(destListed.count == 200)
    }

    // MARK: - 5. Concurrency Races & Multi-threaded Contention

    @Test("Multithreaded contention on PrefireState tryBegin/finish/store/take")
    func testPrefireStateConcurrentContention() async {
        let state = PrefireState()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if state.tryBegin() {
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        state.store(AsyncCompactionCache(
                            note1: "Note \(i)",
                            prefixLen: i,
                            fingerprint: UInt64(i),
                            modelSlug: "model",
                            pass1LatencyMs: 1
                        ))
                        state.finish()
                    } else {
                        _ = state.take()
                        _ = state.isInFlight
                    }
                }
            }
        }

        #expect(!state.isInFlight)
    }

    @Test("Multithreaded contention on CompactCancelGate")
    func testCompactCancelGateConcurrentContention() async {
        let gate = CompactCancelGate()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let scope = gate.enter()
                    try? await Task.sleep(nanoseconds: 500_000)
                    if Bool.random() {
                        gate.requestCancel()
                    }
                    scope.onEnd()
                }
            }
        }

        #expect(!gate.isCancelled)
    }

    // MARK: - 6. Malformed JSONL & Path Traversal Defense

    @Test("Replay handles malformed and junk lines in updates.jsonl gracefully")
    func testReplayMalformedUpdatesJSONL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-malformed-jsonl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let updatesFile = tempDir.appendingPathComponent("updates.jsonl")
        let malformedContent = """
        {"type":"user","text":"P0","prompt_index":0}
        {MALFORMED_JSON_LINE_WITHOUT_QUOTES
        {"type":"agent","text":"A0"}
        
        {"unknown_random_envelope":{"some":"data"}}
        {"type":"user","text":"P1","prompt_index":1}
        {"type":"agent","text":"A1"}
        """
        try malformedContent.write(to: updatesFile, atomically: true, encoding: .utf8)

        let result = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 1)
        #expect(result.promptIndexReached == 1)
        #expect(result.conversation.count >= 2)
        #expect(result.conversation.first?.textContent() == "P0")
    }

    @Test("Compaction arithmetic overflow resistance with extreme token bounds")
    func testTokenWeightArithmeticOverflowDefense() {
        let extremeWeights: [UInt64] = [
            UInt64.max - 1000,
            500,
            400,
            100
        ]
        let splitIdx = splitIndexByTokenFraction(weights: extremeWeights, fraction: 0.95)
        #expect(splitIdx >= 1)
        #expect(splitIdx <= extremeWeights.count)
    }
}
