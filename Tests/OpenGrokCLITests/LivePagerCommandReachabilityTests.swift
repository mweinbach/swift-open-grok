// LivePagerCommandReachabilityTests.swift
//
// The render-layer half of the new slash commands, through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` painting into a
// captured sink, with effects asserted where they actually land — the painted
// frame, the session store on disk, and the owner-protected auth store. The
// controller half (dispatch → overlay request) is pinned in
// `Tests/OpenGrokPagerTests/PagerNewSlashCommandTests.swift`.

import Foundation
import OpenGrokAuth
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

// MARK: - Fixture

/// A sink that keeps everything ever written, plus a stripper so assertions
/// read the words on screen rather than the ANSI cell encoding around them.
private final class CapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// Everything written so far with CSI and OSC sequences removed. The cell
    /// encoder emits a cursor move before every cell, so words survive only
    /// after stripping.
    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var output = ""
        var index = 0
        let data = bytes
        while index < data.count {
            guard data[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(data[index]))
                index += 1
                continue
            }
            index += 1
            guard index < data.count else { break }
            switch data[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < data.count, !(0x40...0x7E).contains(data[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                // OSC: terminated by BEL or ST (ESC \).
                index += 1
                while index < data.count {
                    if data[index] == 0x07 { index += 1; break }
                    if data[index] == 0x1B, index + 1 < data.count,
                       data[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return output
    }
}

private struct RendererFixture {
    let home: URL
    let sink: CapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        modelName: String = "unknown",
        catalogStore: LiveModelCatalogStore? = nil,
        conversationHistory: LiveConversationHistory? = nil,
        sessionCatalogHome: URL? = nil,
        sessionID: String = "live-session",
        mcpServers: [MCPServerConnection] = [],
        compaction: LiveCompactionCoordinator? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-pager-reach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = CapturingSink()
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
            modelName: modelName,
            catalogStore: catalogStore,
            compaction: compaction,
            sessionID: sessionID,
            conversationHistory: conversationHistory,
            // Constructed inline: `LiveSessionCatalog` carries a FileManager
            // and must transfer into the actor as a fresh region.
            sessionCatalog: sessionCatalogHome.map { LiveSessionCatalog(openGrokHome: $0) },
            mcpServers: mcpServers,
            openGrokHome: home,
            // The shortest legal cadence, so a folded frame's flush timer
            // fires within a couple of milliseconds and the poll below stays
            // fast.
            paintCadence: PagerMotion.minimumPaintCadence
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Poll the sink until the painted screen contains `needle`. A repaint
    /// folded into the paint cadence lands via the flush timer, so the frame
    /// is not guaranteed on screen when `render(_:)` returns.
    func waitForFrame(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.contains(needle)
    }
}

private func makeSessionRecord(
    home: URL,
    sessionID: String,
    prompt: String,
    reply: String
) -> LiveConversationRecord {
    var record = LiveConversationRecord.new(
        sessionID: sessionID,
        workingDirectory: home
    )
    record.items = [
        .user(prompt),
        .assistant(AssistantItem(content: reply)),
    ]
    return record
}

// MARK: - Overlays

@Suite("Live pager command surfaces", .serialized)
struct LivePagerCommandReachabilityTests {
    @Test("/usage paints the usage report as a text modal")
    func usageOverlayPaints() async throws {
        let fixture = try RendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.usage))
        // No compaction coordinator in this composition, so the report is the
        // turn/token estimate section — and must say so on screen. Needles
        // are single tokens: the cell differ skips unchanged cells, so a
        // space that survives from the previous frame is not re-emitted and
        // a multi-word needle can be split in the captured stream.
        #expect(await fixture.waitForFrame(containing: "Turns:"))
        #expect(await fixture.waitForFrame(containing: "estimated"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/mcps paints the recorded per-server connection status")
    func mcpsOverlayPaints() async throws {
        let fixture = try RendererFixture(mcpServers: [
            MCPServerConnection(name: "docs", toolNames: ["docs__search"]),
            MCPServerConnection(name: "broken", failure: "spawn failed"),
        ])
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.mcpServers))
        #expect(await fixture.waitForFrame(containing: "docs__search"))
        #expect(await fixture.waitForFrame(containing: "spawn"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/resume paints the stored-session picker from the live catalog")
    func sessionPickerPaints() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(makeSessionRecord(
            home: home,
            sessionID: "stored-one",
            prompt: "map the render seams",
            reply: "Done."
        ))

        let fixture = try RendererFixture(sessionCatalogHome: home)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.sessionPicker))
        // The row label is the stored session's derived title (single-token
        // needle; see the cell-differ note above).
        #expect(await fixture.waitForFrame(containing: "seams"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a resumed session's transcript is repainted from the restored history")
    func resumedTranscriptPaints() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-resumed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LiveConversationStore(openGrokHome: home)
        let record = makeSessionRecord(
            home: home,
            sessionID: "restored",
            prompt: "trace the flash window",
            reply: "The flash lasts 400ms."
        )
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let fixture = try RendererFixture(conversationHistory: history)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "restored"))
        #expect(await fixture.waitForFrame(containing: "window"))
        #expect(await fixture.waitForFrame(containing: "400ms."))
        #expect(await fixture.waitForFrame(containing: "Resumed"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/rename writes the title the session store and picker read back")
    func renameWritesStoredTitle() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LiveConversationStore(openGrokHome: home)
        let record = makeSessionRecord(
            home: home,
            sessionID: "renamed",
            prompt: "first prompt",
            reply: "ok"
        )
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let fixture = try RendererFixture(conversationHistory: history)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.renameSession(title: "Renamed by test")))

        // The write landed on disk, in the record the catalog reads…
        let reloaded = try await store.load(sessionID: "renamed")
        #expect(reloaded.title == "Renamed by test")
        // …and the derived-title fallback lost to it.
        let listing = try LiveSessionCatalog(openGrokHome: home).load(sessionID: "renamed")
        #expect(listing?.title == "Renamed by test")
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/effort with no argument reports the current model's own levels")
    func effortUsageListsModelLevels() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-effort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let catalogStore = LiveModelCatalogStore(
            input: .default,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path],
            openGrokHome: home
        )
        catalogStore.noteModelSwitch(catalogID: "grok-4.5", effort: .high)

        let fixture = try RendererFixture(
            modelName: "grok-4.5",
            catalogStore: catalogStore
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.reasoningEffort(query: nil)))
        // Upstream's usage error lists the model's own option ids and the
        // session's current effort (effort.rs:63-81); the two single-token
        // needles carry the menu and the current marker.
        #expect(await fixture.waitForFrame(containing: "<high|medium|low>"))
        #expect(await fixture.waitForFrame(containing: "high)"))

        // An unknown level classifies with the model's own menu, never a
        // hardcoded global one (model_state.rs:41-60).
        try await fixture.renderer.render(.overlay(.reasoningEffort(query: "turbo")))
        #expect(await fixture.waitForFrame(containing: "'turbo';"))
        try await fixture.renderer.restoreTerminal()
    }
}

