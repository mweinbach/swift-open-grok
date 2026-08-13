// PagerDisplayRefreshProbeTests.swift
//
// Pure decision matrix for the display-refresh probe
// (`display_refresh.rs` decide/precheck + macOS adapter gates). Asserts
// skip tokens and adapter call counts — never the ambient CoreGraphics rate.

import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("Display-refresh probe decision")
struct PagerDisplayRefreshProbeTests {
    private let bandMin = PagerDisplayRefreshProbe.defaultMinHz
    private let bandMax = PagerDisplayRefreshProbe.defaultMaxHz

    @Test("auto cadence off skips without sampling the platform")
    func autoOffSkips() {
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let result = PagerDisplayRefreshProbe.probe(
            environment: [:],
            autoCadenceEnabled: false,
            isInteractive: true,
            host: .macos,
            platform: platform
        )
        #expect(result.hz == nil)
        #expect(result.source == .none)
        #expect(result.skipReason == "flag_off")
        #expect(result.outcome == "skipped")
        #expect(platform.callCount == 0)
    }

    @Test("probe disabled skips before platform FFI")
    func probeDisabledSkips() {
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let result = PagerDisplayRefreshProbe.probe(
            environment: [:],
            autoCadenceEnabled: true,
            probeEnabled: false,
            isInteractive: true,
            host: .macos,
            platform: platform
        )
        #expect(result.skipReason == "disabled")
        #expect(platform.callCount == 0)
    }

    @Test("SSH skips without sampling the platform")
    func sshSkips() {
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let result = PagerDisplayRefreshProbe.probe(
            environment: ["SSH_CONNECTION": "10.0.0.1 1 10.0.0.2 22"],
            autoCadenceEnabled: true,
            isInteractive: true,
            host: .macos,
            platform: platform
        )
        #expect(result.hz == nil)
        #expect(result.source == .none)
        #expect(result.skipReason == "ssh")
        #expect(platform.callCount == 0)
    }

