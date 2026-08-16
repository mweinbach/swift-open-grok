import Foundation
import OpenGrokCLI
import OpenGrokJavaScriptRuntime

#if canImport(Glibc)
import Glibc

// A write to a peer that has gone away must surface as EPIPE, not kill the
// process. SIGPIPE is fatal by default on Linux and ignored under Apple's
// runtime, so this is set here rather than left to whichever subsystem happens
// to initialize first — several of them install it today, which means the
// protection depended on load order. Cost: every write path must now check its
// own return value, which they already do.
_ = signal(SIGPIPE, SIG_IGN)
#endif

if let workerExitCode = await JavaScriptRuntimeWorkerMain.runIfRequested() {
    exit(workerExitCode)
}

if let captureExitCode = LiveVoiceMainIntercept.maybeRunCaptureSubprocess() {
    exit(Int32(captureExitCode))
}

let args = Array(CommandLine.arguments.dropFirst())
let exitCode = await CLIRunner.run(
    args,
    streams: CLIStreams.standard,
    application: OpenGrokExecutableComposition.application()
)
exit(exitCode)
