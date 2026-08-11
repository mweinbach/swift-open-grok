import Foundation
import OpenGrokCLI

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
