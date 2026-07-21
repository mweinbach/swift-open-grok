// OpenGrokPTYTests.swift
import Foundation
import Testing
@testable import OpenGrokPTY

@Suite("OpenGrokPTY")
struct OpenGrokPTYTests {
    @Test("ProcessSpec and exit/signal value types")
    func valueTypes() {
        let spec = ProcessSpec(command: "/bin/sh", arguments: ["-c", "echo hi"], usePTY: true,
                               initialSize: TerminalSize(width: 80, height: 24))
        #expect(spec.command == "/bin/sh")
        #expect(spec.usePTY)
        #expect(spec.initialSize?.height == 24)
        #expect(ProcessExit.code(0) == .code(0))
        #expect(ProcessSignal.terminate.portableValue == 15)
        #expect(ProcessSignal.interrupt.portableValue == 2)
    }

    @Test("BootstrapPTYAdapter.spawn reports unsupported")
    func spawnUnsupported() async {
        let adapter = BootstrapPTYAdapter()
        do {
            _ = try await adapter.spawn(ProcessSpec(command: "echo"))
            Issue.record("Expected unsupported")
        } catch PTYError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
