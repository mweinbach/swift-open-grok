import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private final class PromptFileViewerSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private struct PromptFileViewerFixture {
    let root: URL
    let workspace: URL
    let outside: URL
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-prompt-viewer-\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 35) },
                write: { _ in }
            ),
            sink: PromptFileViewerSink(),
            workingDirectory: workspace.path,
            sessionID: "prompt-viewer-\(UUID().uuidString)",
            openGrokHome: root,
            environment: ["HOME": root.path, "OPENGROK_HOME": root.path]
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live prompt file viewer security", .serialized)
struct LivePromptFileViewerSecurityTests {
    @Test("workspace files render correctly and CRLF is split as one newline character")
    func workspaceFileHandlesCRLF() async throws {
        let fixture = try PromptFileViewerFixture()
        defer { fixture.dispose() }
        let file = fixture.workspace.appendingPathComponent("safe.swift")
        try "first\r\nsecond\r\nthird".write(to: file, atomically: true, encoding: .utf8)

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.openLineViewer(
            path: "safe.swift",
            lineRange: nil
        )))
        let overlay = try #require(await fixture.renderer.overlays.focused)
        #expect(overlay.id == "line-viewer")
        guard case .text(let text) = overlay.content else {
            Issue.record("safe workspace reference did not produce the line viewer")
            return
        }
        #expect(text.lines.map(\.text) == ["first", "second", "third"])
        try await fixture.renderer.restoreTerminal()
    }

    @Test("absolute, traversal, missing, and symlink references refuse without exposing outside bytes")
    func unsafeReferencesAreVisibleRefusals() async throws {
        let fixture = try PromptFileViewerFixture()
        defer { fixture.dispose() }
        let secret = "NEVER-EXPOSE-THIS-EXTERNAL-SECRET"
        let outsideFile = fixture.outside.appendingPathComponent("secret.txt")
        try secret.write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("escape.txt"),
            withDestinationURL: outsideFile
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("escaped-directory"),
            withDestinationURL: fixture.outside
        )

        try await fixture.renderer.begin()
        for unsafePath in [
            outsideFile.path,
            "../outside/secret.txt",
            "missing.txt",
            "escape.txt",
            "escaped-directory/secret.txt",
            "C:/Windows/System32/config/SAM",
        ] {
            try await fixture.renderer.render(.overlay(.openLineViewer(
                path: unsafePath,
                lineRange: nil
            )))
            #expect(await fixture.renderer.testingFocusedOverlayID() == nil)
            let transcript = await fixture.renderer.transcript
            #expect(transcript.contains("Cannot open file reference: \(unsafePath)"))
            #expect(!transcript.contains(secret))
        }
        try await fixture.renderer.restoreTerminal()
    }

    @Test("unreadable workspace content produces a visible error instead of an empty successful viewer")
    func unreadableFilesNeverBecomeEmptyViewers() async throws {
        let fixture = try PromptFileViewerFixture()
        defer { fixture.dispose() }
        let invalid = fixture.workspace.appendingPathComponent("invalid-utf8.txt")
        try Data([0xFF, 0xFE, 0xFD]).write(to: invalid)

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.openLineViewer(
            path: "invalid-utf8.txt",
            lineRange: nil
        )))
        #expect(await fixture.renderer.testingFocusedOverlayID() == nil)
        let transcript = await fixture.renderer.transcript
        #expect(transcript.contains("Cannot open file reference: invalid-utf8.txt"))
        try await fixture.renderer.restoreTerminal()
    }
}
