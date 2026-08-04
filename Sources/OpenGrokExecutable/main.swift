import Foundation
import OpenGrokCLI

let args = Array(CommandLine.arguments.dropFirst())
let exitCode = await CLIRunner.run(
    args,
    streams: CLIStreams.standard,
    application: OpenGrokExecutableComposition.application()
)
exit(exitCode)
