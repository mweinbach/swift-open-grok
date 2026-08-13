import Foundation
import OpenGrokConfigTypes
import OpenGrokShared

/// Resolve the opt-in mouse-reporting toggle feature flag.
///
/// When enabled, the pager registers `Ctrl+R` (scrollback-focused only) and
/// exposes `/toggle-mouse-reporting` so the user can flip terminal mouse
/// capture for native click-drag copy/paste.
///
/// Precedence (highest first), matching Rust
/// `resolve_mouse_reporting_toggle` (`util/config/resolve/ui.rs:118-137` at
/// pin `650c1db7`):
///   1. `GROK_MOUSE_REPORTING_TOGGLE` environment
///   2. `[ui].mouse_reporting_toggle` in the effective TOML document, else
///      the parsed [`UiConfig`] field (defends a partial deserialize)
///   3. default `false`
///
/// The environment dictionary is injectable so callers and tests never mutate
/// process-global state. Callers must pass the session cwd's effective
/// document — never resolve against the process cwd by default.
public func resolveMouseReportingToggle(
    document: TOMLValue? = nil,
    ui: UiConfig = UiConfig(),
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Resolved<Bool> {
    let fromEffective = document?[path: ["ui", "mouse_reporting_toggle"]]?.boolValue
    return BoolFlag(envVar: "GROK_MOUSE_REPORTING_TOGGLE")
        .config(fromEffective ?? ui.mouseReportingToggle)
        .defaultValue(false)
        .resolve(environment: environment)
}

/// Load the effective local authority document for an explicit session or
/// route directory, then resolve the mouse-reporting toggle flag from it.
public func loadResolvedMouseReportingToggle(
    cwd: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> Resolved<Bool> {
    let document = try loadAuthorityComposition(
        cwd: cwd,
        environment: environment
    ).effective()
    return resolveMouseReportingToggle(
        document: document,
        ui: UiConfig(),
        environment: environment
    )
}
