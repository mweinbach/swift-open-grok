// OpenGrokPagerPTYHarness.swift
//
// Drives the built `open-grok` binary under a real PTY and reconstructs what a
// terminal would have shown, so end-to-end scenarios assert on rendered frames
// rather than on a raw byte stream.
//
// Rust crate mapping: `xai-grok-pager-pty-harness` (see CRATE_MAP.md);
// upstream's reference scenarios live in `xai-grok-pager/tests/pty_e2e`.
//
// SCOPE — read before extending. PORT_PLAN W11-S3 asks for the full scenario
// matrix (streaming, tool/permission prompts, plan, Code Mode, subagents,
// rewind/compaction, MCP, background work, suspend). Implemented here is the
// transport and capture layer plus the scenarios that need no model: spawn
// under a PTY at a chosen size, an isolated `OPENGROK_HOME`, scripted input,
// and a virtual screen to assert against.
//
// The base-URL seam that inference-backed scenarios need now exists:
// `LiveComposition.resolveProviderBaseURL` reads `GROK_XAI_API_BASE_URL`
// (and the per-provider equivalents), and `[endpoints] xai_api_base_url`
// overrides it — so a scenario can aim the spawned binary at a mock
// HTTP/SSE server through `PagerPTYHarness.environment`.
//
// Driving one of those exchanges needs `PagerPTYSession`, not `run`: `run`
// writes all of its input before waiting for exit, so a trailing `/quit`
// would race the reply it is supposed to let finish.
//
// `OpenGrokTerminalCore` is deliberately not imported: it declares its own
// `TerminalSize` alongside `OpenGrokTTY`'s, and importing both would make the
// name ambiguous here. It is a renderer in any case; this file needs a parser.

import Foundation
import OpenGrokPTY
import OpenGrokTTY

// MARK: - Virtual screen

