// OpenGrokCrashHandlerTests.swift
import Foundation
import Testing
@testable import OpenGrokCrashHandler

@Suite("OpenGrokCrashHandler")
struct OpenGrokCrashHandlerTests {
    @Test("CrashReport value type")
    func reportValueType() {
        let report = CrashReport(
            summary: "trap",
            redactedBacktrace: ["frame0", "frame1"],
            openGrokHomeRelativePath: "crashes/abc.json"
        )
        #expect(report.summary == "trap")
        #expect(report.redactedBacktrace.count == 2)
        #expect(report.openGrokHomeRelativePath.hasPrefix("crashes/"))
    }

    @Test("BootstrapCrashHandler install/record report unsupported")
    func bootstrapHandler() async {
        let handler = BootstrapCrashHandler()
        let home = URL(fileURLWithPath: "/tmp/og-home")
        do {
            try await handler.install(openGrokHome: home)
            Issue.record("Expected unsupported")
        } catch CrashHandlerError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            _ = try await handler.record(
                CrashReport(summary: "x", redactedBacktrace: [], openGrokHomeRelativePath: "crashes/a.json"),
                openGrokHome: home
            )
            Issue.record("Expected unsupported")
        } catch CrashHandlerError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
