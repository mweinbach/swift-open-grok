import Foundation
import Testing
@testable import OpenGrokConfig
import OpenGrokConfigTypes

@Suite("Mouse reporting toggle configuration")
struct MouseReportingToggleConfigurationTests {
    @Test("defaults off with no env and no config")
    func defaultsOff() throws {
        let document = try parseTOML("model = \"grok\"\n")
        let resolved = resolveMouseReportingToggle(
            document: document,
            environment: [:]
        )
        #expect(resolved == Resolved(value: false, source: .default))
    }

    @Test("effective [ui].mouse_reporting_toggle enables the gate")
    func effectiveConfigEnables() throws {
        let document = try parseTOML("[ui]\nmouse_reporting_toggle = true\n")
        let resolved = resolveMouseReportingToggle(
            document: document,
            environment: [:]
        )
        #expect(resolved == Resolved(value: true, source: .config))
    }

    @Test("GROK_MOUSE_REPORTING_TOGGLE overrides config")
    func environmentWins() throws {
        let document = try parseTOML("[ui]\nmouse_reporting_toggle = false\n")
        let resolved = resolveMouseReportingToggle(
            document: document,
            environment: ["GROK_MOUSE_REPORTING_TOGGLE": "1"]
        )
        #expect(resolved == Resolved(value: true, source: .env))
    }

    @Test("GROK_MOUSE_REPORTING_TOGGLE=0 is a negative control over config true")
    func environmentDisables() throws {
        let document = try parseTOML("[ui]\nmouse_reporting_toggle = true\n")
        let resolved = resolveMouseReportingToggle(
            document: document,
            environment: ["GROK_MOUSE_REPORTING_TOGGLE": "0"]
        )
        #expect(resolved == Resolved(value: false, source: .env))
    }

    @Test("effective TOML false is config source, not default")
    func effectiveFalseIsConfig() throws {
        let document = try parseTOML("[ui]\nmouse_reporting_toggle = false\n")
        let resolved = resolveMouseReportingToggle(
            document: document,
            environment: [:]
        )
        #expect(resolved == Resolved(value: false, source: .config))
    }

    @Test("loadResolvedMouseReportingToggle reads session cwd config, not process cwd")
    func loadResolvedUsesExplicitCwd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mouse-toggle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        [ui]
        mouse_reporting_toggle = true
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let resolved = try loadResolvedMouseReportingToggle(
            cwd: root,
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": home.path
            ]
        )
        #expect(resolved == Resolved(value: true, source: .config))
    }
}