/// A character grid reconstructed from a child process's PTY output.
///
/// A deliberately small ANSI interpreter, not a terminal emulator: it covers
/// what the CLI actually emits on these paths — printable text, `CR`/`LF`/
/// `BS`/`TAB`, cursor positioning and relative motion, and erase-in-line /
/// erase-in-display. Everything else (SGR colours, mode sets, OSC strings) is
/// parsed only well enough to be skipped so it cannot corrupt the grid.
/// Extending this is expected; silently mis-rendering is not, so an unhandled
/// sequence is dropped rather than printed as text.
public struct VirtualScreen: Sendable, Equatable {
    public private(set) var rows: [[Character]]
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorColumn: Int = 0
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.rows = Array(
            repeating: Array(repeating: " ", count: self.width),
            count: self.height
        )
    }

    public init(size: TerminalSize) {
        self.init(width: size.width, height: size.height)
    }

    /// Every row, trailing spaces trimmed.
    public var lines: [String] {
        rows.map { row in
            var line = String(row)
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// The screen as text, with trailing blank lines removed.
    public var text: String {
        var out = lines
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Whether some single row contains `needle`.
    ///
    /// Prefer this over searching ``text`` when a match must not straddle a
    /// line break.
    public func containsInAnyRow(_ needle: String) -> Bool {
        lines.contains { $0.contains(needle) }
    }

    // MARK: Feeding

    /// Interpret `text` and update the grid.
    public mutating func feed(_ text: String) {
        // Swift models "\r\n" as a SINGLE `Character` (scalars [13, 10]), so
        // iterating `Character`s would match neither "\r" nor "\n" and drop the
        // line break entirely as an unrecognized control. PTY output is almost
        // entirely CRLF — the tty driver's ONLCR translates on the way out — so
        // this would have mis-rendered essentially every captured frame. Split
        // any grapheme carrying a control scalar back into its scalars first.
        var characters: [Character] = []
        for character in text {
            let scalars = character.unicodeScalars
            if scalars.count > 1, scalars.contains(where: { $0.value < 0x20 }) {
                characters.append(contentsOf: scalars.map(Character.init))
            } else {
                characters.append(character)
            }
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\u{1B}":
                index = consumeEscape(characters, from: index)
            case "\r":
                cursorColumn = 0
                index += 1
            case "\n":
                lineFeed()
                index += 1
            case "\u{08}":
                cursorColumn = max(0, cursorColumn - 1)
                index += 1
            case "\t":
                cursorColumn = min(width - 1, (cursorColumn / 8 + 1) * 8)
                index += 1
            default:
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                    index += 1
                } else {
                    put(character)
                    index += 1
                }
            }
        }
    }

    /// Interpret `data` as UTF-8 and feed it.
    public mutating func feed(_ data: Data) {
        feed(String(decoding: data, as: UTF8.self))
    }

    // MARK: Grid primitives

    private mutating func put(_ character: Character) {
        if cursorColumn >= width {
            cursorColumn = 0
            lineFeed()
        }
        rows[cursorRow][cursorColumn] = character
        cursorColumn += 1
    }

    private mutating func lineFeed() {
        if cursorRow + 1 < height {
            cursorRow += 1
        } else {
            rows.removeFirst()
            rows.append(Array(repeating: " ", count: width))
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<width { rows[cursorRow][column] = " " }
        case 1:
            for column in 0...min(cursorColumn, width - 1) { rows[cursorRow][column] = " " }
        case 2:
            rows[cursorRow] = Array(repeating: " ", count: width)
        default:
            break
        }
    }

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < height {
                for row in (cursorRow + 1)..<height {
                    rows[row] = Array(repeating: " ", count: width)
                }
            }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { rows[row] = Array(repeating: " ", count: width) }
        case 2, 3:
            rows = Array(repeating: Array(repeating: " ", count: width), count: height)
        default:
            break
        }
    }

    /// Consume one escape sequence starting at `start`; returns the index just
    /// past it.
    private mutating func consumeEscape(_ characters: [Character], from start: Int) -> Int {
        var index = start + 1
        guard index < characters.count else { return characters.count }

        switch characters[index] {
        case "[":
            index += 1
            var parameters = ""
            while index < characters.count,
                  characters[index].isNumber
                    || characters[index] == ";"
                    || characters[index] == "?" {
                parameters.append(characters[index])
                index += 1
            }
            guard index < characters.count else { return characters.count }
            let final = characters[index]
            index += 1
            applyCSI(final: final, parameters: parameters)
            return index
        case "]":
            // OSC runs to BEL or ST (ESC \).
            index += 1
            while index < characters.count {
                if characters[index] == "\u{07}" { return index + 1 }
                if characters[index] == "\u{1B}",
                   index + 1 < characters.count,
                   characters[index + 1] == "\\" {
                    return index + 2
                }
                index += 1
            }
            return characters.count
        default:
            // Two-character escapes (charset selection, RI, and friends).
            return index + 1
        }
    }

    private mutating func applyCSI(final: Character, parameters: String) {
        // Private-mode sequences (`ESC [ ? … h/l`) toggle terminal modes and
        // never touch the grid.
        guard !parameters.hasPrefix("?") else { return }
        let numbers = parameters
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        func parameter(_ position: Int, default fallback: Int) -> Int {
            guard position < numbers.count, numbers[position] != 0 else { return fallback }
            return numbers[position]
        }

        switch final {
        case "H", "f":
            cursorRow = min(height - 1, max(0, parameter(0, default: 1) - 1))
            cursorColumn = min(width - 1, max(0, parameter(1, default: 1) - 1))
        case "A": cursorRow = max(0, cursorRow - parameter(0, default: 1))
        case "B": cursorRow = min(height - 1, cursorRow + parameter(0, default: 1))
        case "C": cursorColumn = min(width - 1, cursorColumn + parameter(0, default: 1))
        case "D": cursorColumn = max(0, cursorColumn - parameter(0, default: 1))
        case "G": cursorColumn = min(width - 1, max(0, parameter(0, default: 1) - 1))
        case "d": cursorRow = min(height - 1, max(0, parameter(0, default: 1) - 1))
        case "J": eraseInDisplay(numbers.first ?? 0)
        case "K": eraseInLine(numbers.first ?? 0)
        default:
            // SGR ("m") and the rest carry no grid effect here.
            break
        }
    }
}

// MARK: - Scenario result

/// What one harness run observed.
public struct ScenarioResult: Sendable {
    /// The reconstructed terminal contents at exit.
    public let screen: VirtualScreen
    /// Every byte the child wrote, in order, for byte-level assertions.
    public let rawOutput: Data
    /// The child's exit status.
    public let exit: ProcessExit
    /// The isolated `OPENGROK_HOME` the run used, so a scenario can assert on
    /// files the CLI wrote.
    public let openGrokHome: URL
    /// The scenario's sandbox root. Delete it to clean up.
    public let sandbox: URL

    public var text: String { screen.text }
}

/// Why a harness run could not be completed.
public enum PTYHarnessError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case timedOut(afterSeconds: TimeInterval)

    public var description: String {
        switch self {
        case let .binaryNotFound(path):
            return """
                open-grok binary not found at \(path); build it first \
                (`swift build --product open-grok`) or set OPENGROK_TEST_BINARY
                """
        case let .timedOut(seconds):
            return "the harness run did not finish within \(seconds)s"
        }
    }
}

