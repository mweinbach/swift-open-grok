// LiveDoctorReachabilityTests.swift
//
// The render-layer half of `/doctor`, through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` consuming the
// `.doctor` overlay intents the controller emits, with evidence taken from
// the painted frame — the `format_doctor` system block, the applicable-fixes
// listing, and the fix-path refusal that must never write config from inside
// the session. The controller half (registry pins, the verbatim grammar,
// dispatch routing) is pinned in
// `Tests/OpenGrokPagerTests/PagerDoctorCommandTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class DoctorCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// Mirror only the byte count on a failed `#expect` — dumping the whole
    /// frame stream as decimal text is the balloon the fork/tasks suite hit.
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
        return String(decoding: plain, as: UTF8.self)
    }
}

/// A session-less live renderer over an isolated `$HOME`: `/doctor` needs no
/// executor, no store, and no session — the standalone probes read only the
/// injected environment.
private struct DoctorSession {
    let home: URL
    let renderer: LiveInteractiveControllerRenderer
    let sink: DoctorCapturingSink

    static func start(extraEnvironment: [String: String] = [:]) async throws -> DoctorSession {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-doctor-tui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = [
            "HOME": home.path,
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
        ]
        environment.merge(extraEnvironment) { _, new in new }
        let sink = DoctorCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        try await renderer.begin()
        try await renderer.render(.promptChanged(OpenGrokPagerInteractivePromptState()))
        return DoctorSession(home: home, renderer: renderer, sink: sink)
    }

    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String) async {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func paintedContains(_ needle: String) -> Bool {
        paintedCompact().contains(needle.filter { !$0.isWhitespace })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("/doctor live seam", .serialized)
struct LiveDoctorReachabilityTests {
    @Test("/doctor paints a real format_doctor report block")
    func reportPaintsRealBlock() async throws {
        let session = try await DoctorSession.start()
        defer { session.cleanup() }

        try await session.renderer.render(.overlay(.doctor(request: .report)))

        // `format_doctor` (doctor_format.rs:9-140): the Environment and
        // Clipboard sections with their fact rows.
        await session.waitForPaint(of: "Environment")
        #expect(session.paintedContains("Environment"))
        #expect(session.paintedContains("multiplexer"))
        #expect(session.paintedContains("ssh          no"))
        #expect(session.paintedContains("Clipboard"))
        #expect(session.paintedContains("status"))
        try await session.renderer.restoreTerminal()
    }

    @Test("/doctor fix paints the applicable-fixes listing (empty locally)")
    func listFixesPaintsEmptyArm() async throws {
        let session = try await DoctorSession.start()
        defer { session.cleanup() }

        try await session.renderer.render(.overlay(.doctor(request: .listFixes)))

        // `format_applicable_automatic_fixes` empty arm (fix.rs:604-606):
        // a local, non-tmux session carries no automatic remediation.
        await session.waitForPaint(of: "No automatic fixes are available here.")
        #expect(session.paintedContains("No automatic fixes are available here."))
        try await session.renderer.restoreTerminal()
    }

    @Test("/doctor fix under SSH paints the run-locally ssh-wrap row")
    func listFixesPaintsSSHRow() async throws {
        let session = try await DoctorSession.start(extraEnvironment: [
            "SSH_CONNECTION": "10.0.0.1 50000 10.0.0.2 22"
        ])
        defer { session.cleanup() }

        try await session.renderer.render(.overlay(.doctor(request: .listFixes)))

        await session.waitForPaint(of: "Automatic fixes:")
        #expect(session.paintedContains("Automatic fixes:"))
        #expect(session.paintedContains("ssh-wrap"))
        try await session.renderer.restoreTerminal()
    }

    @Test("/doctor fix <id> refuses inside the session, points at the CLI, and writes NOTHING")
    func fixRefusesAndWritesNothing() async throws {
        let session = try await DoctorSession.start()
        defer { session.cleanup() }

        try await session.renderer.render(.overlay(.doctor(request: .fix(id: "ssh-wrap"))))

        // The recorded divergence from upstream's confirm-then-apply
        // question: the port has no confirmation seam on the idle slash
        // path, so the fix is refused with the exact CLI command a user
        // types — never applied unconfirmed.
        await session.waitForPaint(of: "not supported in this port yet")
        #expect(session.paintedContains("Applying fixes inside the session is not supported"))
        #expect(session.paintedContains("open-grok doctor fix ssh-wrap --yes"))
        // Refusal means refusal: no shell config appeared in $HOME.
        let zshrc = session.home.appendingPathComponent(".zshrc")
        #expect(!FileManager.default.fileExists(atPath: zshrc.path))
        try await session.renderer.restoreTerminal()
    }

    @Test("/doctor fix with an unknown id paints upstream's resolve error + usage")
    func fixUnknownIDPaintsError() async throws {
        let session = try await DoctorSession.start()
        defer { session.cleanup() }

        try await session.renderer.render(.overlay(.doctor(request: .fix(id: "bogus"))))

        // `CommandResult::Error("{error}\n{USAGE}")` (doctor.rs:110-112).
        await session.waitForPaint(of: "is not an available Doctor fix")
        #expect(session.paintedContains("`bogus` is not an available Doctor fix"))
        #expect(session.paintedContains("Usage: /doctor [fix"))
        try await session.renderer.restoreTerminal()
    }
}
