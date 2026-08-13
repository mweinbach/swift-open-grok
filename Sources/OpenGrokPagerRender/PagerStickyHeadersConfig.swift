// PagerStickyHeadersConfig.swift
//
// `[scrollback.display].sticky_headers` from `$OPENGROK_HOME/pager.toml`.
//
// Ports `ScrollbackDisplayConfig.sticky_headers` at pin 650c1db7
// (`xai-grok-pager-render/src/appearance/config.rs:158-160, 184, 879-880,
// 902, 1429`) and the one-shot load in `appearance/watcher.rs:46-54`
// (`user_grok_home()` gate → `$OPENGROK_HOME/pager.toml` via
// `pager_toml_path()`, `util.rs:20-23`). Hot-reload is not wired here:
// `ConfigWatcher::start` is `start_static` at this pin, so a file edit is
// restart-only.
//
// There is no env override and no settings-modal row (`settings/defs.rs`
// at 650c1db7 has none). Compact mode still suppresses sticky regardless
// of this flag (`scrollback_pane.rs:395-401`, `nav.rs:440-445`).

import Foundation
import OpenGrokConfig

/// Runtime sticky-header gate the TUI actually consumes.
public struct PagerStickyHeadersConfig: Sendable, Equatable, Hashable {
    /// Pin user prompts as sticky headers when scrolled past.
    /// Default `true` (`unwrap_or(true)` at `config.rs:1429`).
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public static let `default` = PagerStickyHeadersConfig()
}

/// Result of reading `[scrollback.display].sticky_headers` — config plus
/// honest diagnostics for malformed input. Absent file / absent key is
/// silence (default true), matching the animation / UiConfig readers.
public struct PagerStickyHeadersConfigLoadResult: Sendable, Equatable {
    public var config: PagerStickyHeadersConfig
    /// Human-readable notes when a value was discarded. Empty on the happy
    /// path (including a missing `pager.toml`).
    public var diagnostics: [String]

    public init(config: PagerStickyHeadersConfig, diagnostics: [String] = []) {
        self.config = config
        self.diagnostics = diagnostics
    }
}

public enum PagerStickyHeadersConfigLoader {
    public static let fileName = "pager.toml"

    /// `$OPENGROK_HOME/pager.toml` when a user home resolves; otherwise
    /// defaults without consulting process cwd (`user_grok_home` gate,
    /// `watcher.rs:47-54`). Project `.opengrok/` is not a pager.toml
    /// authority — only the user home file is.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PagerStickyHeadersConfigLoadResult {
        guard let home = userGrokHome(environment: environment) else {
            return PagerStickyHeadersConfigLoadResult(config: .default)
        }
        return load(openGrokHome: home)
    }

    /// Read `[scrollback.display].sticky_headers` from `<openGrokHome>/pager.toml`.
    public static func load(openGrokHome: URL) -> PagerStickyHeadersConfigLoadResult {
        load(fromPagerTomlAt: openGrokHome.appendingPathComponent(fileName))
    }

    /// Authoritative TOML seam: `loadTomlFile` (absent → empty table;
    /// syntax error → thrown). Never resolves a relative path against cwd.
    public static func load(fromPagerTomlAt path: URL) -> PagerStickyHeadersConfigLoadResult {
        let document: TOMLValue
        do {
            document = try loadTomlFile(at: path)
        } catch {
            return PagerStickyHeadersConfigLoadResult(
                config: .default,
                diagnostics: [
                    "pager.toml unreadable or unparseable at \(path.path); using sticky_headers default true (\(error))"
                ]
            )
        }
        return parse(document)
    }

    /// Parse a TOML source string through the same `parseTOML` seam
    /// `loadTomlFile` uses — package tests exercise the key without an
    /// on-disk home.
    public static func parse(toml: String) throws -> PagerStickyHeadersConfigLoadResult {
        parse(try parseTOML(toml))
    }

    /// Pure table parse — wrong-typed keys fall back to default true with
    /// a diagnostic (Swift port convention; Rust serde would discard the
    /// whole `RawAppearanceConfig`).
    public static func parse(_ document: TOMLValue) -> PagerStickyHeadersConfigLoadResult {
        var config = PagerStickyHeadersConfig.default
        var diagnostics: [String] = []

        if let raw = document[path: ["scrollback", "display", "sticky_headers"]] {
            if let flag = raw.boolValue {
                config.enabled = flag
            } else {
                diagnostics.append(
                    "[scrollback.display].sticky_headers has wrong type; using default true"
                )
            }
        }

        return PagerStickyHeadersConfigLoadResult(config: config, diagnostics: diagnostics)
    }
}