// MARK: - Harness

/// Spawns `open-grok` under a PTY and captures rendered output.
///
/// Every run gets a fresh `OPENGROK_HOME` and an environment scrubbed of the
/// developer's own configuration, so no scenario can depend on real
/// `~/.opengrok` state, installed binaries, or credentials.
public struct PagerPTYHarness: Sendable {
    public var size: TerminalSize
    /// Wall-clock budget for a run. `Duration` needs macOS 13; this package
    /// targets macOS 12, so the budget is plain seconds.
    public var timeoutSeconds: TimeInterval
    /// Extra environment entries layered over the scrubbed base.
    public var environment: [String: String]

    public init(
        size: TerminalSize = TerminalSize(width: 100, height: 30),
        timeoutSeconds: TimeInterval = 30,
        environment: [String: String] = [:]
    ) {
        self.size = size
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
    }

    /// Locate the built binary.
    ///
    /// `OPENGROK_TEST_BINARY` wins so a scenario can aim at a specific build;
    /// otherwise the binary is looked up beside the running test bundle, which
    /// is where SwiftPM puts the product.
    public static func defaultBinaryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let explicit = environment["OPENGROK_TEST_BINARY"], !explicit.isEmpty {
            return explicit
        }
        // The test host's layout differs by platform: a macOS `.xctest` bundle
        // puts the runner at `<build>/Foo.xctest/Contents/MacOS/Foo`, while a
        // plain executable host sits directly in `<build>/`. Walk up from both
        // the running executable and the bundle rather than assuming one shape.
        // Guessing wrong makes every scenario *skip*, which reads as green
        // while proving nothing — so this searches instead of assuming.
        // Nothing at runtime points back at `.build`. SwiftPM runs the suite
        // through `swiftpm-testing-helper`, so `argv[0]` and `Bundle.main` are
        // both inside the toolchain and `Bundle.allBundles` is empty — measured,
        // not assumed. The compile-time source location is the only anchor to
        // the package, so walk up from it to `Package.swift` and look in the
        // build directories beneath.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                let build = directory.appendingPathComponent(".build")
                // `workflow-safe` is the scratch path the repo's verify wrapper
                // uses; `debug` is a plain `swift build`.
                for relative in ["workflow-safe/debug/open-grok", "debug/open-grok"] {
                    let candidate = build.appendingPathComponent(relative)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        return candidate.path
                    }
                }
                return build.appendingPathComponent("debug/open-grok").path
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return "open-grok"
    }

    /// Whether a runnable binary is available, so a scenario can skip rather
    /// than fail when the product has not been built.
    public static func binaryIsAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        FileManager.default.isExecutableFile(atPath: defaultBinaryPath(environment: environment))
    }

    /// Run `open-grok` with `arguments` under a PTY, writing each element of
    /// `input` to the terminal once the child has started.
    ///
    /// Returns when the child exits. A child that outlives ``timeoutSeconds``
    /// is killed and the call throws ``PTYHarnessError/timedOut(afterSeconds:)`` — the
    /// harness never blocks indefinitely on a wedged process, and it never
    /// uses `Process.waitUntilExit`, which is banned in this codebase.
    public func run(
        arguments: [String],
        input: [String] = [],
        binary: String? = nil,
        workingDirectory: URL? = nil
    ) async throws -> ScenarioResult {
        let session = try await start(
            arguments: arguments,
            binary: binary,
            workingDirectory: workingDirectory
        )
        do {
            for line in input {
                try await session.write(line)
            }
            return try await session.finish(timeoutSeconds: timeoutSeconds)
        } catch {
            await session.terminate()
            try? FileManager.default.removeItem(at: session.sandbox)
            throw error
        }
    }

    /// Spawn `open-grok` and hand back a live session instead of waiting for it
    /// to exit, so a scenario can interleave writing and observing.
    ///
    /// The caller owns the child from here: finish it with
    /// ``PagerPTYSession/finish(timeoutSeconds:)`` or kill it with
    /// ``PagerPTYSession/terminate()``, and delete `sandbox` either way.
    public func start(
        arguments: [String],
        binary: String? = nil,
        workingDirectory: URL? = nil
    ) async throws -> PagerPTYSession {
        let binaryPath = binary ?? Self.defaultBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw PTYHarnessError.binaryNotFound(binaryPath)
        }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokPTYHarness-\(UUID().uuidString)", isDirectory: true)
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let cwd = workingDirectory ?? sandbox.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let process = try await PlatformPTYAdapter().spawn(
            ProcessSpec(
                command: binaryPath,
                arguments: arguments,
                environment: isolatedEnvironment(home: home),
                workingDirectory: cwd.path,
                usePTY: true,
                initialSize: size,
                newProcessGroup: true
            )
        )
        let session = PagerPTYSession(
            process: process,
            size: size,
            sandbox: sandbox,
            openGrokHome: home
        )
        // Drain concurrently with everything else: a child that fills the PTY
        // buffer while nobody reads would block forever on write.
        await session.beginDraining()
        return session
    }

    /// `PATH`/`HOME` plus a terminal identity, with the developer's
    /// `OPENGROK_*` settings deliberately absent so no run inherits real state.
    private func isolatedEnvironment(home: URL) -> [String: String] {
        var result: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "COLUMNS": String(size.width),
            "LINES": String(size.height),
            // Keep runs deterministic and offline.
            "NO_COLOR": "1",
            "CI": "1",
        ]
        for (key, value) in environment { result[key] = value }
        return result
    }
}

