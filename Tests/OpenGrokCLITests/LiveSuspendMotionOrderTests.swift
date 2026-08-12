// LiveSuspendMotionOrderTests.swift
//
// `/transcript` suspend order through the LIVE renderer (AGENTS.md §3):
// motion pause before terminal child, resume after restore, and
// `renderAnimationTick` / pending flush are no-ops while the local hold or
// `restored` latch is set. Restore failures keep the hold and skip
// `resumeMotion`. Prefer deterministic latches over scheduler overlap.
//
// Residual gap: controller `motionShutdownLatched` (resume during teardown
// while `running` is still true) is asserted on the pager controller seam in
// `PagerMotionTickerTests.shutdownLatchBlocksResumeDuringTeardown`, not as a
// full live controller↔renderer child race here.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private final class SuspendOrderSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes.count
    }

    var rawBytes: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func offsets(of pattern: String) -> [Int] {
        let needle = Array(pattern.utf8)
        let haystack = rawBytes
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            found.append(start)
        }
        return found
    }

    func strippedText(from offset: Int) -> String {
        let data = rawBytes
        guard offset < data.count else { return "" }
        var output = ""
        var index = offset
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

/// Fails the first alt-screen re-enter after a suspend leave — live seam for
/// `frontendResumeFromChild` restore failure without mocking the renderer.
private final class ResumeFailingSink: PagerTerminalSink, @unchecked Sendable {
    private enum Phase {
        case live
        case suspended
        case afterFailedResume
    }

    private let lock = NSLock()
    private var phase: Phase = .live
    private(set) var frontendRestoreAttempted = false

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: newBytes, as: UTF8.self)
        switch phase {
        case .live:
            if text.contains("\u{1B}[?1049l") {
                phase = .suspended
            }
        case .suspended:
            // `resumeFromChild` re-enters alt screen; reject that write.
            if text.contains("\u{1B}[?1049h") {
                throw ResumeFromChildFailure()
            }
            // Best-effort `frontendRestore` after the resume throw (resets,
            // not alt re-enter — `enteredAlternateScreen` is already false).
            frontendRestoreAttempted = true
            phase = .afterFailedResume
        case .afterFailedResume:
            break
        }
    }

    func flush() throws {}

    var didAttemptFrontendRestore: Bool {
        lock.lock(); defer { lock.unlock() }
        return frontendRestoreAttempted
    }
}

private struct ResumeFromChildFailure: Error, CustomStringConvertible {
    var description: String { "resume-from-child-failed" }
}

private actor SuspendOrderLog {
    enum Entry: Equatable, CustomStringConvertible {
        case suspendMotion
        case park
        case end
        case resumeMotion
        case tickWhileHeld
        case flushWhileHeld

        var description: String {
            switch self {
            case .suspendMotion: return "suspendMotion"
            case .park: return "park"
            case .end: return "end"
            case .resumeMotion: return "resumeMotion"
            case .tickWhileHeld: return "tickWhileHeld"
            case .flushWhileHeld: return "flushWhileHeld"
            }
        }
    }

    private(set) var entries: [Entry] = []

    func record(_ entry: Entry) {
        entries.append(entry)
    }
}

private func writePagerScript(in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("fake-pager.sh")
    let output = directory.appendingPathComponent("pager-saw.txt")
    let contents = """
    #!/bin/sh
    cp "$1" "\(output.path)"
    """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: script.path
    )
    return script
}