    @Test("non-TTY / noninteractive skips without sampling")
    func nonInteractiveSkips() {
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(120))
        let result = PagerDisplayRefreshProbe.probe(
            environment: [:],
            autoCadenceEnabled: true,
            isInteractive: false,
            host: .macos,
            platform: platform
        )
        #expect(result.hz == nil)
        #expect(result.skipReason == "noninteractive")
        #expect(platform.callCount == 0)
    }

    @Test("WSL skips without sampling")
    func wslSkips() {
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(60))
        let result = PagerDisplayRefreshProbe.probe(
            environment: ["WSL_DISTRO_NAME": "Ubuntu"],
            autoCadenceEnabled: true,
            isInteractive: true,
            host: .linux,
            platform: platform
        )
        #expect(result.skipReason == "wsl")
        #expect(result.source == .none)
        #expect(platform.callCount == 0)
    }

    @Test("invalid zero rate is indeterminate, not error")
    func zeroIsIndeterminate() {
        let result = PagerDisplayRefreshProbe.decide(
            autoCadenceEnabled: true,
            isSSH: false,
            isWSL: false,
            isInteractive: true,
            host: .macos,
            displayServer: .quartz,
            platformSample: .failure(.indeterminate)
        )
        #expect(result.hz == nil)
        #expect(result.source == .macosCoreGraphics)
        #expect(result.skipReason == "indeterminate")
        #expect(result.outcome == "skipped")
    }

    @Test("nil display mode is a hard error token")
    func nilModeIsError() {
        let result = PagerDisplayRefreshProbe.decide(
            autoCadenceEnabled: true,
            isSSH: false,
            isWSL: false,
            isInteractive: true,
            host: .macos,
            displayServer: .quartz,
            platformSample: .failure(.error)
        )
        #expect(result.hz == nil)
        #expect(result.source == .macosCoreGraphics)
        #expect(result.skipReason == "error")
        #expect(result.outcome == "error")
    }

    @Test("Hz outside the cadence band is out_of_range")
    func outOfRangeRejected() {
        for hz in [bandMin - 1, bandMax + 1, 30, 480] {
            let result = PagerDisplayRefreshProbe.decide(
                autoCadenceEnabled: true,
                isSSH: false,
                isWSL: false,
                isInteractive: true,
                host: .macos,
                displayServer: .quartz,
                platformSample: .success(hz)
            )
            #expect(result.hz == nil)
            #expect(result.skipReason == "out_of_range")
            #expect(result.source == .macosCoreGraphics)
        }
    }

    @Test("valid 60 / 120 / 144 Hz are accepted on macOS")
    func validRatesAccepted() {
        for hz in [60, 120, 144] {
            let platform = CountingDisplayRefreshPlatformProbe(result: .success(hz))
            let result = PagerDisplayRefreshProbe.probe(
                environment: [:],
                autoCadenceEnabled: true,
                isInteractive: true,
                host: .macos,
                platform: platform
            )
            #expect(result.hz == hz)
            #expect(result.source == .macosCoreGraphics)
            #expect(result.skipReason.isEmpty)
            #expect(result.outcome == "ok")
            #expect(platform.callCount == 1)
        }
    }

    @Test("macOS adapter is called only when eligible")
    func adapterCallCountOnlyWhenEligible() {
        let eligible = CountingDisplayRefreshPlatformProbe(result: .success(120))
        _ = PagerDisplayRefreshProbe.probe(
            environment: [:],
            autoCadenceEnabled: true,
            isInteractive: true,
            host: .macos,
            platform: eligible
        )
        #expect(eligible.callCount == 1)

        let blocked = CountingDisplayRefreshPlatformProbe(result: .success(120))
        _ = PagerDisplayRefreshProbe.probe(
            environment: ["SSH_CLIENT": "1 2 3"],
            autoCadenceEnabled: true,
            isInteractive: true,
            host: .macos,
            platform: blocked
        )
        #expect(blocked.callCount == 0)
        #expect(
            PagerDisplayRefreshProbe.shouldSamplePlatform(
                probeEnabled: true,
                autoCadenceEnabled: true,
                isSSH: false,
                isWSL: false,
                isInteractive: true,
                host: .macos
            )
        )
        #expect(
            !PagerDisplayRefreshProbe.shouldSamplePlatform(
                probeEnabled: true,
                autoCadenceEnabled: false,
                isSSH: false,
                isWSL: false,
                isInteractive: true,
                host: .macos
            )
        )
    }

    @Test("Linux Wayland / X11 / no display return honest unsupported skips")
    func linuxUnsupported() {
        let wayland = PagerDisplayRefreshProbe.decide(
            autoCadenceEnabled: true,
            isSSH: false,
            isWSL: false,
            isInteractive: true,
            host: .linux,
            displayServer: .wayland,
            platformSample: nil
        )
        #expect(wayland.source == .linux)
        #expect(wayland.skipReason == "wayland_unsupported")

        let x11 = PagerDisplayRefreshProbe.decide(
            autoCadenceEnabled: true,
            isSSH: false,
            isWSL: false,
            isInteractive: true,
            host: .linux,
            displayServer: .x11,
            platformSample: nil
        )
        #expect(x11.skipReason == "x11_unsupported")

        let none = PagerDisplayRefreshProbe.decide(
            autoCadenceEnabled: true,
            isSSH: false,
            isWSL: false,
            isInteractive: true,
            host: .linux,
            displayServer: .unknown,
            platformSample: nil
        )
        #expect(none.skipReason == "no_display")
    }

    @Test("Windows stays unsupported without a Swift adapter")
    func windowsUnsupported() {
        let platform = CountingDisplayRefreshPlatformProbe(result: .success(144))
        let result = PagerDisplayRefreshProbe.probe(
            environment: [:],
            autoCadenceEnabled: true,
            isInteractive: true,
            host: .windows,
            platform: platform
        )
        #expect(result.hz == nil)
        #expect(result.source == .windowsEnumDisplaySettings)
        #expect(result.skipReason == "unsupported")
        #expect(platform.callCount == 0)
    }

    @Test("band boundaries of the cadence policy are accepted")
    func cadenceBandBoundariesAccepted() {
        for hz in [bandMin, bandMax] {
            let result = PagerDisplayRefreshProbe.decide(
                autoCadenceEnabled: true,
                isSSH: false,
                isWSL: false,
                isInteractive: true,
                host: .macos,
                displayServer: .quartz,
                platformSample: .success(hz)
            )
            #expect(result.hz == hz)
            #expect(result.skipReason.isEmpty)
        }
    }
}
