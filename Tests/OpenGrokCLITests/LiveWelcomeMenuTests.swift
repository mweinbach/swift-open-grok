// LiveWelcomeMenuTests.swift
//
// The welcome menu through the LIVE seam (AGENTS.md §3): the real
// `LiveInteractiveControllerRenderer` painting into a captured sink over an
// isolated `$OPENGROK_HOME`, with every dispatch asserted at the surface it
// reaches — the painted session picker, the painted cached release notes,
// the `/quit` command round-trip — and every mouse event hit-testing the
// rects the REAL frame published, never guessed coordinates.
//
// Upstream reference at pin 650c1db7: the authenticated welcome row set
// (`views/welcome/mod.rs:1755-1787`), index dispatch (`dispatch_menu_action`,
// `app/app_view.rs:4584-4620`), the welcome-scoped key chords
// (`:4110-4134`), hover selection (`MouseEventKind::Moved`, `:4428-4443`),
// and the load-bearing composer routing: a plain Enter always starts the
// session (`:4104-4109`) and typing falls through to the composer
// (`:4173-4177`) — the menu never steals either. The end-to-end
// typing-then-Enter-submits proof lives in ParityCompositionTests
// (`liveInteractiveWelcomeScreen`); here the renderer half is pinned to
// `.notHandled` for both.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokShellBase
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class WelcomeCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumps the whole byte buffer as decimal text.
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                plain.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        // Decode as UTF-8, NOT one scalar per byte — a byte-per-scalar
        // decode mangles multi-byte glyphs and hides painted rows.
        return String(decoding: plain, as: UTF8.self)
    }
}

/// The live renderer over an isolated `$OPENGROK_HOME`, with the two row
/// backings independently controllable: `withSessionCatalog` gates the
/// Resume row, `seededChangelog` gates the Changelog row (the cached-md
/// probe reads this home's `CHANGELOG.md`).
private struct WelcomeMenuFixture {
    static let testVersion = "9.9.9-menu-test"

    let home: URL
    let sink: WelcomeCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        withSessionCatalog: Bool = true,
        seededChangelog: String? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-welcome-menu-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let seededChangelog {
            try seededChangelog.write(
                to: home.appendingPathComponent("CHANGELOG.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_TEST_VERSION": Self.testVersion,
        ]
        sink = WelcomeCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "welcome-menu-live",
            sessionCatalog: withSessionCatalog
                ? LiveSessionCatalog(openGrokHome: home)
                : nil,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// The painted frame with all whitespace removed — the diff encoder
    /// skips unchanged cells, so multi-word needles never match raw capture.
    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedCompact().contains(needle)
    }

    /// The welcome overlay's published row rects from the LAST painted
    /// frame — the same values the mouse router hit-tests, so a click test
    /// lands exactly where a user's click would.
    func welcomeRows() async -> [PagerOverlayBounds.Row] {
        await renderer.lastOverlayBounds
            .last { $0.id == LiveInteractiveControllerRenderer.welcomeOverlayID }?
            .rows ?? []
    }

    func rowCenter(_ rowID: String) async throws -> (x: Int, y: Int) {
        let rows = await welcomeRows()
        guard let row = rows.first(where: { $0.id == rowID }) else {
            throw CancellationError()
        }
        return (x: row.frame.x + row.frame.width / 2, y: row.frame.y)
    }
}

private func ctrlKey(_ character: Character) -> InputEvent {
    .key(KeyEvent(key: .char(character), modifiers: .control, character: character))
}

// MARK: - Tests

@Suite("Welcome menu live seam", .serialized)
struct LiveWelcomeMenuTests {
    @Test("backed rows paint in upstream order with shortcuts and version; unbacked rows never paint")
    func paintsBackedRowsInUpstreamOrder() async throws {
        let fixture = try WelcomeMenuFixture(
            seededChangelog: "## Cached\n- welcome menu gate needle\n"
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // Byte-parity labels and key hints (`views/welcome/mod.rs:1768-1786`).
        #expect(await fixture.waitForPaint(of: "Resume session"))
        #expect(await fixture.waitForPaint(of: "ctrl+s"))
        #expect(await fixture.waitForPaint(of: "Changelog"))
        #expect(await fixture.waitForPaint(of: "Quit"))
        #expect(await fixture.waitForPaint(of: "ctrl+q"))
        // The hero-inline version badge value (`render_version_badge`,
        // `mod.rs:462-489`), via the port's GROK_TEST_VERSION seam.
        #expect(await fixture.waitForPaint(of: WelcomeMenuFixture.testVersion))

        // Upstream row order with the two omitted rows absent:
        // [Import], New worktree, Resume session, [Changelog], Quit
        // (`mod.rs:1774-1786`) → Resume session, Changelog, Quit.
        #expect(await fixture.welcomeRows().map(\.id) == [
            LiveInteractiveControllerRenderer.welcomeResumeRowID,
            LiveInteractiveControllerRenderer.welcomeChangelogRowID,
            LiveInteractiveControllerRenderer.welcomeQuitRowID,
        ])

