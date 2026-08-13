// PagerAnimationConfig.swift
//
// `[animation]` from `$OPENGROK_HOME/pager.toml` — fps + wave_rows only.
//
// Ports `AnimationConfig` / `RawAnimationConfig` at pin 650c1db7
// (`xai-grok-pager-render/src/appearance/config.rs:371-397, 1087-1105,
// 1452-1458`) and the one-shot load in `appearance/watcher.rs:46-54`
// (`user_grok_home()` gate → `$OPENGROK_HOME/pager.toml` via
// `pager_toml_path()`, `util.rs:10-11`). Hot-reload is not wired here.
//
// `show_fps` exists upstream and is parsed when present but deliberately
// left inert: the FPS HUD / `GROK_FPS` overlay is not advertised in this
// port. Unknown keys under `[animation]` are ignored (serde's default).

import Foundation
import OpenGrokConfig

/// Runtime animation knobs the TUI actually consumes.
public struct PagerAnimationConfig: Sendable, Equatable, Hashable {
    /// Ticks per second. Clamped to `PagerMotion.minimumFPS...maximumFPS`.
    public var fps: Int
    /// Rows per full accent-wave cycle. Clamped to at least 1.
    public var waveRows: Int

    public init(
        fps: Int = PagerMotion.defaultFPS,
        waveRows: Int = PagerMotion.defaultWaveRows
    ) {
        self.fps = Self.clampFPS(fps)
        self.waveRows = Self.clampWaveRows(waveRows)
    }

    public static let `default` = PagerAnimationConfig()

    public static func clampFPS(_ fps: Int) -> Int {
        min(max(fps, PagerMotion.minimumFPS), PagerMotion.maximumFPS)
    }

    public static func clampWaveRows(_ waveRows: Int) -> Int {
        // Upstream: `raw.wave_rows.max(1)` after `u16` deserialize
        // (`config.rs:1456`). Values above `UInt16.max` cannot appear in a
        // successful Rust parse; keep the same ceiling so a hand-edited
        // Swift TOML cannot invent a wavelength the reference rejects.
        max(1, min(waveRows, Int(UInt16.max)))
    }
}

/// Result of reading `[animation]` — config plus honest diagnostics for
/// malformed input. Absent file / absent section is silence (defaults),
/// matching the UiConfig / display-refresh tolerant readers.
public struct PagerAnimationConfigLoadResult: Sendable, Equatable {
    public var config: PagerAnimationConfig
    /// Human-readable notes when a value was discarded. Empty on the happy
    /// path (including a missing `pager.toml`).
    public var diagnostics: [String]

    public init(config: PagerAnimationConfig, diagnostics: [String] = []) {
        self.config = config
        self.diagnostics = diagnostics
    }
}

public enum PagerAnimationConfigLoader {
    public static let fileName = "pager.toml"

    /// `$OPENGROK_HOME/pager.toml` when a user home resolves; otherwise
    /// defaults without consulting process cwd (`user_grok_home` gate,
    /// `watcher.rs:47-54`).
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PagerAnimationConfigLoadResult {
        guard let home = userGrokHome(environment: environment) else {
            return PagerAnimationConfigLoadResult(config: .default)
        }
        return load(openGrokHome: home)
    }

    /// Read `[animation]` from `<openGrokHome>/pager.toml`.
    public static func load(openGrokHome: URL) -> PagerAnimationConfigLoadResult {
        load(fromPagerTomlAt: openGrokHome.appendingPathComponent(fileName))
    }

    /// Authoritative TOML seam: `loadTomlFile` (absent → empty table;
    /// syntax error → thrown). Never resolves a relative path against cwd.
    public static func load(fromPagerTomlAt path: URL) -> PagerAnimationConfigLoadResult {
        let document: TOMLValue
        do {
            document = try loadTomlFile(at: path)
        } catch {
            return PagerAnimationConfigLoadResult(
                config: .default,
                diagnostics: [
                    "pager.toml unreadable or unparseable at \(path.path); using animation defaults (\(error))"
                ]
            )
        }
        return parse(document)
    }

    /// Parse a TOML source string through the same `parseTOML` seam
    /// `loadTomlFile` uses — package tests exercise clamps without an
    /// on-disk home.
    public static func parse(toml: String) throws -> PagerAnimationConfigLoadResult {
        parse(try parseTOML(toml))
    }

    /// Pure table parse — clamps legal integers; wrong-typed keys fall back
    /// to that field's default with a diagnostic (Swift port convention;
    /// Rust serde would discard the whole `RawAppearanceConfig`).
    public static func parse(_ document: TOMLValue) -> PagerAnimationConfigLoadResult {
        var config = PagerAnimationConfig.default
        var diagnostics: [String] = []

        guard let animation = document[path: ["animation"]] else {
            return PagerAnimationConfigLoadResult(config: config)
        }
        guard case .table = animation else {
            return PagerAnimationConfigLoadResult(
                config: .default,
                diagnostics: ["[animation] is not a table; using animation defaults"]
            )
        }

        if let raw = animation[path: ["fps"]] {
            if let n = raw.int64Value {
                config.fps = PagerAnimationConfig.clampFPS(Int(n))
            } else {
                diagnostics.append(
                    "[animation].fps has wrong type; using default \(PagerMotion.defaultFPS)"
                )
            }
        }

        if let raw = animation[path: ["wave_rows"]] {
            if let n = raw.int64Value {
                config.waveRows = PagerAnimationConfig.clampWaveRows(Int(n))
            } else {
                diagnostics.append(
                    "[animation].wave_rows has wrong type; using default \(PagerMotion.defaultWaveRows)"
                )
            }
        }

        // `show_fps` / unknown keys: retained inert / ignored. No FPS HUD.
        _ = animation[path: ["show_fps"]]

        return PagerAnimationConfigLoadResult(config: config, diagnostics: diagnostics)
    }
}
