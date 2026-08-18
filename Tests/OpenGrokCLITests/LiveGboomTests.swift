import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class GboomCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var output: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {
        lock.lock()
        output.append(contentsOf: bytes)
        lock.unlock()
    }

    func flush() throws {}

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self)
    }
}

@Suite("Live GBOOM", .serialized)
struct LiveGboomTests {
    @Test("title starts, movement changes position, and shooting kills")
    func gameStateIsInteractive() {
        var game = LiveGboomState()
        #expect(game.phase == .title)

        #expect(game.handleKey(KeyEvent(key: .char("x"))) == .changed)
        #expect(game.phase == .playing)

        let startX = game.playerX
        _ = game.handleKey(KeyEvent(key: .char("w")))
        #expect(game.playerX > startX)

        _ = game.handleKey(KeyEvent(key: .char(" ")))
        _ = game.handleKey(KeyEvent(key: .char(" ")))
        #expect(game.kills == 1)
    }

    @Test("game frames are valid PNG payloads")
    func frameIsPNG() throws {
        var game = LiveGboomState()
        let generated = game.framePNG(width: 160, height: 100)
        let png = try #require(generated)
        #expect(png.starts(with: KittyGraphics.pngSignature))
    }

    @Test("live modal transmits, places, and clears Kitty frames")
    func liveKittyLifecycle() async throws {
        setTestGraphicsProtocolOverride(.kitty)
        defer { setTestGraphicsProtocolOverride(nil) }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-gboom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sink = GboomCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            sessionID: "gboom-live",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "TERM_PROGRAM": "kitty",
                "TERM": "xterm-kitty",
            ]
        )

        try await renderer.begin()
        try await renderer.presentGboom()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await renderer.gboom != nil)
        #expect(sink.text.contains("a=t,f=100,t=d,q=2,i=1"))
        #expect(sink.text.contains("a=p,i=1,p=1"))

        _ = try await renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(await renderer.gboom == nil)
        #expect(sink.text.contains("a=d,d=i,i=1,q=2"))
        try await renderer.restoreTerminal()
    }
}
