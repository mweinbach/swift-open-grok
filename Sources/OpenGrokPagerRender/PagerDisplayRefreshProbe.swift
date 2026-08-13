// PagerDisplayRefreshProbe.swift
//
// One-shot primary-display refresh probe for auto paint cadence.
//
// Ports `xai-grok-pager-render/src/host/display_refresh.rs` at reference
// 650c1db7, with the startup gate from `display_refresh_startup.rs` (probe
// only when auto-cadence can change a clock). Fail-closed: never throws into
// callers; no TTY I/O; no display-mode mutation; no AppKit/SwiftUI.
//
// macOS reads CoreGraphics behind an injectable platform closure so tests stay
// deterministic. Linux returns honest unsupported skip tokens; Windows stays
// unsupported in this Swift port until a Win32 adapter exists.

import Dispatch
import Foundation
import OpenGrokShared
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS)
import CoreGraphics
#endif

// MARK: - Result types

/// `DisplayRefreshSource` (`display_refresh.rs:15-20`).
public enum PagerDisplayRefreshSource: String, Sendable, Equatable, Hashable {
    case none
    case macosCoreGraphics = "macos_core_graphics"
    case windowsEnumDisplaySettings = "windows_enum_display_settings"
    case linux
}

/// Platform / host classification used by the pure decision matrix.
public enum PagerDisplayRefreshHost: String, Sendable, Equatable, Hashable {
    case macos
    case linux
    case windows
    case other

    public static func current() -> PagerDisplayRefreshHost {
        #if os(macOS)
        return .macos
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .other
        #endif
    }
}

/// Display-server classification for Linux skip reasons
/// (`DisplayServer`, host/mod.rs:56-96).
public enum PagerDisplayRefreshDisplayServer: String, Sendable, Equatable, Hashable {
    case quartz
    case wayland
    case x11
    case win32
    case unknown

    public static func detect(
        environment: [String: String],
        host: PagerDisplayRefreshHost = .current()
    ) -> PagerDisplayRefreshDisplayServer {
        switch host {
        case .macos: return .quartz
        case .windows: return .win32
        case .linux:
            if let wayland = environment["WAYLAND_DISPLAY"], !wayland.isEmpty {
                return .wayland
            }
            if let display = environment["DISPLAY"], !display.isEmpty {
                return .x11
            }
            return .unknown
        case .other:
            return .unknown
        }
    }
}

/// Failure tokens from a platform adapter before Hz acceptance.
/// `Error` is required so these values can be `Result` failures.
public enum PagerDisplayRefreshPlatformFailure: String, Error, Sendable, Equatable, Hashable {
    /// Null mode, non-finite rate, or other hard failure (`error`).
    case error
    /// Documented indeterminate 0.0 rate on some LCD/VRR panels.
    case indeterminate
    /// Platform has no adapter in this build.
    case unsupported
}

/// `DisplayRefreshProbeResult` (`display_refresh.rs:23-29`).
public struct PagerDisplayRefreshProbeResult: Sendable, Equatable, Hashable {
    public var hz: Int?
    public var source: PagerDisplayRefreshSource
    /// Empty when ok; else a stable skip/error token.
    public var skipReason: String
    public var durationMs: UInt64

    public init(
        hz: Int?,
        source: PagerDisplayRefreshSource,
        skipReason: String,
        durationMs: UInt64 = 0
    ) {
        self.hz = hz
        self.source = source
        self.skipReason = skipReason
        self.durationMs = durationMs
    }

    /// `ok` | `skipped` | `error` (`display_refresh.rs:33-41`).
    public var outcome: String {
        if hz != nil { return "ok" }
        if skipReason == "error" { return "error" }
        return "skipped"
    }
}

/// Injected macOS (or test) sampler. Returns a rounded positive Hz or a
/// typed failure — never throws.
public protocol PagerDisplayRefreshPlatformProbing: Sendable {
    func sampleMainDisplayRefreshHz() -> Result<Int, PagerDisplayRefreshPlatformFailure>
}

// MARK: - Probe

/// One-shot display-refresh probe. Call once per renderer/session startup;
/// only the numeric `hz` feeds `PagerFrameClock.cadence`.
public enum PagerDisplayRefreshProbe {
    /// Inclusive Hz band accepted by the probe — same defaults as
    /// `PagerDisplayRefreshPolicy` (55...165). Outside → `out_of_range`.
    /// Stored as `let` so public default arguments stay macOS-12-legal
    /// (no computed/`ContinuousClock`-era helpers in default expressions).
    public static let defaultMinHz: Int = 55
    public static let defaultMaxHz: Int = 165

