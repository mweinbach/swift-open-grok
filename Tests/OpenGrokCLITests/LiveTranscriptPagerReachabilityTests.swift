// LiveTranscriptPagerReachabilityTests.swift
//
// `/transcript`'s suspend-into-`$PAGER` through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` painting into
// a captured sink, a recording suspend host, and `$PAGER` pointed at a real
// script that copies its argument — so the ordered park → teardown → child →
// re-entry → cleanup sequence is asserted where it lands, not against
// composition types. The controller half (dispatch → `.transcriptPager`) is
// pinned in `Tests/OpenGrokPagerTests/PagerTranscriptCommandTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

// MARK: - Fixture

private final class TranscriptCapturingSink: PagerTerminalSink, @unchecked Sendable {
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

    /// Byte offsets of every occurrence of `pattern`'s UTF-8 in the stream.
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

    /// Painted words from `offset` on, with CSI/OSC stripped — the cell
    /// encoder emits a cursor move before every cell, so text survives only
    /// after stripping.
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

/// The ordered park/end trail a test's fake suspend host leaves behind, each
/// entry stamped with how many bytes the sink had seen when it happened.
private actor SuspendLog {
    enum Entry: Equatable {
        case park(atByteCount: Int)
        case end(atByteCount: Int)
    }

    private(set) var entries: [Entry] = []

    func record(_ entry: Entry) {
        entries.append(entry)
    }
}

private struct TranscriptPagerFixture {
    let home: URL
    let sink: TranscriptCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let log: SuspendLog
    let environment: [String: String]

    init(pagerScript: URL? = nil) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-transcript-pager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
        #if os(Windows)
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? ""
        #else
        // The pager script's `cp` needs a real PATH; nothing else does.
        env["PATH"] = "/usr/bin:/bin"
        #endif
        if let pagerScript {
            env["PAGER"] = pagerScript.path
        }
        environment = env
        sink = TranscriptCapturingSink()
        log = SuspendLog()
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            sessionID: "transcript-pager",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: env
        )
    }

    /// A host whose park succeeds and whose `end` records — the resource's
    /// raw/discard/resume half is pinned by the TTY-level pause tests; this
    /// seam asserts the renderer drives it at the right point in the order.
    func installRecordingHost() async {
        let sink = sink
        let log = log
        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record(.park(atByteCount: sink.byteCount))
                return LiveInputSuspension(end: {
                    await log.record(.end(atByteCount: sink.byteCount))
                })
            },
            environment: environment
        ))
    }

    /// A host whose park times out, recording the attempt.
    func installParkFailingHost() async {
        let sink = sink
        let log = log
        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record(.park(atByteCount: sink.byteCount))
                return nil
            },
            environment: environment
        ))
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func waitForFrame(
        containing needle: String,
        from offset: Int = 0,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText(from: offset).contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText(from: offset).contains(needle)
    }
}

/// The `$PAGER` stand-in: copies the transcript it was handed into `output`
/// and records the path it was handed into `argumentPath`.
private func writePagerScript(
    in directory: URL
) throws -> (script: URL, output: URL, argumentPath: URL) {
    #if os(Windows)
    let script = directory.appendingPathComponent("fake-pager.cmd")
    #else
    let script = directory.appendingPathComponent("fake-pager.sh")
    #endif
    let output = directory.appendingPathComponent("pager-saw.txt")
    let argumentPath = directory.appendingPathComponent("pager-arg.txt")
    #if os(Windows)
    let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
    let moreExecutable = (systemRoot as NSString)
        .appendingPathComponent(#"System32\more.com"#)
    let contents = """
    @echo off
    > "%~dp0pager-arg.txt" echo(%~1
    "\(moreExecutable)" < "%~1" > "%~dp0pager-saw.txt"
    """
    #else
    let contents = """
    #!/bin/sh
    cp "$1" "\(output.path)"
    printf '%s' "$1" > "\(argumentPath.path)"
    """
    #endif
    try contents.write(to: script, atomically: true, encoding: .utf8)
    #if !os(Windows)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: script.path
    )
    #endif
    return (script, output, argumentPath)
}

