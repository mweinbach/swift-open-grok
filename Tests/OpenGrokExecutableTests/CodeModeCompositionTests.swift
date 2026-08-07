import Foundation
import OpenGrokCodeMode
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

/// Terminal capture. Same shape the parity suite uses: the renderer emits a
/// cursor move and an SGR run before every glyph, so only the escape-stripped
/// text is readable.
private final class CodeModeTerminalFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var terminal: OpenGrokLiveTerminal {
        let fixture = self
        return OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { data in fixture.append(data) }
        )
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }

    var paintedText: String {
        var result = ""
        var iterator = output[...]
        while let escape = iterator.firstIndex(of: "\u{1B}") {
            result += iterator[iterator.startIndex..<escape]
            var cursor = iterator.index(after: escape)
            guard cursor < iterator.endIndex else { break }
            if iterator[cursor] == "[" || iterator[cursor] == "]" {
                let isOSC = iterator[cursor] == "]"
                cursor = iterator.index(after: cursor)
                while cursor < iterator.endIndex {
                    let scalar = iterator[cursor].unicodeScalars.first!.value
                    let isFinal = isOSC
                        ? (scalar == 0x07 || iterator[cursor] == "\\")
                        : (scalar >= 0x40 && scalar <= 0x7E)
                    cursor = iterator.index(after: cursor)
                    if isFinal { break }
                }
            } else {
                cursor = iterator.index(after: cursor)
            }
            iterator = iterator[cursor...]
        }
        result += iterator
        return result
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

private final class CodeModeTerminalSink: PagerTerminalSink {
    let capabilities = PagerTerminalCapabilities.standard
    private let terminal: CodeModeTerminalFixture

    init(terminal: CodeModeTerminalFixture) {
        self.terminal = terminal
    }

    func write(bytes: [UInt8]) throws { terminal.append(Data(bytes)) }
    func flush() throws {}
}

/// A sampler that issues one tool call per round and answers with the last
/// tool result once it runs out of calls to make.
///
/// `next` receives the round index and the previous round's tool result, which
/// is how a `wait` gets the cell id the transport just handed the model.
private final class CodeModeSamplerFixture: @unchecked Sendable {
    typealias Next = @Sendable (Int, String?) -> ToolCall?

    private let lock = NSLock()
    private let next: Next
    private var requests: [OpenGrokLiveSamplingRequest] = []

    init(script: [ToolCall]) {
        let queue = CodeModeScriptQueue(script)
        self.next = { _, _ in queue.pop() }
    }

    init(next: @escaping Next) {
        self.next = next
    }

    var recordedRequests: [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Suspend until the model has been sampled `count` times.
    ///
    /// Cheaper and steadier than polling the terminal: `paintedText` rescans
    /// the whole accumulated frame buffer, which a full-screen renderer grows
    /// without bound.
    func waitForRounds(_ count: Int) async {
        for _ in 0..<2_000 {
            if recordedRequests.count >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The tool result the model saw for `callID`, if the turn got that far.
    func result(for callID: String) -> String? {
        recordedRequests
            .flatMap(\.items)
            .compactMap { item -> ToolResultItem? in
                guard case .toolResult(let result) = item else { return nil }
                return result
            }
            .last { $0.toolCallId == callID }?
            .content
    }

    func makeSampler() -> OpenGrokLiveSampler {
        let fixture = self
        return OpenGrokLiveSampler { request, emit in
            guard let call = fixture.recordAndAdvance(request) else {
                let results = request.items.compactMap { item -> ToolResultItem? in
                    guard case .toolResult(let result) = item else { return nil }
                    return result
                }
                let answer = "cell answer: \(results.last?.content ?? "no tool result")"
                await emit(.output(answer))
                return OpenGrokLiveSamplingResponse(output: answer, stopReason: "stop")
            }
            return OpenGrokLiveSamplingResponse(
                output: "",
                stopReason: "tool_calls",
                items: [.assistant(AssistantItem(content: "", toolCalls: [call]))]
            )
        }
    }

    private func recordAndAdvance(_ request: OpenGrokLiveSamplingRequest) -> ToolCall? {
        lock.lock()
        let round = requests.count
        requests.append(request)
        lock.unlock()
        let lastResult = request.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        }.last?.content
        return next(round, lastResult)
    }
}

private final class CodeModeScriptQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ToolCall]

    init(_ remaining: [ToolCall]) { self.remaining = remaining }

    func pop() -> ToolCall? {
        lock.lock()
        defer { lock.unlock() }
        return remaining.isEmpty ? nil : remaining.removeFirst()
    }
}

// MARK: - Helpers

private enum CodeModeFixtures {
    /// The function-envelope form of an `exec` call: the JavaScript body rides
    /// in `source`.
    static func exec(id: String, source: String) -> ToolCall {
        ToolCall(id: id, name: "exec", arguments: json(["source": source]))
    }

    static func wait(id: String, cellIDFrom text: String, yieldTimeMs: Int) -> ToolCall? {
        guard let cellID = cellID(in: text) else { return nil }
        return ToolCall(
            id: id,
            name: "wait",
            arguments: json(["cell_id": cellID, "yield_time_ms": yieldTimeMs])
        )
    }

    /// The transport tells the model the cell id in prose; a `wait` has to
    /// quote it back.
    static func cellID(in text: String) -> String? {
        guard let range = text.range(of: "Script running with cell ID ") else { return nil }
        let tail = text[range.upperBound...]
        let id = tail.prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func workspace() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func environment(root: URL, extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "HOME": root.path,
            "OPENGROK_HOME": root.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-key"
        ]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    static func typed(_ text: String) -> [InputEvent] {
        text.map { .key(KeyEvent(key: .char($0), character: $0)) }
    }

    static func waitForPaintedText(
        _ text: String,
        terminal: CodeModeTerminalFixture
    ) async {
        for _ in 0..<500 {
            if terminal.paintedText.contains(text) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func waitForTerminalOutput(
        _ text: String,
        terminal: CodeModeTerminalFixture
    ) async {
        for _ in 0..<500 {
            if terminal.output.contains(text) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private func codeModeToolNames(
    capability: CodeModeRuntimeCapability?
) async -> [String] {
    let root = CodeModeFixtures.workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let sampler = CodeModeSamplerFixture(script: [])
    let dependencies: OpenGrokLiveCompositionDependencies
    if let capability {
        dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() },
            makeCodeModeCapability: { capability }
        )
    } else {
        dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in sampler.makeSampler() }
        )
    }
    let application = OpenGrokApplication.live(
        dependencies: dependencies,
        control: .never
    )
    let (streams, _, _) = CLIStreams.buffered()
    let code = await CLIRunner.run(
        ["headless", "--prompt", "hello", "--cwd", root.path],
        environment: CodeModeFixtures.environment(
            root: root,
            extra: ["OPENGROK_TOOL_MODE": "code_mode"]
        ),
        streams: streams,
        application: application
    )
    #expect(code == CLIRunner.ExitCode.success.rawValue)
    return sampler.recordedRequests.first?.tools.map(\.name) ?? []
}

// MARK: - Tests

@Suite("Code Mode live composition")
struct CodeModeCompositionTests {

    @Test("an unavailable runtime suppresses the Code Mode transport")
    func unavailableRuntimeDoesNotAdvertiseTransport() async {
        let names = await codeModeToolNames(capability: .unavailable)
        #expect(names.contains("exec") == false)
        #expect(names.contains("wait") == false)
        #expect(names.contains("read_file"))
        #expect(names.contains("run_terminal_cmd"))
    }

#if !canImport(JavaScriptCore)
    @Test("the default non-JavaScriptCore capability suppresses the transport")
    func defaultRuntimeDoesNotAdvertiseTransport() async {
        let names = await codeModeToolNames(capability: nil)
        #expect(names.contains("exec") == false)
        #expect(names.contains("wait") == false)
        #expect(names.contains("read_file"))
        #expect(names.contains("run_terminal_cmd"))
    }
#endif

#if canImport(JavaScriptCore)

    // MARK: Tool surface

    @Test("code_mode keeps ordinary tools top-level and adds exec and wait")
    func codeModeAdvertisesBothSurfaces() async {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = CodeModeSamplerFixture(script: [])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "hello", "--cwd", root.path],
            environment: CodeModeFixtures.environment(
                root: root,
                extra: ["OPENGROK_TOOL_MODE": "code_mode"]
            ),
            streams: streams,
            application: application
        )

        let names = sampler.recordedRequests.first?.tools.map(\.name) ?? []
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(names.contains("exec"))
        #expect(names.contains("wait"))
        #expect(names.contains("read_file"))
        #expect(names.contains("run_terminal_cmd"))
        // `exec` and `wait` are appended after the ordinary tools, and the
        // description carries the nested namespace the cell can reach.
        #expect(names.suffix(2) == ["exec", "wait"])
        let exec = sampler.recordedRequests.first?.tools.first { $0.name == "exec" }
        #expect(exec?.description?.contains("tools.exec_command") == true)
    }

    @Test("code_mode_only hides every tool the cell can reach through tools.*")
    func codeModeOnlyHidesDirectTools() async {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = CodeModeSamplerFixture(script: [])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "hello", "--cwd", root.path],
            environment: CodeModeFixtures.environment(
                root: root,
                extra: ["OPENGROK_TOOL_MODE": "code_mode_only"]
            ),
            streams: streams,
            application: application
        )

        let names = sampler.recordedRequests.first?.tools.map(\.name) ?? []
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        // Only the direct-only tools survive alongside the transport pair. The
        // three background-task consumers are on that list on purpose: they
        // hold the turn until a task finishes, which a cell's yield timer
        // cannot survive — the timer would hand control back to the model while
        // the wait is still outstanding. `spawn_subagent` is in the same class:
        // a foreground spawn parks the turn on the child
        // (`is_code_mode_direct_only_tool`, session/code_mode.rs:68).
        #expect(
            Set(names) == ["get_task_output", "wait_tasks", "kill_task", "spawn_subagent", "exec", "wait"]
        )
        // The transport pair is always last, after any direct-only tool.
        #expect(names.suffix(2) == ["exec", "wait"])
        // Only-mode is what makes the exec description carry the typed
        // declarations for the nested namespace.
        let exec = sampler.recordedRequests.first?.tools.first { $0.name == "exec" }
        #expect(exec?.description?.contains("### `read_file`") == true)
    }

    @Test("direct mode leaves the tool surface untouched")
    func directModeAdvertisesNoTransport() async {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampler = CodeModeSamplerFixture(script: [])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()

        _ = await CLIRunner.run(
            ["headless", "--prompt", "hello", "--cwd", root.path],
            environment: CodeModeFixtures.environment(root: root),
            streams: streams,
            application: application
        )

        let names = sampler.recordedRequests.first?.tools.map(\.name) ?? []
        #expect(names.contains("read_file"))
        #expect(names.contains("exec") == false)
        #expect(names.contains("wait") == false)
    }

    // MARK: Config

    @Test("[ui] code_mode selects the tool mode, including the legacy boolean")
    func configSelectsToolMode() async {
        for (setting, expectsTransport) in [
            ("code_mode = \"code_mode_only\"", true),
            ("code_mode = true", true),
            ("code_mode = false", false)
        ] {
            let root = CodeModeFixtures.workspace()
            defer { try? FileManager.default.removeItem(at: root) }
            // A project layer under the cwd, not the user's own config file.
            let project = root.appendingPathComponent("project", isDirectory: true)
            let configDirectory = project.appendingPathComponent(".opengrok", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true
            )
            try? "[ui]\n\(setting)\n".write(
                to: configDirectory.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )

            let sampler = CodeModeSamplerFixture(script: [])
            let application = OpenGrokApplication.live(
                dependencies: OpenGrokLiveCompositionDependencies(
                    makeSampler: { _ in sampler.makeSampler() }
                ),
                control: .never
            )
            let (streams, _, _) = CLIStreams.buffered()
            _ = await CLIRunner.run(
                ["headless", "--prompt", "hello", "--cwd", project.path],
                environment: CodeModeFixtures.environment(root: root),
                streams: streams,
                application: application
            )

            let names = sampler.recordedRequests.first?.tools.map(\.name) ?? []
            #expect(names.contains("exec") == expectsTransport, "setting: \(setting)")
        }
    }

    // MARK: Nested dispatch

    @Test("a cell's nested read runs through the live tool pipeline")
    func nestedReadToolRunsThroughThePipeline() async {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try? "hello from disk\n".write(
            to: root.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        let sampler = CodeModeSamplerFixture(script: [
            CodeModeFixtures.exec(id: "exec-call-1", source: """
            const file = await tools.read_file({ target_file: "note.txt" });
            text(JSON.stringify(file));
            """)
        ])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let (streams, out, err) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["headless", "--prompt", "read the note", "--cwd", root.path],
            environment: CodeModeFixtures.environment(
                root: root,
                extra: ["OPENGROK_TOOL_MODE": "code_mode"]
            ),
            streams: streams,
            application: application
        )

        let execResult = sampler.result(for: "exec-call-1")
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        // The cell read the real file through the real file-tool pack.
        #expect(execResult?.contains("hello from disk") == true)
        #expect(out.contents.contains("hello from disk"))
        // `exec` is transport: it never announces itself the way a tool does.
        #expect(err.contents.contains("running tool exec") == false)
        #expect(err.contents.contains("running tool wait") == false)
    }

    @Test("nested calls raise tool cards while exec and wait raise none")
    func transportProjectionKeepsCellPlumbingOutOfFrames() async {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try? "hello from disk\n".write(
            to: root.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        let source = """
        const file = await tools.read_file({ target_file: "note.txt" });
        text(JSON.stringify(file));
        """
        let sampler = CodeModeSamplerFixture(script: [
            CodeModeFixtures.exec(id: "exec-call-1", source: source)
        ])
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() }
            ),
            control: .never
        )
        let (streams, out, _) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "read the note",
                "--cwd", root.path,
                "--output-format", "streaming-json"
            ],
            environment: CodeModeFixtures.environment(
                root: root,
                extra: ["OPENGROK_TOOL_MODE": "code_mode"]
            ),
            streams: streams,
            application: application
        )

        let records = out.contents.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        let toolRecords = records.filter { $0["type"] as? String == "tool" }
        let toolNames = Set(toolRecords.compactMap { $0["name"] as? String })

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        // The cards the UI shows are exactly the cell's nested calls.
        #expect(toolNames == ["read_file"])
        #expect(toolRecords.contains { $0["state"] as? String == "running" })
        #expect(toolRecords.contains { $0["state"] as? String == "succeeded" })
        // Under a synthetic per-cell call id, never the model's `exec` id.
        #expect(toolRecords.allSatisfy { ($0["call_id"] as? String)?.hasPrefix("exec-") == true })
        #expect(toolRecords.contains { ($0["call_id"] as? String) == "exec-call-1" } == false)
        // Raw JavaScript and the cell id are transport, and stay off the wire.
        #expect(out.contents.contains("tools.read_file") == false)
        #expect(out.contents.contains("Script running with cell ID") == false)
    }

    // MARK: Permissions

    /// Runs an interactive session whose cell writes a file, answering the
    /// permission sheet with a scripted key once it is painted.
    private func runNestedWriteSession(
        answer: [InputEvent]
    ) async -> (code: Int32, painted: String, cellResult: String?, wroteFile: Bool) {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("written.txt")

        let sampler = CodeModeSamplerFixture(script: [
            CodeModeFixtures.exec(id: "exec-write-1", source: """
            const result = await tools.write({
              file_path: "written.txt",
              content: "written by the cell\\n"
            });
            text(JSON.stringify(result));
            """)
        ])
        let terminal = CodeModeTerminalFixture()
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in CodeModeFixtures.typed("write the file")
                    + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                await CodeModeFixtures.waitForPaintedText("Allow write", terminal: terminal)
                for event in answer { continuation.yield(event) }
                // The second sampling round is the turn's own answer, i.e. the
                // cell finished and the model saw its result.
                await sampler.waitForRounds(2)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() },
                terminal: terminal.terminal,
                makeInteractiveInput: {
                    OpenGrokLiveInteractiveInput(events: input, close: {})
                },
                makeTerminalSink: { CodeModeTerminalSink(terminal: terminal) }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["interactive", "--cwd", root.path],
            environment: CodeModeFixtures.environment(
                root: root,
                extra: ["OPENGROK_TOOL_MODE": "code_mode"]
            ),
            streams: streams,
            application: application
        )
        return (
            code,
            terminal.paintedText,
            sampler.result(for: "exec-write-1"),
            FileManager.default.fileExists(atPath: target.path)
        )
    }

    @Test("a nested mutation raises the permission sheet and honors Yes")
    func nestedMutationPromptsAndAllows() async {
        // Option 2 is "Yes" — a one-shot allow.
        let outcome = await runNestedWriteSession(
            answer: [.key(KeyEvent(key: .char("2"), character: "2"))]
        )
        #expect(outcome.code == CLIRunner.ExitCode.success.rawValue)
        // The nested write went through the same gate a direct write does.
        #expect(outcome.painted.contains("Allow write"))
        #expect(outcome.wroteFile == true)
        #expect(outcome.cellResult?.contains("OPENGROK_ALLOW_WRITES") != true)
    }

    @Test("a nested mutation the user denies fails inside the cell")
    func nestedMutationPromptsAndDenies() async {
        // Option 3 is "No, and tell Grok what to do differently".
        let outcome = await runNestedWriteSession(
            answer: [.key(KeyEvent(key: .char("3"), character: "3"))]
        )
        #expect(outcome.code == CLIRunner.ExitCode.success.rawValue)
        #expect(outcome.painted.contains("Allow write"))
        #expect(outcome.wroteFile == false)
        // The refusal reaches the JavaScript as a rejection, not a silent
        // success, and the cell's error text carries it back to the model.
        #expect(outcome.cellResult?.contains("denied") == true)
    }

    // MARK: Cancellation

    @Test("cancelling the turn terminates the running cell instead of waiting")
    func turnCancelTerminatesRunningCell() async {
        let root = CodeModeFixtures.workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // The cell yields quickly and then parks forever; the model's `wait`
        // asks for a 60 s window, so a turn that does not terminate the cell
        // on Esc cannot return for a minute.
        let sampler = CodeModeSamplerFixture { round, lastResult in
            switch round {
            case 0:
                return CodeModeFixtures.exec(id: "exec-park-1", source: """
                // @exec: {"yield_time_ms": 250}
                text("cell parked");
                await new Promise(() => {});
                """)
            default:
                // Quote the cell id the transport just reported back.
                return CodeModeFixtures.wait(
                    id: "wait-\(round)",
                    cellIDFrom: lastResult ?? "",
                    yieldTimeMs: 60_000
                )
            }
        }
        let terminal = CodeModeTerminalFixture()
        let cancelledAt = CodeModeInstantBox()
        let input = AsyncThrowingStream<InputEvent, Error> { continuation in
            Task {
                for event in CodeModeFixtures.typed("park a cell")
                    + [.key(KeyEvent(key: .enter))] {
                    continuation.yield(event)
                }
                // Esc once the turn is genuinely in flight.
                await CodeModeFixtures.waitForPaintedText("park a cell", terminal: terminal)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                cancelledAt.mark()
                continuation.yield(.key(KeyEvent(key: .escape)))
                try? await Task.sleep(nanoseconds: 500_000_000)
                continuation.yield(.key(KeyEvent(
                    key: .char("d"),
                    modifiers: .control,
                    character: "d"
                )))
                continuation.finish()
            }
        }
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in sampler.makeSampler() },
                terminal: terminal.terminal,
                makeInteractiveInput: {
                    OpenGrokLiveInteractiveInput(events: input, close: {})
                },
                makeTerminalSink: { CodeModeTerminalSink(terminal: terminal) }
            ),
            control: .never
        )
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["interactive", "--cwd", root.path],
            environment: CodeModeFixtures.environment(
                root: root,
                extra: ["OPENGROK_TOOL_MODE": "code_mode"]
            ),
            streams: streams,
            application: application
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        // The parked cell held a JavaScriptCore thread; teardown returning at
        // all is the assertion that terminate does not wait for it.
        let elapsed = cancelledAt.elapsed()
        #expect(elapsed != nil)
        #expect((elapsed ?? .infinity) < 30, "cancel took \(elapsed ?? -1)s")
    }
#endif
}

/// Records when Esc was sent so the test can bound how long teardown took.
private final class CodeModeInstantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date?

    func mark() {
        lock.lock()
        instant = Date()
        lock.unlock()
    }

    func elapsed() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return instant.map { Date().timeIntervalSince($0) }
    }
}
