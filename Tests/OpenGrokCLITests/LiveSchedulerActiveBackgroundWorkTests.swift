// LiveSchedulerActiveBackgroundWorkTests.swift
//
// Status-chip push events from `LiveSchedulerHost` through the live
// `LiveActiveBackgroundWorkSink` seam (AGENTS.md §3). Rust
// `TasksPane::running_count` (`tasks_pane.rs:1132-1149`) counts
// `scheduled.len()` — every provisional + live entry, not only a currently
// firing Cron. No polling: every event is awaited on a host mutation edge.
//
// Provisional→durable and sink install use atomic `.replace`; independent
// create/delete/expiry keep `.upsert` / `.remove`.
//
// Fixed clocks; never sleep a scheduler interval.

import Foundation
import OpenGrokScheduler
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class ABWTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { now = start }

    var current: Date {
        lock.withLock { now }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { now = now.addingTimeInterval(seconds) }
    }
}

/// Records every sink event in delivery order and mirrors them into a cache
/// so tests assert both the push sequence and the chip membership.
private actor ABWEventCollector {
    private(set) var events: [LiveActiveBackgroundWorkEvent] = []
    private var cache = LiveActiveBackgroundWorkCache()

    var scheduledCount: Int { cache.count(of: .scheduled) }
    var totalCount: Int { cache.count }

    func record(_ event: LiveActiveBackgroundWorkEvent) {
        events.append(event)
        cache.apply(event)
    }

    /// Drop the recorded sequence only. Keeps chip membership so a later
    /// phase can assert deltas against still-visible ids (e.g. create then
    /// provisional → count 2). Use this between lifecycle stages.
    func clearEvents() {
        events.removeAll()
    }

    /// Drop both the sequence and membership. Only for phases where the
    /// mirrored cache is truly empty again, or before a sink reinstall that
    /// will reseed. Never use while host ids remain visible — a subsequent
    /// upsert would under-count.
    func reset() {
        events.removeAll()
        cache.removeAll()
    }

    /// Scheduled ids carried by the recorded events (upsert/remove one id;
    /// replace contributes its full set).
    func scheduledIDsInOrder() -> [String] {
        events.flatMap { event -> [String] in
            switch event {
            case .upsert(let key) where key.kind == .scheduled:
                return [key.id]
            case .remove(let key) where key.kind == .scheduled:
                return [key.id]
            case .replace(let kind, let ids) where kind == .scheduled:
                return ids.sorted()
            default:
                return []
            }
        }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private struct TempPersistence {
    let directory: URL
    let persistence: LiveSchedulerPersistence

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-sched-abw-\(UUID().uuidString)", isDirectory: true)
        guard let persistence = LiveSchedulerPersistence.forSessionDirectory(directory) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.persistence = persistence
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeTasks(_ tasks: [ScheduledTask]) throws {
        let encoded = try tasks.map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }
        let document: [String: Any] = [
            "state": ["grok_build.Scheduler": ["tasks": encoded]],
        ]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: persistence.stateFileURL)
    }
}

// MARK: - Suite

@Suite("scheduler active background work")
struct LiveSchedulerActiveBackgroundWorkTests {

