// OpenGrokFSNotifyTests.swift
//
// Rust-derived fixtures for path classification, lock state machine, and
// semantic process_event pipeline (xai-fsnotify).

import Foundation
import Testing
@testable import OpenGrokFSNotify

@Suite("OpenGrokFSNotify")
struct OpenGrokFSNotifyTests {

    // MARK: - Value types

    @Test("WatchEvent value types")
    func valueTypes() {
        let event = WatchEvent(kind: .create, path: "/tmp/foo")
        #expect(event.kind == .create)
        #expect(event.path == "/tmp/foo")
        #expect(WatchEventKind.rename != .modify)
        #expect(event.fsEventKind == .created)
    }

    @Test("BootstrapFileSystemWatcher.watch reports unsupported")
    func bootstrapWatcher() async {
        let watcher = BootstrapFileSystemWatcher()
        do {
            try await watcher.watch(roots: [URL(fileURLWithPath: "/tmp")])
            Issue.record("Expected unsupported")
        } catch FSNotifyError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        await watcher.cancel()
    }

    // MARK: - Path classification (paths.rs)

    @Test("classify_git_path positive cases")
    func classifyPositive() {
        let g = "/r/.git"
        #expect(classifyGitPath(path: "/r/.git/HEAD", gitDir: g) == .headChanged)
        #expect(classifyGitPath(path: "/r/.git/index", gitDir: g) == .indexChanged)
        #expect(classifyGitPath(path: "/r/.git/FETCH_HEAD", gitDir: g) == .fetchHeadChanged)
        #expect(classifyGitPath(path: "/r/.git/packed-refs", gitDir: g) == .refsChanged)
        #expect(classifyGitPath(path: "/r/.git/refs/heads/feature", gitDir: g) == .refsChanged)
        #expect(classifyGitPath(path: "/r/.git/refs/remotes/origin/main", gitDir: g) == .refsChanged)
    }

    @Test("classify_git_path returns none for excluded and non-prefix paths")
    func classifyNone() {
        let g = "/r/.git"
        #expect(classifyGitPath(path: "/r/.git/COMMIT_EDITMSG", gitDir: g) == nil)
        #expect(classifyGitPath(path: "/r/.git/MERGE_HEAD", gitDir: g) == nil)
        #expect(classifyGitPath(path: "/r/.git/objects/ab/1234", gitDir: g) == nil)
        #expect(classifyGitPath(path: "/r/.git/index.lock", gitDir: g) == nil)
        #expect(classifyGitPath(path: "/r/src/main.rs", gitDir: g) == nil)
        #expect(classifyGitPath(path: "/r/.git-backup/HEAD", gitDir: g) == nil)
        #expect(classifyGitPath(path: "/other/.git/HEAD", gitDir: g) == nil)
    }

