// OpenGrokSystemPowerTests.swift
import Foundation
import Testing
@testable import OpenGrokSystemPower

@Suite("OpenGrokSystemPower")
struct OpenGrokSystemPowerTests {
    @Test("BootstrapPowerAdapter.acquire reports unsupported")
    func bootstrapPower() async {
        let adapter = BootstrapPowerAdapter()
        do {
            _ = try await adapter.acquire(kind: .preventSystemSleep, reason: "agent running")
            Issue.record("Expected unsupported")
        } catch PowerError.unsupported {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(PowerLeaseKind.preventDisplaySleep != .preventSystemSleep)
    }
}
