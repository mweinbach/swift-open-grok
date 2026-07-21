// OpenGrokFSNotifyTests.swift
import Foundation
import Testing
@testable import OpenGrokFSNotify

@Suite("OpenGrokFSNotify")
struct OpenGrokFSNotifyTests {
    @Test("WatchEvent value types")
    func valueTypes() {
        let event = WatchEvent(kind: .create, path: "/tmp/foo")
        #expect(event.kind == .create)
        #expect(event.path == "/tmp/foo")
        #expect(WatchEventKind.rename != .modify)
    }

    @Test("BootstrapFileSystemWatcher.watch reports unsupported and events() finishes")
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
        let events = watcher.events()
        var finished = false
        do {
            for try await _ in events { }
            finished = true
        } catch {
            Issue.record("events() threw: \(error)")
        }
        #expect(finished)
        await watcher.cancel()
    }
}
