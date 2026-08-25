import Foundation
import OpenGrokPTY
import OpenGrokShared
import OpenGrokTTY
import Testing

@testable import OpenGrokCLI

private final class WrapTestRawModeLease: RawModeLease, @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0

    func release() async {
        recordRelease()
    }

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }

    private func recordRelease() {
        lock.lock()
        releases += 1
        lock.unlock()
    }
}

private struct WrapTestTTY: TTYAdapter {
    let lease: WrapTestRawModeLease

    var identifier: String? { "wrap-test" }
    func isATTY() -> Bool { true }
    func size() -> OpenGrokTTY.TerminalSize? {
        OpenGrokTTY.TerminalSize(width: 92, height: 31)
    }
    func capabilities() -> OpenGrokTTY.TerminalCapability {
        OpenGrokTTY.TerminalCapability()
    }
    func enterRawMode() async throws -> any RawModeLease { lease }
    func write(_ data: Data) async throws {
        _ = data
    }
}

private actor WrapClipboardCapture {
    private var values: [Data] = []

    func append(_ value: Data) {
        values.append(value)
    }

    func snapshot() -> [Data] {
        values
    }
}

private struct CancelledWrapPTY: PTYAdapter {
    func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        _ = spec
        throw PTYError.cancelled
    }
}

private func wrapTestDependencies(
    interactive: Bool,
    stdout: BufferedStream,
    stderr: BufferedStream,
    clipboard: WrapClipboardCapture = WrapClipboardCapture(),
    lease: WrapTestRawModeLease = WrapTestRawModeLease(),
    input: Data? = nil
) -> LiveWrapExecutionDependencies {
    LiveWrapExecutionDependencies(
        pty: PlatformPTYAdapter(),
        terminal: WrapTestTTY(lease: lease),
        interactive: { interactive },
        writeOutput: { stdout.write(String(decoding: $0, as: UTF8.self)) },
        writeError: { stderr.write(String(decoding: $0, as: UTF8.self)) },
        writeClipboard: { await clipboard.append($0) },
        readClipboardImage: { nil },
        appearance: { "dark" },
        input: input,
        forwardStandardInput: false
    )
}

@Suite("Live open-grok wrap subprocess and OSC 52 parity")
struct LiveWrapCompositionTests {
    private var environment: [String: String] {
        [
            "HOME": FileManager.default.temporaryDirectory.path,
            "OPENGROK_HOME": FileManager.default.temporaryDirectory
                .appendingPathComponent("opengrok-wrap-test-\(UUID().uuidString)").path,
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/sh",
            "GROK_SANDBOX": "off",
        ]
    }

