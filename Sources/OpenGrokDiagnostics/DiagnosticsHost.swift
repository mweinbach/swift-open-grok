// DiagnosticsHost.swift
//
// Host platform and display-server classification for the doctor engine.
//
// Ports `xai-grok-pager-render/src/host/mod.rs` at reference 650c1db7:
//   * `HostOs` (host/mod.rs:25-49) with `current()`.
//   * `DisplayServer` (host/mod.rs:56-96) with the pure `detect_from_env`
//     helper so tests can drive the Linux matrix without ambient state.
//
// This target keeps its own copy rather than importing a pager target: the
// diagnostics library must build with no OpenGrokPager/OpenGrokCLI edge (the
// disjointness guarantee for this slice).

import Foundation

/// `HostOs` (host/mod.rs:25-49). Serialized snake_case by strum upstream.
public enum HostOs: String, Sendable, Equatable, Hashable {
    case macos
    case linux
    case windows
    case other

    /// `HostOs::current()` (host/mod.rs:38-48) — compile-time constant.
    public static func current() -> HostOs {
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

/// `DisplayServer` (host/mod.rs:56-96).
public enum DisplayServer: String, Sendable, Equatable, Hashable {
    case quartz
    case wayland
    case x11
    case win32
    case unknown

    /// `DisplayServer::detect_from_env` (host/mod.rs:80-95). Pure so the
    /// Linux Wayland/X11 precedence matrix is testable; empty values are
    /// ignored exactly as upstream (`is_some_and(|v| !v.is_empty())`).
    public static func detect(environment: [String: String], host: HostOs = HostOs.current()) -> DisplayServer {
        switch host {
        case .macos: return .quartz
        case .windows: return .win32
        case .linux:
            if let wayland = environment["WAYLAND_DISPLAY"], !wayland.isEmpty { return .wayland }
            if let display = environment["DISPLAY"], !display.isEmpty { return .x11 }
            return .unknown
        case .other: return .unknown
        }
    }

    /// `DisplayServer::current()` (host/mod.rs:71-77) without the process
    /// cache: callers of the standalone collector pass the env explicitly.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> DisplayServer {
        detect(environment: environment)
    }
}
