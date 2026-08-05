import Foundation
import Testing
@testable import OpenGrokCLI

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class TerminalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}

@Suite("OpenGrokExecutable composition")
struct OpenGrokExecutableTests {
    @Test("live interactive composition renders and restores full-screen terminal")
    func liveInteractiveFullScreenComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminalRecorder = TerminalRecorder()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 60, height: 12) },
            write: { terminalRecorder.append($0) }
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.status("thinking"))
                    await emit(.output("interactive answer"))
                    return OpenGrokLiveSamplingResponse(output: "interactive answer", stopReason: "stop")
                }
            },
            terminal: terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["interactive", "--prompt", "show the pager", "--fullscreen"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(terminalRecorder.string.contains("\u{1B}[?1049h"))
        // The session screen has no title banner — its chrome is the composer
        // box and the shortcuts bar.
        #expect(terminalRecorder.string.contains("\u{256D}"))
        #expect(terminalRecorder.string.contains("Ctrl+c:cancel"))
        #expect(terminalRecorder.string.contains("\u{1B}[?1049l"))
        #expect(terminalRecorder.string.hasSuffix("You: show the pager\nGrok: interactive answer\n"))
    }

    @Test("live interactive composition falls back inline without a TTY")
    func liveInteractiveInlineComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminalRecorder = TerminalRecorder()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { nil },
            write: { terminalRecorder.append($0) }
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.output("inline answer"))
                    return OpenGrokLiveSamplingResponse(output: "inline answer")
                }
            },
            terminal: terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["interactive", "--prompt", "show inline"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(terminalRecorder.string == "You: show inline\nGrok: inline answer\n")
    }

    /// Root `--minimal` must degrade, never refuse.
    ///
    /// The sibling case above cannot catch this: it does not pass `--minimal`,
    /// so it never produces `OpenGrokPagerMode.minimal`. When `--minimal` was
    /// first wired, the only path that produced `.minimal` without a usable
    /// terminal was also the one that rejected it, and the flag failed with
    /// "unsupported: interactive pager mode minimal" where it had previously
    /// worked. Upstream treats `--minimal` as a scrollback-native *preference*,
    /// so inline is a faithful downgrade — unlike `--fullscreen`, which has no
    /// sane non-TTY equivalent and is right to throw.
    ///
    /// Asserting on the exit code and the absence of a refusal rather than on
    /// exact terminal bytes: the regression is "this errors instead of
    /// running", and pinning the byte stream here would just duplicate the
    /// sibling's assertion while making this case brittle to render changes.
    @Test("root --minimal degrades instead of refusing without a TTY")
    func liveMinimalRenderingFallsBackInline() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminalRecorder = TerminalRecorder()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { nil },
            write: { terminalRecorder.append($0) }
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.output("minimal answer"))
                    return OpenGrokLiveSamplingResponse(output: "minimal answer")
                }
            },
            terminal: terminal
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        // The root form: `--minimal` with a positional prompt. The `minimal`
        // mode word is a different feature (a one-shot run) and would not
        // exercise `minimalRendering`.
        let code = await CLIRunner.run(
            ["--minimal", "show minimal"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(code != CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(out.contents.isEmpty)
        #expect(!err.contents.contains("unsupported"))
        #expect(!err.contents.contains("interactive pager mode"))
        #expect(terminalRecorder.string.contains("minimal answer"))
    }

    @Test("live headless composition runs prompt through shell and pager")
    func liveHeadlessComposition() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = InvocationRecorder()
        let dependencies = OpenGrokLiveCompositionDependencies { configuration in
            recorder.append("config:\(configuration.model):\(configuration.baseURL)")
            return OpenGrokLiveSampler { request, emit in
                recorder.append("sample:\(request.prompt):\(request.model)")
                await emit(.status("thinking"))
                await emit(.output("Swift answer"))
                return OpenGrokLiveSamplingResponse(output: "Swift answer", stopReason: "end_turn")
            }
        }
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "port this", "--model", "grok-test"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key",
                "GROK_XAI_API_BASE_URL": "http://127.0.0.1:9999/v1"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(out.contents == "Swift answer\n")
        #expect(err.contents == "open-grok: thinking\n")
        #expect(recorder.snapshot == [
            "config:grok-test:http://127.0.0.1:9999/v1",
            "sample:port this:grok-test"
        ])
    }

    @Test("live minimal composition emits one collected JSON result")
    func liveMinimalJSONComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = OpenGrokLiveCompositionDependencies { _ in
            OpenGrokLiveSampler { _, emit in
                await emit(.output("structured answer"))
                return OpenGrokLiveSamplingResponse(output: "structured answer", stopReason: "stop")
            }
        }
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["minimal", "--prompt-json", "{\"prompt\":\"render it\"}", "--output-format", "json"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key"
            ],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(err.contents.isEmpty)
        let data = try #require(out.contents.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "completed")
        #expect(object["output"] as? String == "structured answer")
        #expect(object["summary"] as? String == "stop")
        #expect(object["session_id"] as? String != nil)
    }

    @Test("live composition routes Codex to its own store and fails closed when unauthenticated")
    func liveCodexRequiresItsOwnCredentials() async throws {
        // The Codex route is wired now, so the provider is no longer refused
        // outright. It must still fail closed when the isolated Codex store
        // holds nothing — and it must not fall back to the xAI key that is set
        // here, which is the credential-isolation contract.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let application = OpenGrokApplication.live(control: .never)
        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "hello", "--provider", "codex"],
            environment: ["XAI_API_KEY": "test-key", "OPENGROK_HOME": home.path],
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("login --codex"))
        #expect(!err.contents.contains("Codex OAuth provider"))
    }

    @Test("async dispatch owns startup, wait, and shutdown")
    func lifecycleOwnership() async {
        let recorder = InvocationRecorder()
        let launcher = CLIApplicationLauncher { command, context in
            recorder.append("start:\(command.routeName):\(context.environment["TEST"] ?? "missing")")
            recorder.append("cancelled:\(context.control.isCancelled())")
            return CLIApplicationSession(
                waitForExit: { recorder.append("wait") },
                shutdown: { recorder.append("shutdown") }
            )
        }
        let application = OpenGrokApplication(
            launcher: launcher,
            control: .never
        )
        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["interactive", "--model", "grok-test"],
            environment: ["TEST": "composition"],
            streams: streams,
            application: application
        )
        #expect(code == 0)
        #expect(out.contents.isEmpty)
        #expect(err.contents.isEmpty)
        #expect(recorder.snapshot == [
            "start:interactive:composition",
            "cancelled:false",
            "wait",
            "shutdown"
        ])
    }

    @Test("launcher errors are reported as process failures")
    func launcherFailure() async {
        let launcher = CLIApplicationLauncher { _, _ in
            throw CLIApplicationError.failed("startup failed")
        }
        let application = OpenGrokApplication(launcher: launcher)
        let (streams, out, err) = CLIStreams.buffered()
        let code = await CLIRunner.run(["acp"], streams: streams, application: application)
        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("startup failed"))
    }

    @Test("cancellation is observable through the injected execution seam")
    func cancellationSeam() async {
        let recorder = InvocationRecorder()
        let control = CLIExecutionControl(
            isCancelled: { true },
            waitForCancellation: { recorder.append("wait-for-cancellation") }
        )
        let launcher = CLIApplicationLauncher { _, context in
            recorder.append(context.control.isCancelled() ? "cancelled" : "running")
            return CLIApplicationSession(
                waitForExit: {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    recorder.append("wait")
                },
                shutdown: { recorder.append("shutdown") }
            )
        }
        let application = OpenGrokApplication(launcher: launcher, control: control)
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(["minimal"], streams: streams, application: application)
        #expect(code == CLIRunner.ExitCode.cancelled.rawValue)
        #expect(recorder.snapshot == ["cancelled", "wait-for-cancellation", "shutdown"])
    }

    @Test("the synchronous product entry point never pretends runtime support")
    func syncEntryPointFailsClosed() {
        let (streams, out, err) = CLIStreams.buffered()
        let code = CLIRunner.main(["agent", "serve"], streams: streams)
        #expect(code == CLIRunner.ExitCode.notImplemented.rawValue)
        #expect(out.contents.isEmpty)
        #expect(err.contents.contains("unavailable"))
    }
}