// MARK: - Settings-modal secret saves

@Suite("Settings modal secret persistence", .serialized)
struct LiveSettingsSecretSaveTests {
    @Test("a saved secret lands in the scope the live credential resolver reads")
    func secretSaveRoundTrips() async throws {
        let fixture = try RendererFixture()
        defer { fixture.dispose() }

        await fixture.renderer.applySettingsEvent(
            .secret(key: "meta_api_key", value: "  sk-meta-123  ")
        )
        // The SAME store `readProviderAPIKey` reads (Storage.swift:183), under
        // the provider-scoped key, trimmed.
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "meta") == "sk-meta-123")

        // An empty value clears the scope rather than storing an empty key
        // (upstream `SecretStatus::Missing` → ClearMetaApiKey, ui.rs:1447-1448).
        await fixture.renderer.applySettingsEvent(.secret(key: "meta_api_key", value: ""))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "meta") == nil)
    }

    @Test("resetting a secret row removes the stored credential")
    func secretResetClears() async throws {
        let fixture = try RendererFixture()
        defer { fixture.dispose() }

        await fixture.renderer.applySettingsEvent(
            .secret(key: "deepseek_api_key", value: "sk-deep-1")
        )
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "deepseek") == "sk-deep-1")

        await fixture.renderer.applySettingsEvent(.resetRequested(key: "deepseek_api_key"))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "deepseek") == nil)
    }

    @Test("the Kimi Platform row writes the historical kimi scope")
    func kimiPlatformScopeMapping() async throws {
        let fixture = try RendererFixture()
        defer { fixture.dispose() }

        await fixture.renderer.applySettingsEvent(
            .secret(key: "kimi_api_key", value: "sk-kimi-1")
        )
        // `kimi_api_key_scope` (ProviderScopes.swift:46-51): Platform reuses
        // `kimi::api_key` so pre-split logins keep working.
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "kimi") == "sk-kimi-1")
        #expect(readScopedAPIKey(grokHome: fixture.home, scope: kimiCodeAPIKeyScope) == nil)
    }
}