        // Rows the port cannot back never paint (Wave 18 B2 lead ruling d):
        // no worktree dialog (`Action::OpenNewWorktreeDialog`), no Claude
        // import surface (`Action::ImportClaudeSettings`).
        let painted = fixture.paintedCompact()
        #expect(!painted.contains("Newworktree"))
        #expect(!painted.contains("ImportClaudesettings"))
        #expect(!painted.contains("ctrl+w"))
        #expect(!painted.contains("ctrl+i"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a composition without the backings paints only the Quit row")
    func omitsRowsWhoseBackingsAreAbsent() async throws {
        let fixture = try WelcomeMenuFixture(
            withSessionCatalog: false,
            seededChangelog: nil
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Quit"))

        #expect(await fixture.welcomeRows().map(\.id) == [
            LiveInteractiveControllerRenderer.welcomeQuitRowID,
        ])
        let painted = fixture.paintedCompact()
        #expect(!painted.contains("Resumesession"))
        #expect(!painted.contains("Changelog"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("clicking the Resume row opens the real session picker over the welcome")
    func resumeRowClickOpensTheRealPicker() async throws {
        let fixture = try WelcomeMenuFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Resume session"))

        let target = try await fixture.rowCenter(
            LiveInteractiveControllerRenderer.welcomeResumeRowID
        )
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: target.x,
            y: target.y
        )))
        #expect(routing == .consumed)
        // The REAL picker `/resume` opens (`Action::FetchSessionList`,
        // app/app_view.rs:4608-4610) — an empty catalog paints its honest
        // placeholder row.
        #expect(await fixture.waitForPaint(of: "Resume a session"))
        #expect(await fixture.waitForPaint(of: "No saved sessions"))
        // The welcome survives its own menu dispatch — only the first turn
        // dismisses it.
        #expect(!(await fixture.welcomeRows().isEmpty))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("ctrl+s opens the same picker — the welcome-scoped chord")
    func resumeChordOpensTheRealPicker() async throws {
        let fixture = try WelcomeMenuFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Resume session"))

        // Upstream's welcome ctrl+s arm (`app/app_view.rs:4119-4121`).
        let routing = try await fixture.renderer.handleInput(ctrlKey("s"))
        #expect(routing == .consumed)
        #expect(await fixture.waitForPaint(of: "Resume a session"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("the Quit row and ctrl+q both round-trip the controller-owned /quit")
    func quitRowAndChordRoundTripSlashQuit() async throws {
        let fixture = try WelcomeMenuFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Quit"))

        // Mouse (`dispatch_menu_action` quit arm, `:4619`; a mouse-dispatched
        // quit is immediate upstream too — `apply_quit_confirmation` with no
        // key event, `:3620-3621`).
        let target = try await fixture.rowCenter(
            LiveInteractiveControllerRenderer.welcomeQuitRowID
        )
        let clicked = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: target.x,
            y: target.y
        )))
        #expect(clicked == .runCommand("/quit"))

        // Keyboard — the painted `ctrl+q` hint must be a live chord.
        let chorded = try await fixture.renderer.handleInput(ctrlKey("q"))
        #expect(chorded == .runCommand("/quit"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("clicking the Changelog row opens the CACHED release notes, no fetch")
    func changelogRowClickOpensCachedReleaseNotes() async throws {
        let fixture = try WelcomeMenuFixture(
            seededChangelog: "# What's new\n\nWelcome menu changelog needle OMEGA.\n"
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Changelog"))

        let target = try await fixture.rowCenter(
            LiveInteractiveControllerRenderer.welcomeChangelogRowID
        )
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: target.x,
            y: target.y
        )))
        #expect(routing == .consumed)
        // `Action::ShowReleaseNotes` from cached markdown only
        // (app/app_view.rs:4611-4618): the composition has NO transport, so
        // a painted body can only have come from the disk cache.
        #expect(await fixture.waitForPaint(of: "Release Notes"))
        #expect(await fixture.waitForPaint(of: "Welcome menu changelog needle OMEGA."))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("composer keys fall through the welcome; chords die with the welcome")
    func composerKeysFallThroughTheWelcome() async throws {
        let fixture = try WelcomeMenuFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Resume session"))

        // The load-bearing routing decision, renderer half: plain typing and
        // a plain Enter belong to the live composer beneath the welcome —
        // upstream promotes typing into the session (`:4173-4177`) and a
        // plain Enter ALWAYS starts the session, never a menu dispatch
        // (`:4104-4109` precedes the menu-Enter arm at `:4163-4172`).
        // The end-to-end submit proof is ParityCompositionTests
        // `liveInteractiveWelcomeScreen`; `.notHandled` here is what hands
        // the keys to that path.
        let typed = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .char("h"), character: "h"))
        )
        #expect(typed == .notHandled)
        let entered = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(entered == .notHandled)

        // The chords are welcome-scoped exactly as upstream's welcome input
        // ctx is: once the first turn dismisses the welcome, ctrl+s falls
        // through untouched (the port's mid-session Ctrl+S deliberately
        // stays unbound until a sessions surface exists there).
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "hello",
            mode: .fullScreen
        )))
        let afterDismissal = try await fixture.renderer.handleInput(ctrlKey("s"))
        #expect(afterDismissal == .notHandled)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("hover selects the row under the pointer and clears off the rows")
    func hoverMovesTheWelcomeSelection() async throws {
        let fixture = try WelcomeMenuFixture(
            seededChangelog: "cache for a three-row menu\n"
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.waitForPaint(of: "Quit"))

        // No selection until the pointer arrives — upstream's
        // `welcome_menu_index` starts `None` (app/app_view.rs:1912).
        #expect(await fixture.renderer.welcomeMenuSelectionForTesting == nil)

        // Hover the THIRD row (Quit) — `MouseEventKind::Moved` sets the
        // index of the row under the pointer (`:4428-4439`).
        let quit = try await fixture.rowCenter(
            LiveInteractiveControllerRenderer.welcomeQuitRowID
        )
        let hovered = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .move,
            x: quit.x,
            y: quit.y
        )))
        #expect(hovered == .consumed)
        #expect(await fixture.renderer.welcomeMenuSelectionForTesting == 2)

        // Off the rows the selection CLEARS (`:4440-4442` sets `None`).
        let cleared = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .move,
            x: quit.x,
            y: quit.y + 5
        )))
        #expect(cleared == .consumed)
        #expect(await fixture.renderer.welcomeMenuSelectionForTesting == nil)
        try await fixture.renderer.restoreTerminal()
    }
}