    /// Production entry: environment + auto-cadence flag, optional policy band.
    /// Never throws. Skips FFI when auto is off, probe is disabled, SSH, WSL,
    /// or the process is non-interactive.
    public static func probe(
        environment: [String: String],
        autoCadenceEnabled: Bool,
        probeEnabled: Bool = true,
        minHz: Int = PagerDisplayRefreshProbe.defaultMinHz,
        maxHz: Int = PagerDisplayRefreshProbe.defaultMaxHz,
        isInteractive: Bool? = nil,
        host: PagerDisplayRefreshHost = PagerDisplayRefreshHost.current(),
        platform: (any PagerDisplayRefreshPlatformProbing)? = nil
    ) -> PagerDisplayRefreshProbeResult {
        // DispatchTime is the monotonic clock at this package's macOS 12 floor
        // (ContinuousClock is 13+).
        let startedNanos = DispatchTime.now().uptimeNanoseconds
        let interactive = isInteractive ?? Self.standardInputIsInteractive()
        let isSSH = isRemoteSession(environment: environment)
        let isWSL = environmentLooksLikeWSL(environment)
        let display = PagerDisplayRefreshDisplayServer.detect(
            environment: environment,
            host: host
        )

        // Avoid platform FFI when a precheck already forces a skip
        // (`display_refresh.rs:67-76` + auto/noninteractive startup gates).
        let platformSample: Result<Int, PagerDisplayRefreshPlatformFailure>?
        if shouldSamplePlatform(
            probeEnabled: probeEnabled,
            autoCadenceEnabled: autoCadenceEnabled,
            isSSH: isSSH,
            isWSL: isWSL,
            isInteractive: interactive,
            host: host
        ) {
            let sampler = platform ?? Self.defaultPlatformProbe(for: host)
            platformSample = sampler.sampleMainDisplayRefreshHz()
        } else {
            platformSample = nil
        }

        var result = decide(
            probeEnabled: probeEnabled,
            autoCadenceEnabled: autoCadenceEnabled,
            isSSH: isSSH,
            isWSL: isWSL,
            isInteractive: interactive,
            host: host,
            displayServer: display,
            platformSample: platformSample,
            minHz: min(minHz, maxHz),
            maxHz: max(minHz, maxHz)
        )
        let endedNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedNanos = endedNanos >= startedNanos ? endedNanos - startedNanos : 0
        result.durationMs = elapsedNanos / 1_000_000
        return result
    }

    /// Pure decision matrix used by production and tests
    /// (`decide`, `display_refresh.rs:82-113`) plus auto / noninteractive gates.
    public static func decide(
        probeEnabled: Bool = true,
        autoCadenceEnabled: Bool,
        isSSH: Bool,
        isWSL: Bool,
        isInteractive: Bool,
        host: PagerDisplayRefreshHost,
        displayServer: PagerDisplayRefreshDisplayServer,
        platformSample: Result<Int, PagerDisplayRefreshPlatformFailure>?,
        minHz: Int = PagerDisplayRefreshProbe.defaultMinHz,
        maxHz: Int = PagerDisplayRefreshProbe.defaultMaxHz
    ) -> PagerDisplayRefreshProbeResult {
        if !probeEnabled {
            return .init(hz: nil, source: .none, skipReason: "disabled")
        }
        if !autoCadenceEnabled {
            return .init(hz: nil, source: .none, skipReason: "flag_off")
        }
        if isSSH {
            return .init(hz: nil, source: .none, skipReason: "ssh")
        }
        if isWSL {
            return .init(hz: nil, source: .none, skipReason: "wsl")
        }
        if !isInteractive {
            return .init(hz: nil, source: .none, skipReason: "noninteractive")
        }

        switch host {
        case .macos:
            let source = PagerDisplayRefreshSource.macosCoreGraphics
            switch platformSample ?? .failure(.error) {
            case .success(let hz):
                return accept(hz: hz, source: source, minHz: minHz, maxHz: maxHz)
            case .failure(let failure):
                return .init(hz: nil, source: source, skipReason: failure.rawValue)
            }
        case .windows:
            // Win32 EnumDisplaySettings adapter is not in this Swift port yet.
            let source = PagerDisplayRefreshSource.windowsEnumDisplaySettings
            switch platformSample {
            case .some(.success(let hz)):
                return accept(hz: hz, source: source, minHz: minHz, maxHz: maxHz)
            case .some(.failure(let failure)):
                return .init(hz: nil, source: source, skipReason: failure.rawValue)
            case .none:
                return .init(hz: nil, source: source, skipReason: "unsupported")
            }
        case .linux:
            return .init(
                hz: nil,
                source: .linux,
                skipReason: linuxSkipReason(displayServer)
            )
        case .other:
            return .init(hz: nil, source: .none, skipReason: "unsupported")
        }
    }

