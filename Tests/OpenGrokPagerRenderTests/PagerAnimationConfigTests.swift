// PagerAnimationConfigTests.swift
//
// `[animation]` reader: defaults, clamps, malformed values, unknown keys,
// and an isolated `$OPENGROK_HOME/pager.toml` startup load. `show_fps` stays
// absent from the public value (HUD unwired).

import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("PagerAnimationConfig reader")
struct PagerAnimationConfigTests {
    @Test("empty document keeps upstream defaults")
    func emptyDefaults() throws {
        let loaded = try PagerAnimationConfigLoader.parse(toml: "")
        #expect(loaded.config == .default)
        #expect(loaded.config.fps == 30)
        #expect(loaded.config.waveRows == 32)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("legal fps and wave_rows are accepted")
    func legalValues() throws {
        let loaded = try PagerAnimationConfigLoader.parse(toml: """
        [animation]
        fps = 12
        wave_rows = 8
        """)
        #expect(loaded.config.fps == 12)
        #expect(loaded.config.waveRows == 8)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("fps clamps to 1...60 and wave_rows to at least 1")
    func clamps() throws {
        let low = try PagerAnimationConfigLoader.parse(toml: """
        [animation]
        fps = 0
        wave_rows = 0
        """)
        #expect(low.config.fps == 1)
        #expect(low.config.waveRows == 1)

        let high = try PagerAnimationConfigLoader.parse(toml: """
        [animation]
        fps = 1000
        wave_rows = 4
        """)
        #expect(high.config.fps == 60)
        #expect(high.config.waveRows == 4)
    }

    @Test("wrong-typed keys fall back to defaults with diagnostics")
    func malformedValues() throws {
        let loaded = try PagerAnimationConfigLoader.parse(toml: """
        [animation]
        fps = "thirty"
        wave_rows = true
        """)
        #expect(loaded.config.fps == PagerMotion.defaultFPS)
        #expect(loaded.config.waveRows == PagerMotion.defaultWaveRows)
        #expect(loaded.diagnostics.count == 2)
        #expect(loaded.diagnostics.contains { $0.contains("fps") })
        #expect(loaded.diagnostics.contains { $0.contains("wave_rows") })
    }

    @Test("unknown keys and show_fps are ignored without changing defaults")
    func unknownAndShowFPSIgnored() throws {
        let loaded = try PagerAnimationConfigLoader.parse(toml: """
        [animation]
        show_fps = true
        mystery = 99
        fps = 15
        """)
        #expect(loaded.config.fps == 15)
        #expect(loaded.config.waveRows == 32)
        #expect(loaded.diagnostics.isEmpty)
        // Public value carries only fps + waveRows — no show_fps field.
        #expect(PagerAnimationConfig.default.fps == 30)
    }

    @Test("non-table [animation] falls back with a diagnostic")
    func animationNotATable() throws {
        let loaded = try PagerAnimationConfigLoader.parse(toml: """
        animation = 1
        """)
        #expect(loaded.config == .default)
        #expect(loaded.diagnostics.contains { $0.contains("not a table") })
    }

    @Test("startup path reads an isolated pager.toml under openGrokHome")
    func isolatedPagerToml() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-animation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("pager.toml")
        try """
        [animation]
        fps = 9
        wave_rows = 6
        show_fps = true
        """.write(to: path, atomically: true, encoding: .utf8)

        // Process cwd must not participate — only the explicit home path.
        let loaded = PagerAnimationConfigLoader.load(openGrokHome: root)
        #expect(loaded.config.fps == 9)
        #expect(loaded.config.waveRows == 6)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("syntax-broken pager.toml yields defaults and a diagnostic")
    func brokenToml() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-animation-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        [animation
        fps = 12
        """.write(
            to: root.appendingPathComponent("pager.toml"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = PagerAnimationConfigLoader.load(openGrokHome: root)
        #expect(loaded.config == .default)
        #expect(!loaded.diagnostics.isEmpty)
    }

    @Test("absent pager.toml is silent defaults")
    func absentFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-animation-missing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = PagerAnimationConfigLoader.load(openGrokHome: root)
        #expect(loaded.config == .default)
        #expect(loaded.diagnostics.isEmpty)
    }
}