    @Test("create upserts; list stays counted; delete removes")
    func createListDelete() async throws {
        let clock = ABWTestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current })
        let collector = ABWEventCollector()
        await host.setActiveBackgroundWorkSink { await collector.record($0) }
        // Empty atomic seed — drop it so the create edge stands alone.
        await collector.clearEvents()

        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "check deploy",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: task.id))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(kind: .scheduled, id: task.id))
        #expect(await collector.scheduledCount == 1)
        #expect(await host.list().map(\.id) == [task.id])
        #expect(await collector.events == [upsert])

        #expect(try await host.deleteTask(id: task.id))
        #expect(await host.list().isEmpty)
        #expect(await collector.scheduledCount == 0)
        #expect(await collector.events.last == remove)
    }

    @Test("provisional→durable emits one replace; count never transiently 0 or 2")
    func provisionalReplacementOneReplace() async throws {
        let clock = ABWTestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current })
        let collector = ABWEventCollector()
        await host.setActiveBackgroundWorkSink { await collector.record($0) }
        await collector.clearEvents()

        await host.insertProvisional(prompt: "check deploy", humanSchedule: "scheduling…")
        let provisionalID = try #require(await host.displayInfos().first?.taskId)
        #expect(provisionalID.hasPrefix("provisional-"))
        #expect(await collector.scheduledCount == 1)
        await collector.clearEvents()

        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "check deploy",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        let events = await collector.events
        let expected = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: [task.id]
        )
        #expect(events == [expected], "provisional→durable must be one atomic replace")

        // Applying the lone replace onto a cache that already held the
        // provisional never paints 0 or 2.
        var side = LiveActiveBackgroundWorkCache()
        _ = side.apply(
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: provisionalID))
        )
        #expect(side.count(of: .scheduled) == 1)
        _ = side.apply(expected)
        #expect(side.count(of: .scheduled) == 1)
        #expect(await collector.scheduledCount == 1)
        #expect(await host.displayInfos().map(\.taskId) == [task.id])
    }

    @Test("sink install after load publishes one replace of every restored id")
    func loadExistingPublishesOnInstall() async throws {
        let workspace = try TempPersistence()
        defer { workspace.cleanup() }
        let seedClock = ABWTestClock(t0)
        let seed = LiveSchedulerHost(clock: { seedClock.current }, persistence: workspace.persistence)
        let first = try await seed.createTask(
            intervalSecs: 300, prompt: "a", durable: true,
            foreground: true, fireImmediately: false
        )
        seedClock.advance(by: 1)
        let second = try await seed.createTask(
            intervalSecs: 600, prompt: "b", durable: false,
            foreground: true, fireImmediately: false
        )

        let host = LiveSchedulerHost(clock: { seedClock.current }, persistence: workspace.persistence)
        #expect(await host.list().map(\.id) == [first.id, second.id])

        let collector = ABWEventCollector()
        await host.setActiveBackgroundWorkSink { await collector.record($0) }

        let seedReplace = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: [first.id, second.id]
        )
        #expect(await collector.scheduledCount == 2)
        #expect(await collector.events == [seedReplace])
        #expect(Set(await collector.scheduledIDsInOrder()) == [first.id, second.id])
    }

    @Test("recurring expiry and one-shot fire removal emit scheduled removes")
    func expiryAndOneShotRemoval() async throws {
        // Recurring non-durable expiry (actor.rs:395-404).
        let clock = ABWTestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current })
        let collector = ABWEventCollector()
        await host.setActiveBackgroundWorkSink { await collector.record($0) }
        await host.setFireSink { _ in }

        let recurring = try await host.createTask(
            intervalSecs: 60,
            prompt: "expire me",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        // Task still visible — clear the sequence only so the expiry remove
        // actually drops mirrored membership to zero.
        await collector.clearEvents()

        let expiredAt = t0.addingTimeInterval(7 * 86_400)
        let fires = await host.fireDue(now: expiredAt)
        let recurringRemove = try #require(
            LiveActiveBackgroundWorkEvent.remove(kind: .scheduled, id: recurring.id)
        )
        #expect(fires.isEmpty)
        #expect(await host.list().isEmpty)
        #expect(await collector.events == [recurringRemove])
        #expect(await collector.scheduledCount == 0)

        // One-shot (legacy decoded) removal at fire (actor.rs:294, 410-412).
        let workspace = try TempPersistence()
        defer { workspace.cleanup() }
        var oneShot = ScheduledTask(
            intervalSecs: 60,
            prompt: "once",
            recurring: false,
            durable: false,
            fireImmediately: true,
            now: t0
        )
        oneShot.id = "oneshot01cafe"
        try workspace.writeTasks([oneShot])

        let oneShotHost = LiveSchedulerHost(
            clock: { t0 },
            persistence: workspace.persistence
        )
        let oneShotCollector = ABWEventCollector()
        await oneShotHost.setActiveBackgroundWorkSink { await oneShotCollector.record($0) }
        #expect(await oneShotCollector.scheduledCount == 1)
        await oneShotCollector.clearEvents()

        await oneShotHost.setFireSink { _ in }
        // setFireSink runs fireDue; the due one-shot is removed at fire.
        let oneShotRemove = try #require(
            LiveActiveBackgroundWorkEvent.remove(kind: .scheduled, id: oneShot.id)
        )
        #expect(await oneShotHost.list().isEmpty)
        #expect(await oneShotCollector.events.contains(oneShotRemove))
        #expect(await oneShotCollector.scheduledCount == 0)
    }

    @Test("shutdown removes every still-visible scheduled id")
    func shutdownClearsChip() async throws {
        let clock = ABWTestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current })
        let collector = ABWEventCollector()
        await host.setActiveBackgroundWorkSink { await collector.record($0) }
        await collector.clearEvents()

        await host.insertProvisional(prompt: "preview", humanSchedule: "scheduling…")
        let provisionalID = try #require(await host.displayInfos().first?.taskId)
        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "live",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        // After create, only the durable id remains visible (via replace).
        #expect(await collector.scheduledCount == 1)
        await collector.clearEvents()

        await host.insertProvisional(prompt: "again", humanSchedule: "scheduling…")
        let secondProvisional = try #require(
            await host.displayInfos().first(where: { $0.taskId.hasPrefix("provisional-") })?.taskId
        )
        // Durable id still mirrored — provisional upsert must yield 2.
        #expect(await collector.scheduledCount == 2)
        await collector.clearEvents()

        await host.shutdown()
        let removed = Set(await collector.events.compactMap { event -> String? in
            switch event {
            case .remove(let key) where key.kind == .scheduled:
                return key.id
            default:
                return nil
            }
        })
        #expect(removed == [task.id, secondProvisional])
        #expect(await collector.scheduledCount == 0)
        #expect(!removed.contains(provisionalID), "already-replaced provisional must not re-remove")
    }

    @Test("replacing or clearing the sink never delivers later events to the old sink")
    func sinkReplacementDoesNotLeak() async throws {
        let clock = ABWTestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current })
        let first = ABWEventCollector()
        let second = ABWEventCollector()

        await host.setActiveBackgroundWorkSink { await first.record($0) }
        await first.clearEvents()
        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "owned by first",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        #expect(await first.scheduledCount == 1)

        // Replacement publishes one atomic replace to the NEW sink only.
        await host.setActiveBackgroundWorkSink { await second.record($0) }
        let reseed = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: [task.id]
        )
        #expect(await second.scheduledCount == 1)
        #expect(await second.events == [reseed])
        let firstCountAfterReplace = await first.events.count

        let other = try await host.createTask(
            intervalSecs: 600,
            prompt: "owned by second",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        let otherUpsert = try #require(
            LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: other.id)
        )
        #expect(await first.events.count == firstCountAfterReplace, "old sink must not see post-replace creates")
        #expect(await second.events.contains(otherUpsert))

        await host.setActiveBackgroundWorkSink(nil)
        let secondCountAfterClear = await second.events.count
        _ = try await host.createTask(
            intervalSecs: 120,
            prompt: "nobody",
            durable: false,
            foreground: true,
            fireImmediately: false
        )
        #expect(await first.events.count == firstCountAfterReplace)
        #expect(await second.events.count == secondCountAfterClear)
    }

    @Test("durable expiry remove publishes only after the barrier commits")
    func durableExpiryRemove() async throws {
        let workspace = try TempPersistence()
        defer { workspace.cleanup() }
        let clock = ABWTestClock(t0)
        let host = LiveSchedulerHost(
            clock: { clock.current },
            persistence: workspace.persistence
        )
        let collector = ABWEventCollector()
        await host.setActiveBackgroundWorkSink { await collector.record($0) }
        await host.setFireSink { _ in }

        let task = try await host.createTask(
            intervalSecs: 60,
            prompt: "durable expire",
            durable: true,
            foreground: true,
            fireImmediately: false
        )
        await collector.clearEvents()

        let fires = await host.fireDue(now: t0.addingTimeInterval(7 * 86_400))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(kind: .scheduled, id: task.id))
        #expect(fires.isEmpty)
        #expect(await host.list().isEmpty)
        #expect(await collector.events == [remove])
        #expect(await collector.scheduledCount == 0)
    }
}