@Suite("Live suspend motion order", .serialized)
struct LiveSuspendMotionOrderTests {
    @Test("suspendMotion runs before park/child; resumeMotion after restore; ticks no-op while held")
    func motionPauseBeforeChildAndResumeAfterRestore() async throws {
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }
        let pager = try writePagerScript(in: scriptDirectory)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "PAGER": pager.path,
        ]
        let sink = SuspendOrderSink()
        let log = SuspendOrderLog()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            sessionID: "suspend-motion-order",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )

        try await renderer.begin()
        // Seed motion clock so a suppressed tick would be observable.
        try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
            tick: 1,
            seconds: 1.0,
            demand: .fast
        ))
        let tickBefore = await renderer.testingPaintedMotionTick()

        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record(.park)
                return LiveInputSuspension(end: {
                    await log.record(.end)
                })
            },
            environment: environment,
            suspendMotion: {
                await log.record(.suspendMotion)
                #expect(await renderer.testingLocalMotionHold())
                // Interleaved tick while held must not mutate the painted clock.
                try? await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
                    tick: 99,
                    seconds: 99.0,
                    demand: .fast
                ))
                if await renderer.testingPaintedMotionTick() == tickBefore {
                    await log.record(.tickWhileHeld)
                }
            },
            resumeMotion: {
                await log.record(.resumeMotion)
            }
        ))

        try await renderer.render(.notice("suspend-motion-seed"))
        try await renderer.render(.overlay(.transcriptPager))

        let entries = await log.entries
        #expect(entries == [
            .suspendMotion,
            .tickWhileHeld,
            .park,
            .end,
            .resumeMotion,
        ])
        #expect(await !renderer.testingLocalMotionHold())
        #expect(await renderer.testingPaintedMotionTick() == tickBefore)

        // Teardown still lands after park (motion pause is earlier).
        let altLeaves = sink.offsets(of: "\u{1B}[?1049l")
        #expect(altLeaves.count == 1)
        try await renderer.restoreTerminal()
    }

    @Test("park timeout still resumes motion and clears the local hold")
    func parkFailureResumesMotion() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-parkfail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        let sink = SuspendOrderSink()
        let log = SuspendOrderLog()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            sessionID: "suspend-park-fail",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )

        try await renderer.begin()
        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record(.park)
                return nil
            },
            environment: environment,
            suspendMotion: { await log.record(.suspendMotion) },
            resumeMotion: { await log.record(.resumeMotion) }
        ))
        try await renderer.render(.notice("park-fail-seed"))
        try await renderer.render(.overlay(.transcriptPager))

        #expect(await log.entries == [.suspendMotion, .park, .resumeMotion])
        #expect(await !renderer.testingLocalMotionHold())
        #expect(sink.offsets(of: "\u{1B}[?1049l").isEmpty)
        try await renderer.restoreTerminal()
    }

    @Test("renderAnimationTick after restored is a no-op")
    func renderTickAfterRestoredNoops() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-restored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: SuspendOrderSink(),
            workingDirectory: home.path,
            sessionID: "suspend-restored-tick",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "PATH": "/usr/bin:/bin",
            ]
        )

        try await renderer.begin()
        try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
            tick: 3,
            seconds: 0.5,
            demand: .fast
        ))
        let tickBefore = await renderer.testingPaintedMotionTick()
        try await renderer.restoreTerminal()
        #expect(await renderer.testingRestored())

        try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
            tick: 99,
            seconds: 99.0,
            demand: .fast
        ))
        #expect(await renderer.testingPaintedMotionTick() == tickBefore)
    }

    @Test("pending flush cannot paint or re-arm while local motion hold is latched")
    func pendingFlushNoopsDuringHold() async throws {
        // Long cadence so two notices fold into a deferred flush. Hold is
        // asserted through the live suspend path (set before suspendMotion);
        // flush is invoked on the live seam rather than racing the sleep.
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }
        let pager = try writePagerScript(in: scriptDirectory)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-flush-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "PAGER": pager.path,
        ]
        let sink = SuspendOrderSink()
        let log = SuspendOrderLog()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            sessionID: "suspend-flush-hold",
            openGrokHome: home,
            paintCadence: 1.0,
            environment: environment
        )

        try await renderer.begin()
        try await renderer.render(.notice("flush-hold-seed"))
        try await renderer.render(.notice("flush-hold-coalesce-a"))
        try await renderer.render(.notice("flush-hold-coalesce-b"))
        // Residual gap: we do not assert wall-clock overlap with the sleep
        // itself — only that once hold is latched, flush cannot paint/re-arm.
        let scheduledBefore = await renderer.testingHasScheduledFrame()

        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record(.park)
                return LiveInputSuspension(end: {
                    await log.record(.end)
                })
            },
            environment: environment,
            suspendMotion: {
                await log.record(.suspendMotion)
                #expect(await renderer.testingLocalMotionHold())
                #expect(await !renderer.testingHasPendingFlushTask())
                let bytesBefore = sink.byteCount
                await renderer.testingFlushPendingFrameNow()
                #expect(sink.byteCount == bytesBefore)
                #expect(await !renderer.testingHasPendingFlushTask())
                if scheduledBefore {
                    #expect(await renderer.testingHasScheduledFrame())
                }
                await log.record(.flushWhileHeld)
            },
            resumeMotion: {
                await log.record(.resumeMotion)
            }
        ))

        try await renderer.render(.overlay(.transcriptPager))

        #expect(await log.entries == [
            .suspendMotion,
            .flushWhileHeld,
            .park,
            .end,
            .resumeMotion,
        ])
        #expect(await !renderer.testingLocalMotionHold())
        try await renderer.restoreTerminal()
    }

    @Test("restore failure keeps hold, best-effort frontendRestore, skips resumeMotion")
    func restoreFailureSkipsResumeMotion() async throws {
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-restorefail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }
        let pager = try writePagerScript(in: scriptDirectory)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-suspend-restorefail-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "PAGER": pager.path,
        ]
        let sink = ResumeFailingSink()
        let log = SuspendOrderLog()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            sessionID: "suspend-restore-fail",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )

        try await renderer.begin()
        try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
            tick: 2,
            seconds: 0.25,
            demand: .fast
        ))
        let tickBefore = await renderer.testingPaintedMotionTick()

        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record(.park)
                return LiveInputSuspension(end: {
                    await log.record(.end)
                })
            },
            environment: environment,
            suspendMotion: { await log.record(.suspendMotion) },
            resumeMotion: { await log.record(.resumeMotion) }
        ))

        try await renderer.render(.notice("restore-fail-seed"))
        do {
            try await renderer.render(.overlay(.transcriptPager))
            Issue.record("expected resume-from-child failure to throw")
        } catch {
            #expect(String(describing: error).contains("resume-from-child-failed"))
        }

        #expect(await log.entries == [.suspendMotion, .park])
        #expect(await renderer.testingLocalMotionHold())
        #expect(sink.didAttemptFrontendRestore)
        // Hold kept: ticks stay dark after the failed restore path.
        try? await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
            tick: 77,
            seconds: 77.0,
            demand: .fast
        ))
        #expect(await renderer.testingPaintedMotionTick() == tickBefore)
    }
}
