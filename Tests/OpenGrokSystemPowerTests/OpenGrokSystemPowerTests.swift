// OpenGrokSystemPowerTests.swift
import Foundation
import Testing
@testable import OpenGrokSystemPower

@Suite("OpenGrokSystemPower")
struct OpenGrokSystemPowerTests {
    @Test("PowerEvent is equatable")
    func powerEventEq() {
        #expect(PowerEvent.willSleep == .willSleep)
        #expect(PowerEvent.willSleep != .didWake)
        #expect(PowerLeaseKind.preventDisplaySleep != .preventSystemSleep)
    }

    @Test("currentPowerState never panics")
    func currentStateSafe() {
        let state = currentPowerState()
        #expect(state == .fullWake || state == .darkWake || state == .unknown)
    }

    @Test("SystemPowerListener start-and-drop is clean")
    func startAndDropClean() {
        let listener = SystemPowerListener.start { _ in }
        // May be nil when the platform facility is unavailable.
        if let listener {
            listener.invalidate()
        }
    }

    #if os(macOS)
    @Test("classifyCapabilities pure mapping")
    func classifyCapabilities() {
        let cpu: UInt32 = 0x1
        let video: UInt32 = 0x2
        let network: UInt32 = 0x8
        let disk: UInt32 = 0x10
        #expect(MacOSPower.classifyCapabilities(cpu | video | network | disk) == .fullWake)
        #expect(MacOSPower.classifyCapabilities(cpu | network | disk) == .darkWake)
        #expect(MacOSPower.classifyCapabilities(cpu) == .darkWake)
        #expect(MacOSPower.classifyCapabilities(0) == .unknown)
        #expect(MacOSPower.classifyCapabilities(video) == .unknown)
    }

    @Test("mapPowerMessage matrix")
    func mapPowerMessageMatrix() {
        #expect(MacOSPower.mapPowerMessage(0xe000_0270) == (.willSleep, true))
        #expect(MacOSPower.mapPowerMessage(0xe000_0280) == (.willSleep, true))
        #expect(MacOSPower.mapPowerMessage(0xe000_0290) == (.didWake, false))
        #expect(MacOSPower.mapPowerMessage(0xe000_0300) == (.didWake, false))
        #expect(MacOSPower.mapPowerMessage(0xe000_0320) == (nil, false))
    }

    @Test("macOS listener registers via IOKit and stops cleanly")
    func macOSListenerRegisters() async throws {
        var events: [PowerEvent] = []
        let lock = NSLock()
        let listener = SystemPowerListener.start { event in
            lock.lock()
            events.append(event)
            lock.unlock()
        }
        // On a normal developer machine IORegisterForSystemPower succeeds.
        // Sandboxes may deny it — tolerate nil without failing the suite.
        if let listener {
            // Keep alive briefly so the run-loop thread is fully up.
            try await Task.sleep(nanoseconds: 100_000_000)
            listener.invalidate()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = events
    }
    #endif

    @Test("PlatformPowerAdapter acquire and release system sleep lease")
    func acquireSystemSleepLease() async throws {
        #if os(macOS)
        let adapter = PlatformPowerAdapter()
        let lease = try await adapter.acquire(
            kind: .preventSystemSleep,
            reason: "Open Grok test turn"
        )
        #expect(lease.kind == .preventSystemSleep)
        #expect(lease.reason.contains("Open Grok"))
        await lease.release()
        await lease.release() // idempotent
        #elseif os(Linux)
        let adapter = PlatformPowerAdapter()
        do {
            let lease = try await adapter.acquire(
                kind: .preventSystemSleep,
                reason: "Open Grok test turn"
            )
            await lease.release()
        } catch PowerError.acquireFailed, PowerError.unsupported {
            // acceptable on systems without logind
        }
        #else
        let adapter = PlatformPowerAdapter()
        do {
            _ = try await adapter.acquire(kind: .preventSystemSleep, reason: "x")
            Issue.record("expected unsupported")
        } catch PowerError.unsupported, PowerError.acquireFailed {
            // expected
        }
        #endif
    }

    @Test("PlatformPowerAdapter acquire display sleep lease")
    func acquireDisplaySleepLease() async throws {
        #if os(macOS)
        let adapter = PlatformPowerAdapter()
        let lease = try await adapter.acquire(
            kind: .preventDisplaySleep,
            reason: "Open Grok display test"
        )
        #expect(lease.kind == .preventDisplaySleep)
        await lease.release()
        #endif
    }

    @Test("lease deinit releases assertion")
    func leaseDeinitReleases() async throws {
        #if os(macOS)
        let adapter = PlatformPowerAdapter()
        var lease: (any PowerLease)? = try await adapter.acquire(
            kind: .preventSystemSleep,
            reason: "deinit test"
        )
        #expect(lease != nil)
        lease = nil
        // No crash / hang — assertion released in deinit.
        #endif
    }

    @Test("BootstrapPowerAdapter delegates to platform")
    func bootstrapDelegates() async throws {
        #if os(macOS)
        let adapter = BootstrapPowerAdapter()
        let lease = try await adapter.acquire(kind: .preventSystemSleep, reason: "bootstrap")
        await lease.release()
        #endif
    }
}