    @Test("alias fallback leaves only the executable bare and safely quotes every argument")
    func shellFallbackNeverExpandsArguments() {
        #if !os(Windows)
        let plan = LiveWrapComposition.deriveSpawn(
            command: ["an_alias", ";touch /tmp/no", "don't", "$HOME", "", "=word"],
            shell: "/bin/sh",
            executableAvailable: false,
            mode: .interactive
        )

        #expect(plan.executable == "/bin/sh")
        #expect(plan.arguments == [
            "-i", "-c", "an_alias ';touch /tmp/no' 'don'\\''t' '$HOME' '' '=word'",
        ])
        #expect(LiveWrapComposition.quoteShellWord("`id` && echo") == "'`id` && echo'")
        #endif
    }

    @Test("explicit, empty, and whitespace-bearing executable words retain direct argv")
    func unsafeFirstWordsDoNotBecomeShellPrograms() {
        for first in ["./missing", "/bin/sh", "", "white space"] {
            let plan = LiveWrapComposition.deriveSpawn(
                command: [first, "tail;$(id)"],
                shell: "/bin/sh",
                executableAvailable: false,
                mode: .interactive
            )
            #expect(plan.executable == first)
            #expect(plan.arguments == ["tail;$(id)"])
        }
    }

    @Test("a sole complete shell command uses interactive or plain mode exactly as upstream")
    func singleShellCommandRespectsTerminalMode() {
        #if !os(Windows)
        let interactive = LiveWrapComposition.deriveSpawn(
            command: ["printf hello | cat"],
            shell: "/bin/sh",
            executableAvailable: false,
            mode: .interactive
        )
        let plain = LiveWrapComposition.deriveSpawn(
            command: ["printf hello | cat"],
            shell: "/bin/sh",
            executableAvailable: false,
            mode: .plain
        )

        #expect(interactive.arguments == ["-i", "-c", "printf hello | cat"])
        #expect(plain.arguments == ["-c", "printf hello | cat"])
        #endif
    }

    @Test("non-TTY children preserve separate stdout/stderr and their exact exit status")
    func fallbackKeepsSeparateStreamsAndExitCode() async {
        #if !os(Windows)
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let options = CLIUtilityOptions(
            name: "wrap",
            values: ["/bin/sh", "-c", "printf output; printf error >&2; exit 7"]
        )
        let dependencies = wrapTestDependencies(interactive: false, stdout: stdout, stderr: stderr)

        let code = await LiveWrapComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: dependencies
        )

        #expect(code == 7)
        #expect(stdout.contents == "output")
        #expect(stderr.contents == "error")
        #endif
    }

    @Test("piped fallback stdin reaches the child without merging stderr")
    func fallbackForwardsProvidedInput() async {
        #if !os(Windows)
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let options = CLIUtilityOptions(
            name: "wrap",
            values: ["/bin/sh", "-c", "IFS= read -r item; printf '<%s>' \"$item\"; printf side >&2"]
        )
        let dependencies = wrapTestDependencies(
            interactive: false,
            stdout: stdout,
            stderr: stderr,
            input: Data("piped 🌍\n".utf8)
        )

        let code = await LiveWrapComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: dependencies
        )

        #expect(code == 0)
        #expect(stdout.contents == "<piped 🌍>")
        #expect(stderr.contents == "side")
        #endif
    }

    @Test("non-TTY fallback never invents wrapped clipboard or appearance markers")
    func fallbackDoesNotAdvertiseClipboardSink() async {
        #if !os(Windows)
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let options = CLIUtilityOptions(
            name: "wrap",
            values: ["/bin/sh", "-c", "printf '%s|%s|%s' \"$GROK_OSC52_SINK\" \"$LC_GROK_OSC52_SINK\" \"$GROK_APPEARANCE\""]
        )
        let dependencies = wrapTestDependencies(interactive: false, stdout: stdout, stderr: stderr)

        let code = await LiveWrapComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: dependencies
        )

        #expect(code == 0)
        #expect(stdout.contents == "||")
        #expect(stderr.contents.isEmpty)
        #endif
    }

    @Test("real PTY children receive both sink markers, both appearance values, and a terminal")
    func wrappedChildReceivesTerminalAndEnvironment() async {
        #if os(macOS) || os(Linux)
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let lease = WrapTestRawModeLease()
        let options = CLIUtilityOptions(
            name: "wrap",
            values: [
                "/bin/sh", "-c",
                "test -t 0 && printf '%s|%s|%s|%s' \"$GROK_OSC52_SINK\" "
                    + "\"$LC_GROK_OSC52_SINK\" \"$GROK_APPEARANCE\" \"$LC_GROK_APPEARANCE\"; exit 6",
            ]
        )
        let dependencies = wrapTestDependencies(
            interactive: true,
            stdout: stdout,
            stderr: stderr,
            lease: lease
        )

        let code = await LiveWrapComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: dependencies
        )

        #expect(code == 6)
        #expect(stdout.contents == "1|1|dark|dark")
        #expect(stderr.contents.isEmpty)
        #expect(lease.releaseCount == 1)
        #endif
    }

    @Test("wrapped PTY consumes OSC 52, delivers clipboard content, and repairs abandoned DEC modes")
    func wrappedChildBridgesClipboardAndRestoresTerminal() async {
        #if os(macOS) || os(Linux)
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let clipboard = WrapClipboardCapture()
        let lease = WrapTestRawModeLease()
        let options = CLIUtilityOptions(
            name: "wrap",
            values: [
                "/bin/sh", "-c",
                "printf 'before\\033]52;c;aGVsbG8=\\007after\\033[?1000h'",
            ]
        )
        let dependencies = wrapTestDependencies(
            interactive: true,
            stdout: stdout,
            stderr: stderr,
            clipboard: clipboard,
            lease: lease
        )

        let code = await LiveWrapComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: dependencies
        )

        #expect(code == 0)
        #expect(stdout.contents == "beforeafter\u{1b}[?1000h\u{1b}[?1000l")
        #expect(await clipboard.snapshot() == [Data("hello".utf8)])
        #expect(stderr.contents.isEmpty)
        #expect(lease.releaseCount == 1)
        #endif
    }

    @Test("the actual async CLI seam executes wrap and propagates the child's status")
    func executableRunnerReachesWrapComposition() async {
        #if !os(Windows)
        let (streams, stdout, stderr) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["wrap", "/bin/sh", "-c", "printf live-seam; exit 9"],
            environment: environment,
            streams: streams,
            application: .unavailable
        )

        #expect(code == 9)
        #expect(stdout.contents == "live-seam")
        #expect(stderr.contents.isEmpty)
        #endif
    }

    @Test("a cancelled PTY never relaunches the command outside its wrapper")
    func cancelledPTYNeverFallsBackToExecution() async {
        let (streams, stdout, stderr) = CLIStreams.buffered()
        var dependencies = wrapTestDependencies(
            interactive: true,
            stdout: stdout,
            stderr: stderr
        )
        dependencies.pty = CancelledWrapPTY()
        let options = CLIUtilityOptions(
            name: "wrap",
            values: ["/bin/sh", "-c", "printf should-not-run"]
        )

        let code = await LiveWrapComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: dependencies
        )

        #expect(code == CLIRunner.ExitCode.cancelled.rawValue)
        #expect(stdout.contents.isEmpty)
        #expect(stderr.contents.isEmpty)
    }
}
