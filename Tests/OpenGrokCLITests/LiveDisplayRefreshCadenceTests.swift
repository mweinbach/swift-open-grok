// LiveDisplayRefreshCadenceTests.swift
//
// Live-seam proof that a valid probed Hz reaches the existing paint-cadence
// resolver through `OpenGrokLiveApplicationLauncher.resolveStartupPaintCadence`
// (AGENTS.md §3). Does not touch CoreGraphics — the platform sampler is injected.

import Foundation
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

@Suite("Live display-refresh → paint cadence")
struct LiveDisplayRefreshCadenceTests {
    @Test("valid 120 Hz probe resolves to 8 ms through existing policy")
    func probed120MapsToEightMilliseconds() {
        let policy = PagerDisplayRefreshPolicy(autoCadenceEnabled: true)
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let cadence = OpenGrokLiveApplicationLauncher.resolveStartupPaintCadence(
            environment: [:],
            policy: policy,
            isInteractive: true,
            platform: platform
        )
        #expect(cadence == 0.008)
        #expect(platform.callCount == 1)
    }

    @Test("auto cadence off keeps the 16 ms default even with a 120 Hz sampler")
    func autoOffKeepsDefault() {
        let policy = PagerDisplayRefreshPolicy(autoCadenceEnabled: false)
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let cadence = OpenGrokLiveApplicationLauncher.resolveStartupPaintCadence(
            environment: [:],
            policy: policy,
            isInteractive: true,
            platform: platform
        )
        #expect(cadence == PagerMotion.defaultPaintCadence)
        #expect(platform.callCount == 0)
    }

    @Test("SSH skip yields probe_skip default cadence")
    func sshKeepsDefault() {
        let policy = PagerDisplayRefreshPolicy(autoCadenceEnabled: true)
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let cadence = OpenGrokLiveApplicationLauncher.resolveStartupPaintCadence(
            environment: ["SSH_TTY": "/dev/pts/0"],
            policy: policy,
            isInteractive: true,
            platform: platform
        )
        #expect(cadence == PagerMotion.defaultPaintCadence)
        #expect(platform.callCount == 0)
    }
}
