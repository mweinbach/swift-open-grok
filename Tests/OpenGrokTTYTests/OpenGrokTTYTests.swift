// OpenGrokTTYTests.swift
import Foundation
import Testing
@testable import OpenGrokTTY

@Suite("OpenGrokTTY")
struct OpenGrokTTYTests {
    @Test("BootstrapTTYAdapter detects TTY without crashing and reports unsupported for raw mode")
    func bootstrapAdapter() async {
        let adapter = BootstrapTTYAdapter(fd: 1)
        // isatty(1) depends on the test host; just assert it returns a Bool.
        _ = adapter.isATTY()
        #expect(adapter.identifier == "fd:1")
        #expect(adapter.size() == nil)
        do {
            _ = try await adapter.enterRawMode()
            Issue.record("Expected unsupported")
        } catch TTYError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