    /// Whether the platform sampler may run. Tests assert call-count against
    /// this gate so SSH / auto-off never touch CoreGraphics.
    public static func shouldSamplePlatform(
        probeEnabled: Bool,
        autoCadenceEnabled: Bool,
        isSSH: Bool,
        isWSL: Bool,
        isInteractive: Bool,
        host: PagerDisplayRefreshHost
    ) -> Bool {
        guard probeEnabled, autoCadenceEnabled, !isSSH, !isWSL, isInteractive else {
            return false
        }
        switch host {
        case .macos:
            return true
        case .windows:
            // No Swift Win32 adapter yet — do not invent a sampler call.
            return false
        case .linux, .other:
            return false
        }
    }
}

// MARK: - Acceptance / env helpers

extension PagerDisplayRefreshProbe {
    fileprivate static func accept(
        hz: Int,
        source: PagerDisplayRefreshSource,
        minHz: Int,
        maxHz: Int
    ) -> PagerDisplayRefreshProbeResult {
        if hz < minHz || hz > maxHz {
            return .init(hz: nil, source: source, skipReason: "out_of_range")
        }
        return .init(hz: hz, source: source, skipReason: "")
    }

    fileprivate static func linuxSkipReason(
        _ display: PagerDisplayRefreshDisplayServer
    ) -> String {
        switch display {
        case .wayland: return "wayland_unsupported"
        case .x11: return "x11_unsupported"
        case .quartz, .win32, .unknown: return "no_display"
        }
    }

    fileprivate static func environmentLooksLikeWSL(
        _ environment: [String: String]
    ) -> Bool {
        environment["WSL_DISTRO_NAME"] != nil || environment["WSL_INTEROP"] != nil
    }

    fileprivate static func standardInputIsInteractive() -> Bool {
        isatty(STDIN_FILENO) != 0
    }

    fileprivate static func defaultPlatformProbe(
        for host: PagerDisplayRefreshHost
    ) -> any PagerDisplayRefreshPlatformProbing {
        switch host {
        case .macos:
            #if os(macOS)
            return MacOSCoreGraphicsDisplayRefreshProbe()
            #else
            return UnsupportedDisplayRefreshProbe()
            #endif
        case .windows, .linux, .other:
            return UnsupportedDisplayRefreshProbe()
        }
    }
}

// MARK: - Platform adapters

#if os(macOS)
/// CoreGraphics primary-display sampler
/// (`macos_main_display_refresh_hz`, `display_refresh.rs:161-189`).
struct MacOSCoreGraphicsDisplayRefreshProbe: PagerDisplayRefreshPlatformProbing {
    func sampleMainDisplayRefreshHz() -> Result<Int, PagerDisplayRefreshPlatformFailure> {
        let display = CGMainDisplayID()
        // Swift overlay returns an ARC-managed `CGDisplayMode?` — nil is the
        // Rust null-mode path (`Err("error")`).
        guard let mode = CGDisplayCopyDisplayMode(display) else {
            return .failure(.error)
        }
        // Prefer the Swift overlay property — `CGDisplayModeGetRefreshRate`
        // is obsoleted in current SDKs while `refreshRate` remains the
        // supported macOS 12-compatible path for the same CoreGraphics value.
        let rate = Double(mode.refreshRate)
        if !rate.isFinite || rate < 0 {
            return .failure(.error)
        }
        // 0.0 is documented indeterminate for some LCD/VRR panels — skip,
        // not error. No AppKit/NSScreen fallback here.
        if rate == 0 {
            return .failure(.indeterminate)
        }
        return .success(Int(rate.rounded()))
    }
}
#endif

struct UnsupportedDisplayRefreshProbe: PagerDisplayRefreshPlatformProbing {
    func sampleMainDisplayRefreshHz() -> Result<Int, PagerDisplayRefreshPlatformFailure> {
        .failure(.unsupported)
    }
}

/// Test / injection helper that records call count.
public final class CountingDisplayRefreshPlatformProbe: PagerDisplayRefreshPlatformProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let result: Result<Int, PagerDisplayRefreshPlatformFailure>

    public init(result: Result<Int, PagerDisplayRefreshPlatformFailure>) {
        self.result = result
    }

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    public func sampleMainDisplayRefreshHz() -> Result<Int, PagerDisplayRefreshPlatformFailure> {
        lock.lock(); _callCount += 1; lock.unlock()
        return result
    }
}