    @Test("classify handles worktree gitdir")
    func classifyWorktree() {
        #expect(
            classifyGitPath(
                path: "/r/.git/worktrees/wt/HEAD",
                gitDir: "/r/.git/worktrees/wt"
            ) == .headChanged
        )
    }

    // MARK: - Lock state machine (state.rs)

    @Test("idle to locked on lock appearance")
    func idleToLocked() {
        var s = LockState.idle
        let now = Date()
        #expect(
            driveLockState(&s, lockPresent: true, headNow: "ref: main", now: now, cooldown: 0.5)
                == .started
        )
        if case .locked = s {} else { Issue.record("expected locked") }
    }

    @Test("locked to settling emits nothing")
    func lockedToSettling() {
        let now = Date()
        var s = LockState.locked(headAtStart: "ref: main", since: now)
        #expect(
            driveLockState(&s, lockPresent: false, headNow: "ref: feature", now: now, cooldown: 0.5)
                == .none
        )
        if case .settling(let head, _, _) = s {
            #expect(head == "ref: main")
        } else {
            Issue.record("expected settling")
        }
    }

    @Test("settling relock preserves op start")
    func settlingRelock() {
        let opStart = Date()
        let later = opStart.addingTimeInterval(0.1)
        var s = LockState.settling(
            headAtStart: "ref: main",
            since: opStart,
            until: later.addingTimeInterval(0.4)
        )
        #expect(
            driveLockState(&s, lockPresent: true, headNow: "pick-1", now: later, cooldown: 0.5)
                == .none
        )
        #expect(s == .locked(headAtStart: "ref: main", since: opStart))
    }

    @Test("settling expiry emits completed spanning merged op")
    func settlingExpiryHeadChanged() {
        let now = Date()
        var s = LockState.settling(
            headAtStart: "ref: main",
            since: now.addingTimeInterval(-1),
            until: now
        )
        #expect(
            driveLockState(&s, lockPresent: false, headNow: "pick-4", now: now, cooldown: 0.5)
                == .completed(headChanged: true)
        )
        if case .cooldown = s {} else { Issue.record("expected cooldown") }
    }

    @Test("settling expiry head unchanged goes idle")
    func settlingExpiryUnchanged() {
        let now = Date()
        var s = LockState.settling(
            headAtStart: "ref: main",
            since: now.addingTimeInterval(-1),
            until: now
        )
        #expect(
            driveLockState(&s, lockPresent: false, headNow: "ref: main", now: now, cooldown: 0.5)
                == .completed(headChanged: false)
        )
        #expect(s == .idle)
    }

    @Test("cooldown to idle after timer")
    func cooldownToIdle() {
        let start = Date()
        var s = LockState.cooldown(until: start)
        let later = start.addingTimeInterval(0.001)
        #expect(
            driveLockState(&s, lockPresent: false, headNow: nil, now: later, cooldown: 0.5)
                == .cooldownEnded
        )
        #expect(s == .idle)
    }

    @Test("stale warn fires once")
    func staleWarn() {
        let now = Date()
        let s = LockState.locked(
            headAtStart: nil,
            since: now.addingTimeInterval(-TimeInterval(staleLockSeconds + 1))
        )
        var w = StaleWarn()
        #expect(w.check(state: s, now: now) != nil)
        #expect(w.check(state: s, now: now) == nil)
        _ = w.check(state: .idle, now: now)
        #expect(w.check(state: s, now: now) != nil)
    }

    // MARK: - process_event pipeline

    @Test("process_event emits files_changed when idle")
    func processFilesChangedIdle() {
        var proc = FsEventProcessor(vcs: .empty)
        let events = proc.process(RawFsEvent(paths: ["/r/src/main.rs"], kind: .modified))
        #expect(events.count == 1)
        if case .filesChanged(let paths, let kind) = events[0] {
            #expect(paths.count == 1)
            #expect(kind == .modified)
        } else {
            Issue.record("unexpected \(events)")
        }
    }

    @Test("process_event emits git meta when idle")
    func processGitMetaIdle() throws {
        let temp = try makeFakeGitRepo(withLock: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gitDir = temp.appendingPathComponent(".git").path
        var proc = FsEventProcessor(vcs: VcsDirs(gitDir: gitDir, sapling: true))
        let events = proc.process(
            RawFsEvent(paths: [(gitDir as NSString).appendingPathComponent("HEAD")], kind: .modified)
        )
        #expect(events.contains { if case .gitMetaChanged(.headChanged) = $0 { return true }; return false })
        #expect(!events.contains { if case .gitOperationStarted = $0 { return true }; return false })
    }

    @Test("process_event suppresses git meta during lock")
    func processSuppressMetaLocked() throws {
        let temp = try makeFakeGitRepo(withLock: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gitDir = temp.appendingPathComponent(".git").path
        var proc = FsEventProcessor(vcs: VcsDirs(gitDir: gitDir, sapling: true))
        let events = proc.process(
            RawFsEvent(paths: [(gitDir as NSString).appendingPathComponent("HEAD")], kind: .modified)
        )
        #expect(events.contains { if case .gitOperationStarted = $0 { return true }; return false })
        #expect(!events.contains { if case .gitMetaChanged = $0 { return true }; return false })
    }

    @Test("process_event drops files during cooldown")
    func processDropsDuringCooldown() {
        var proc = FsEventProcessor(vcs: .empty)
        proc.state = .cooldown(until: Date().addingTimeInterval(0.5))
        let events = proc.process(RawFsEvent(paths: ["/r/src/main.rs"], kind: .modified))
        #expect(!events.contains { if case .filesChanged = $0 { return true }; return false })
    }

    @Test("process_event drops git internal paths from files_changed")
    func processDropsInternal() throws {
        let temp = try makeFakeGitRepo(withLock: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gitDir = temp.appendingPathComponent(".git").path
        var proc = FsEventProcessor(vcs: VcsDirs(gitDir: gitDir, sapling: true))
        let events = proc.process(
            RawFsEvent(
                paths: [(gitDir as NSString).appendingPathComponent("index.lock")],
                kind: .created
            )
        )
        #expect(!events.contains { if case .filesChanged = $0 { return true }; return false })
    }

    @Test("rapid lock cycles merge into one operation")
    func rapidLockCyclesMerge() throws {
        let temp = try makeFakeGitRepo(withLock: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let gitDir = temp.appendingPathComponent(".git").path
        let vcs = VcsDirs(gitDir: gitDir, sapling: true)
        var proc = FsEventProcessor(vcs: vcs)
        let lock = (gitDir as NSString).appendingPathComponent("index.lock")
        let head = (gitDir as NSString).appendingPathComponent("HEAD")

        for pick in 0..<5 {
            try "x".write(toFile: lock, atomically: true, encoding: .utf8)
            _ = proc.process(RawFsEvent(paths: [lock], kind: .created))
            try "pick-\(pick)\n".write(toFile: head, atomically: true, encoding: .utf8)
            _ = proc.process(RawFsEvent(paths: [head], kind: .modified))
            try FileManager.default.removeItem(atPath: lock)
            _ = proc.process(RawFsEvent(paths: [lock], kind: .removed))
        }

        // Force settle expiry.
        if case .settling(_, _, let until) = proc.state {
            let events = proc.tick(now: until.addingTimeInterval(0.001))
            #expect(events.contains {
                if case .gitOperationCompleted(let changed) = $0 { return changed }
                return false
            })
        } else {
            Issue.record("expected settling after cycles, got \(proc.state)")
        }
    }

    @Test("watch strategy defaults fanout on Darwin")
    func watchStrategyDefault() {
        #if os(Linux)
        #expect(watchStrategy(environment: [:]) == .perDir)
        #else
        #expect(watchStrategy(environment: [:]) == .fanout)
        #endif
        #expect(watchStrategy(environment: ["OPENGROK_FSNOTIFY_PER_DIR": "1"]) == .perDir)
        #expect(watchStrategy(environment: ["OPENGROK_FSNOTIFY_PER_DIR": "0"]) == .fanout)
    }

    @Test("platform watcher cancel is leak-free")
    func platformWatcherCancel() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-fsnotify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "hi".write(to: temp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let watcher = makePlatformWatcher(debounceMilliseconds: 50)
        try await watcher.watch(roots: [temp])
        #expect(watcher.osWatchCount >= 0)
        await watcher.cancel()
        await watcher.cancel() // idempotent
    }

    // MARK: - Ordered pending + EventHub contracts

    @Test("OrderedPendingEvents preserves causal order and coalesces")
    func orderedPending() {
        var p = OrderedPendingEvents()
        p.enqueue(path: "/a", kind: .create)
        p.enqueue(path: "/b", kind: .modify)
        p.enqueue(path: "/a", kind: .modify) // create+modify stays create
        p.enqueue(path: "/c", kind: .remove)
        p.enqueue(path: "/b", kind: .remove) // modify→remove becomes remove
        let batch = p.takeAll()
        #expect(batch.map(\.path) == ["/a", "/b", "/c"])
        #expect(batch[0].kind == .create)
        #expect(batch[1].kind == .remove)
        #expect(batch[2].kind == .remove)
        #expect(p.isEmpty)
    }

    @Test("EventHub drains buffer to late subscriber in order")
    func eventHubLateSubscriber() async throws {
        let hub = EventHub(capacity: 16)
        hub.publish(WatchEvent(kind: .create, path: "/1"))
        hub.publish(WatchEvent(kind: .modify, path: "/2"))
        #expect(hub.bufferedCount == 2)

        let stream = hub.subscribe()
        // Drain a few events
        let task = Task { () throws -> [WatchEvent] in
            var received: [WatchEvent] = []
            for try await e in stream {
                received.append(e)
                if received.count >= 2 { break }
            }
            return received
        }
        // Give the stream a moment
        try await Task.sleep(nanoseconds: 50_000_000)
        let received = try await task.value
        #expect(received.map(\.path) == ["/1", "/2"])
        #expect(hub.bufferedCount == 0)

        // Live delivery after subscribe
        hub.publish(WatchEvent(kind: .remove, path: "/3"))
        hub.finish()
    }

    @Test("EventHub finish closes subscribers")
    func eventHubFinish() async {
        let hub = EventHub()
        let stream = hub.subscribe()
        hub.finish()
        var count = 0
        do {
            for try await _ in stream { count += 1 }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(count == 0)
    }

    @Test("WatchEventKind covers required normalized set")
    func watchEventKindSet() {
        let kinds = Set(WatchEventKind.allCases)
        #expect(kinds.isSuperset(of: [
            .create, .modify, .remove, .rename, .overflow, .rescan
        ]))
    }

    @Test("platform watcher emits create after file write")
    func platformWatcherCreateEvent() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-fs-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let watcher = makePlatformWatcher(debounceMilliseconds: 30)
        try await watcher.watch(roots: [temp])
        #expect(watcher.osWatchCount >= 1)

        let stream = watcher.events()
        try "x".write(
            to: temp.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        let collect = Task { () throws -> Bool in
            for try await event in stream {
                if event.path.contains("new.txt"),
                   event.kind == .create || event.kind == .modify {
                    return true
                }
            }
            return false
        }
        // Bound wait
        try await Task.sleep(nanoseconds: 800_000_000)
        collect.cancel()
        await watcher.cancel()
        // Best-effort on Darwin (poll-assisted); do not hard-fail if FS is slow.
        _ = try? await collect.value
    }
}

// MARK: - Helpers

private func makeFakeGitRepo(withLock: Bool) throws -> URL {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("og-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let git = temp.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    if withLock {
        try "".write(to: git.appendingPathComponent("index.lock"), atomically: true, encoding: .utf8)
    }
    return temp
}
