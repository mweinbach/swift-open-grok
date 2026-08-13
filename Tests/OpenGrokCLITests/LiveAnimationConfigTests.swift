// LiveAnimationConfigTests.swift
//
// Live-seam proof that `$OPENGROK_HOME/pager.toml` `[animation]` reaches
// `LiveInteractiveControllerRenderer.animationFPS` (and thus the
// composition's `setMotionFPS` call) before first frame. Wave rows are
// covered by the pure render suite; this pins the construction load path.

import Foundation
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

@Suite("Live animation config startup load")
struct LiveAnimationConfigTests {
    @Test("isolated pager.toml sets renderer animationFPS before run")
    func isolatedHomeSetsFPS() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-animation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try """
        [animation]
        fps = 11
        wave_rows = 7
        """.write(
            to: home.appendingPathComponent("pager.toml"),
            atomically: true,
            encoding: .utf8
        )

        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let sink = AnimationConfigCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 80, height: 24) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            openGrokHome: home,
            environment: environment
        )

        #expect(await renderer.animationFPS == 11)
        // Same loader the renderer used — wave_rows reach PagerRenderState
        // through the private field; assert the file parse for the pair.
        let loaded = PagerAnimationConfigLoader.load(openGrokHome: home)
        #expect(loaded.config.waveRows == 7)
    }

    @Test("absent pager.toml keeps default fps on the live renderer")
    func absentKeepsDefault() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-animation-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let renderer = LiveInteractiveControllerRenderer(
            mode: .inline,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 80, height: 24) },
                write: { _ in }
            ),
            sink: AnimationConfigCapturingSink(),
            workingDirectory: home.path,
            openGrokHome: home,
            environment: environment
        )
        #expect(await renderer.animationFPS == PagerMotion.defaultFPS)
    }
}

private final class AnimationConfigCapturingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes _: [UInt8]) throws {}
    func flush() throws {}
}
