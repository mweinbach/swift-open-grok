// DiagnosticsClipboard.swift
//
// Clipboard delivery/trust classification consumed by the doctor engine.
//
// Ports, at reference 650c1db7:
//   * `ClipboardDelivery`, `ClipboardEnvironment`, `Osc52Capability`,
//     `NativeClipboardPreflight`, `native_clipboard_preflight`,
//     `osc52_delivery`, `expected_delivery`
//     (`xai-grok-pager-render/src/clipboard/trust.rs:14-160`).
//   * `ClipboardRoute` (`xai-grok-pager-render/src/clipboard/mod.rs:101-112`).
//
// Only the preflight classification is ported: the write-time feedback
// (`resolve_copy_decision`, trust.rs:179-218) belongs to the live copy path,
// not to diagnostics.

import Foundation

/// `ClipboardDelivery` (trust.rs:14-39).
public enum ClipboardDelivery: String, Sendable, Equatable, Hashable {
    case confirmed
    case unverified
    case failed

    public var isConfirmed: Bool { self == .confirmed }
    public var isFailed: Bool { self == .failed }
}

/// `Osc52Capability` (trust.rs:58-73).
public enum Osc52Capability: String, Sendable, Equatable, Hashable {
    case supported
    case unsupported
    case unknown

    /// `label()` (trust.rs:66-72).
    public var label: String { rawValue }
}

/// `ClipboardEnvironment` (trust.rs:44-53).
public struct ClipboardEnvironment: Sendable, Equatable {
    public var brand: TerminalName
    public var hostOs: HostOs
    public var displayServer: DisplayServer
    public var remote: Bool
    public var container: Bool
    public var osc52Sink: Bool
    public var waylandDataControl: Bool
    public var wlCopyAvailable: Bool

    public init(
        brand: TerminalName,
        hostOs: HostOs,
        displayServer: DisplayServer,
        remote: Bool,
        container: Bool,
        osc52Sink: Bool,
        waylandDataControl: Bool,
        wlCopyAvailable: Bool
    ) {
        self.brand = brand
        self.hostOs = hostOs
        self.displayServer = displayServer
        self.remote = remote
        self.container = container
        self.osc52Sink = osc52Sink
        self.waylandDataControl = waylandDataControl
        self.wlCopyAvailable = wlCopyAvailable
    }

    /// `osc52_capability` (trust.rs:77-85).
    public var osc52Capability: Osc52Capability {
        if osc52Sink || brand.supportsOSC52Clipboard { return .supported }
        if brand == .unknown { return .unknown }
        return .unsupported
    }
}

/// `NativeClipboardPreflight` (trust.rs:90-95).
public enum NativeClipboardPreflight: String, Sendable, Equatable, Hashable {
    case disabled
    case localAvailable
    case remoteOnly
    case unavailable
}

/// `native_clipboard_preflight` (trust.rs:102-128).
public func nativeClipboardPreflight(
    routeNative: Bool,
    environment: ClipboardEnvironment
) -> NativeClipboardPreflight {
    if !routeNative { return .disabled }
    if environment.remote || environment.container { return .remoteOnly }
    switch environment.hostOs {
    case .linux:
        switch environment.displayServer {
        case .wayland where environment.wlCopyAvailable || environment.waylandDataControl:
            return .localAvailable
        case .wayland, .unknown:
            return .unavailable
        case .x11:
            return .localAvailable
        case .quartz, .win32:
            return .unavailable
        }
    case .macos, .windows:
        return .localAvailable
    case .other:
        return .unavailable
    }
}

/// `osc52_delivery` (trust.rs:132-140). Missing capability evidence across a
/// remote/container boundary is Unverified rather than Failed.
func osc52Delivery(environment: ClipboardEnvironment) -> ClipboardDelivery {
    switch environment.osc52Capability {
    case .supported:
        return .confirmed
    case .unknown where environment.remote || environment.container:
        return .unverified
    case .unknown, .unsupported:
        return .failed
    }
}

/// `expected_delivery` (trust.rs:143-160).
public func expectedDelivery(
    native: NativeClipboardPreflight,
    routeTmux: Bool,
    routeOsc52: Bool,
    environment: ClipboardEnvironment
) -> ClipboardDelivery {
    if native == .localAvailable { return .confirmed }
    let osc52: ClipboardDelivery? = routeOsc52 ? osc52Delivery(environment: environment) : nil
    if osc52 == .confirmed || routeTmux { return .confirmed }
    if osc52 == .unverified { return .unverified }
    return .failed
}

/// `ClipboardRoute` (clipboard/mod.rs:101-112).
public struct ClipboardRoute: Sendable, Equatable {
    public var native: Bool
    public var tmuxBuffer: Bool
    public var osc52: Bool
    public var osc52TmuxPassthrough: Bool

    public init(native: Bool, tmuxBuffer: Bool, osc52: Bool, osc52TmuxPassthrough: Bool) {
        self.native = native
        self.tmuxBuffer = tmuxBuffer
        self.osc52 = osc52
        self.osc52TmuxPassthrough = osc52TmuxPassthrough
    }
}
