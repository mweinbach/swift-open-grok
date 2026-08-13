// PagerStickyHeadersConfigTests.swift
//
// `[scrollback.display].sticky_headers` reader: default true, bool parse,
// malformed values, isolated `$OPENGROK_HOME/pager.toml`. No env, no
// settings row — those absences are asserted in the registry / live suites.

import Foundation
import Testing
@testable import OpenGrokPagerRender

@Suite("PagerStickyHeadersConfig reader")
struct PagerStickyHeadersConfigTests {
    @Test("empty document keeps upstream default true")
    func emptyDefaults() throws {
        let loaded = try PagerStickyHeadersConfigLoader.parse(toml: "")
        #expect(loaded.config == .default)
        #expect(loaded.config.enabled == true)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("absent key under [scrollback.display] stays true")
    func absentKey() throws {
        let loaded = try PagerStickyHeadersConfigLoader.parse(toml: """
        [scrollback.display]
        tab_width = 4
        """)
        #expect(loaded.config.enabled == true)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("explicit false and true are accepted")
    func legalValues() throws {
        let off = try PagerStickyHeadersConfigLoader.parse(toml: """
        [scrollback.display]
        sticky_headers = false
        """)
        #expect(off.config.enabled == false)
        #expect(off.diagnostics.isEmpty)

        let on = try PagerStickyHeadersConfigLoader.parse(toml: """
        [scrollback.display]
        sticky_headers = true
        """)
        #expect(on.config.enabled == true)
        #expect(on.diagnostics.isEmpty)
    }

    @Test("wrong-typed key falls back to true with a diagnostic")
    func malformedValue() throws {
        let loaded = try PagerStickyHeadersConfigLoader.parse(toml: """
        [scrollback.display]
        sticky_headers = "nope"
        """)
        #expect(loaded.config.enabled == true)
        #expect(loaded.diagnostics.contains { $0.contains("sticky_headers") })
    }

    @Test("[ui] sticky_headers in the same file is ignored")
    func uiTableIsNotAuthority() throws {
        let loaded = try PagerStickyHeadersConfigLoader.parse(toml: """
        [ui]
        sticky_headers = false
        """)
        #expect(loaded.config.enabled == true)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("startup path reads an isolated pager.toml under openGrokHome")
    func isolatedPagerToml() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-sticky-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        [scrollback.display]
        sticky_headers = false
        """.write(
            to: root.appendingPathComponent("pager.toml"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = PagerStickyHeadersConfigLoader.load(openGrokHome: root)
        #expect(loaded.config.enabled == false)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test("syntax-broken pager.toml yields default true and a diagnostic")
    func brokenToml() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-sticky-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        [scrollback.display
        sticky_headers = false
        """.write(
            to: root.appendingPathComponent("pager.toml"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = PagerStickyHeadersConfigLoader.load(openGrokHome: root)
        #expect(loaded.config.enabled == true)
        #expect(!loaded.diagnostics.isEmpty)
    }

    @Test("absent pager.toml is silent default true")
    func absentFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pager-sticky-missing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = PagerStickyHeadersConfigLoader.load(openGrokHome: root)
        #expect(loaded.config.enabled == true)
        #expect(loaded.diagnostics.isEmpty)
    }
}