private func transcriptTempFiles() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path
    )) ?? []
    return Set(names.filter { $0.hasPrefix("open-grok-transcript-") })
}

// MARK: - Tests

@Suite("Live /transcript pager host", .serialized)
struct LiveTranscriptPagerReachabilityTests {
    @Test("the full suspend sequence runs in order and the child sees the transcript")
    func fullSuspendSequence() async throws {
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-fake-pager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }
        let pager = try writePagerScript(in: scriptDirectory)

        let fixture = try TranscriptPagerFixture(pagerScript: pager.script)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        await fixture.installRecordingHost()
        try await fixture.renderer.render(.notice("transcript seed alpha"))

        try await fixture.renderer.render(.overlay(.transcriptPager))

        // Park before teardown, end after re-entry.
        let entries = await fixture.log.entries
        guard entries.count == 2,
              case .park(let parkOffset) = entries[0],
              case .end(let endOffset) = entries[1]
        else {
            Issue.record("expected [park, end], got \(entries)")
            return
        }
        #expect(parkOffset < endOffset)

        // Teardown (?1049l) lands between park and end; re-entry (the second
        // ?1049h — the first is `begin()`'s) lands after teardown and no
        // later than the recorded end, because the renderer resumes before
        // the input suspension ends.
        let altLeaves = fixture.sink.offsets(of: "\u{1B}[?1049l")
        let altEnters = fixture.sink.offsets(of: "\u{1B}[?1049h")
        #expect(altLeaves.count == 1)
        #expect(altEnters.count == 2)
        if let leave = altLeaves.first, altEnters.count == 2 {
            #expect(leave >= parkOffset)
            #expect(leave < altEnters[1])
            #expect(altEnters[1] <= endOffset)
        }

        // The child ran, saw the transcript, and its temp file was deleted.
        let sawContent = try String(contentsOf: pager.output, encoding: .utf8)
        #expect(sawContent.contains("transcript seed alpha"))
        let handedPath = try String(contentsOf: pager.argumentPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(handedPath.contains("open-grok-transcript-"))
        #expect(!FileManager.default.fileExists(atPath: handedPath))

        // A repaint followed the resume: the transcript word paints again
        // after the recorded end of the suspension.
        #expect(await fixture.waitForFrame(containing: "alpha", from: endOffset))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("an empty transcript emits the exact notice and never parks")
    func emptyTranscriptNeverParks() async throws {
        let fixture = try TranscriptPagerFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        await fixture.installRecordingHost()

        let before = transcriptTempFiles()
        try await fixture.renderer.render(.overlay(.transcriptPager))

        // dispatch/transcript.rs:257-262, single-token needles because the
        // cell differ can split multi-word strings across skipped cells.
        #expect(await fixture.waitForFrame(containing: "conversation"))
        #expect(await fixture.waitForFrame(containing: "yet"))
        #expect(await fixture.log.entries.isEmpty)
        #expect(transcriptTempFiles().subtracting(before).isEmpty)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a park failure notes the timeout, deletes the temp file, and leaves the renderer painting")
    func parkFailureLeavesRendererLive() async throws {
        let fixture = try TranscriptPagerFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        await fixture.installParkFailingHost()
        try await fixture.renderer.render(.notice("seed for the park-failure run"))

        let before = transcriptTempFiles()
        try await fixture.renderer.render(.overlay(.transcriptPager))

        // Upstream's timeout text (event_loop.rs:367-370); the notice
        // painting at all is also the proof the renderer never suspended.
        #expect(await fixture.waitForFrame(containing: "park"))
        let entries = await fixture.log.entries
        #expect(entries.count == 1)
        if case .park = entries.first {
        } else {
            Issue.record("expected a single park attempt, got \(entries)")
        }
        #expect(transcriptTempFiles().subtracting(before).isEmpty)

        // No teardown bytes ever went out.
        #expect(fixture.sink.offsets(of: "\u{1B}[?1049l").isEmpty)
        try await fixture.renderer.restoreTerminal()
    }
}
