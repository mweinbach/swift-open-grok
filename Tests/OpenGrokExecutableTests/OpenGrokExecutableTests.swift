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

@Suite("OpenGrokExecutable composition")
struct OpenGrokExecutableTests {
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
