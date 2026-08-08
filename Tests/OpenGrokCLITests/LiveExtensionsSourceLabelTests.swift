// LiveExtensionsSourceLabelTests.swift
//
// Pins `LiveExtensionsComposition.sourceLabel` — the port of
// `derive_source_label` (`extensions_modal.rs:2238-2303`) — against a
// *session* `$OPENGROK_HOME`, never the process default. The regression this
// guards: hook discovery's `contentsOfDirectory(at:)` returns canonicalized
// paths (`/var/…` → `/private/var/…`), while the session home keeps its
// literal spelling; a raw prefix compare then labeled the user's own global
// hooks "Custom: /private/var/…". Rust never hits this (`read_dir` preserves
// the given prefix), so the port must canonicalize both sides itself.

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("extensions source labels")
struct LiveExtensionsSourceLabelTests {
    /// A real on-disk `$OPENGROK_HOME` with a hooks dir, so symlink
    /// resolution has something to resolve — `resolvingSymlinksInPath`
    /// only rewrites components that exist.
    private struct HomeFixture {
        let home: URL
        var hooks: URL { home.appendingPathComponent("hooks", isDirectory: true) }

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("opengrok-source-label-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: hooks, withIntermediateDirectories: true
            )
        }

        func dispose() { try? FileManager.default.removeItem(at: home) }
    }

    private func label(
        _ sourceDir: String,
        grokHome: URL,
        isDefaultGrokHome: Bool = false,
        homeDirectory: String? = nil
    ) -> String {
        LiveExtensionsComposition.sourceLabel(
            forSourceDir: sourceDir,
            grokHome: grokHome,
            isDefaultGrokHome: isDefaultGrokHome,
            homeDirectory: homeDirectory
        )
    }

    @Test("the session home's hooks dir is Global hooks, in its literal spelling")
    func globalHooksLiteralPath() throws {
        let fixture = try HomeFixture()
        defer { fixture.dispose() }
        #expect(label(fixture.hooks.path, grokHome: fixture.home) == "Global hooks")
    }

    @Test("the hooks dir as directory enumeration actually spells it is still Global hooks")
    func globalHooksEnumeratedPath() throws {
        // THE regression: take sourceDir from the same FileManager API hook
        // discovery uses, which canonicalizes (`/var/…` → `/private/var/…` on
        // macOS). The label must not depend on which spelling came back.
        let fixture = try HomeFixture()
        defer { fixture.dispose() }
        try "{}".write(
            to: fixture.hooks.appendingPathComponent("a.json"),
            atomically: true,
            encoding: .utf8
        )
        let enumerated = try #require(FileManager.default.contentsOfDirectory(
            at: fixture.hooks,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).first).deletingLastPathComponent().path
        #expect(label(enumerated, grokHome: fixture.home) == "Global hooks")
    }

    @Test("a $OPENGROK_HOME reached through a symlink still owns its global hooks")
    func globalHooksSymlinkedHome() throws {
        let fixture = try HomeFixture()
        defer { fixture.dispose() }
        let link = fixture.home.appendingPathComponent("linked-home")
        let real = fixture.home.appendingPathComponent("real-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("hooks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // The session was configured with the symlink; discovery resolved it.
        #expect(label(
            real.appendingPathComponent("hooks").path,
            grokHome: link
        ) == "Global hooks")
    }

    @Test("project, Claude, and plugin dirs classify as upstream does")
    func nonGlobalClassifications() throws {
        let fixture = try HomeFixture()
        defer { fixture.dispose() }
        // `ends_with("/.opengrok/hooks")` / `contains("/.opengrok/hooks/")`
        // (`extensions_modal.rs:2282-2284`) — textual, workspace-independent.
        #expect(label("/ws/repo/.opengrok/hooks", grokHome: fixture.home) == "Project hooks")
        #expect(label("/ws/repo/.opengrok/hooks/extra", grokHome: fixture.home) == "Project hooks")
        #expect(label(
            "/Users/u/.claude/hooks", grokHome: fixture.home, homeDirectory: "/Users/u"
        ) == "Claude settings")
        #expect(label(
            fixture.home.appendingPathComponent("plugins/fmt/hooks").path,
            grokHome: fixture.home
        ) == "Plugin: fmt")
        #expect(label(
            "/ws/repo/.opengrok/installed-plugins/lint/hooks",
            grokHome: fixture.home
        ) == "Plugin: lint")
    }

    @Test("custom dirs abbreviate against the session home, then $HOME, then raw")
    func customAbbreviations() throws {
        let fixture = try HomeFixture()
        defer { fixture.dispose() }
        // Under the session grok home but not hooks/: `$OPENGROK_HOME` when
        // overridden, `~/.opengrok` when default (`display_grok_home_prefix`).
        #expect(label(
            fixture.home.appendingPathComponent("extra").path,
            grokHome: fixture.home,
            isDefaultGrokHome: false
        ) == "Custom: $OPENGROK_HOME/extra")
        #expect(label(
            fixture.home.appendingPathComponent("extra").path,
            grokHome: fixture.home,
            isDefaultGrokHome: true
        ) == "Custom: ~/.opengrok/extra")
        #expect(label(
            "/Users/u/custom-hooks",
            grokHome: fixture.home,
            homeDirectory: "/Users/u"
        ) == "Custom: ~/custom-hooks")
        #expect(label("/srv/hooks", grokHome: fixture.home, homeDirectory: "/Users/u")
            == "Custom: /srv/hooks")
    }
}