// MARK: - Session

/// A spawned `open-grok` that is still running, so a scenario can write, watch
/// the screen react, and only then write again.
///
/// ``PagerPTYHarness/run(arguments:input:binary:workingDirectory:)`` writes all
/// of its input up front, which cannot express "send a prompt, let the reply
/// stream, then quit" — the quit would race the reply. An inference-backed
/// exchange needs this type.
public actor PagerPTYSession {
    private let process: any PTYProcess
    private let size: TerminalSize
    /// The run's scratch directory. The caller deletes it.
    public nonisolated let sandbox: URL
    public nonisolated let openGrokHome: URL

    private var raw = Data()
    private var drain: Task<Void, Never>?
    private var finished = false

    init(process: any PTYProcess, size: TerminalSize, sandbox: URL, openGrokHome: URL) {
        self.process = process
        self.size = size
        self.sandbox = sandbox
        self.openGrokHome = openGrokHome
    }

    func beginDraining() {
        guard drain == nil else { return }
        drain = Task { [process] in
            // A closed PTY surfaces as a throw; that is the child exiting, not
            // a scenario failure, so the accumulated bytes stand.
            do {
                for try await chunk in process.output() {
                    await self.append(chunk)
                }
            } catch {}
        }
    }

    private func append(_ chunk: Data) { raw.append(chunk) }

    /// Write raw bytes to the terminal. Include `\r` to press Return — a PTY in
    /// canonical mode takes CR, not LF, as the line terminator.
    public func write(_ text: String) async throws {
        try await process.write(Data(text.utf8))
    }

    /// What a terminal would be showing right now.
    public func screen() -> VirtualScreen {
        var screen = VirtualScreen(size: size)
        screen.feed(raw)
        return screen
    }

    public func text() -> String { screen().text }

    /// Poll the rendered screen until some row contains `needle`.
    ///
    /// Returns whether it appeared, so a caller can assert on the result rather
    /// than on a bare timeout. Polling the *screen* (not the raw bytes) is what
    /// makes this CRLF- and redraw-aware: a TUI that repaints a line still ends
    /// up with the text on a row, even though the bytes never contain it
    /// contiguously.
    public func waitForScreen(
        containing needle: String,
        timeoutSeconds: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if screen().containsInAnyRow(needle) { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return screen().containsInAnyRow(needle)
    }

    /// Wait for the child to exit within `timeoutSeconds`, then snapshot it.
    ///
    /// A child that overruns is killed and the call throws
    /// ``PTYHarnessError/timedOut(afterSeconds:)``. Never uses
    /// `Process.waitUntilExit`, which is banned in this codebase.
    public func finish(timeoutSeconds: TimeInterval) async throws -> ScenarioResult {
        let exit: ProcessExit
        do {
            exit = try await withThrowingTaskGroup(of: ProcessExit.self) { group in
                group.addTask { [process] in try await process.waitForExit() }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)
                    )
                    throw PTYHarnessError.timedOut(afterSeconds: timeoutSeconds)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            await terminate()
            throw error
        }

        // The child has exited; let the drain flush its buffered tail.
        _ = await drain?.value
        await process.cancel()
        finished = true
        return ScenarioResult(
            screen: screen(),
            rawOutput: raw,
            exit: exit,
            openGrokHome: openGrokHome,
            sandbox: sandbox
        )
    }

    /// Kill the child and stop draining. Safe to call twice.
    public func terminate() async {
        guard !finished else { return }
        finished = true
        try? await process.signal(.kill)
        drain?.cancel()
        await process.cancel()
    }
}
