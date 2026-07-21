// OpenGrokExecutable — the `open-grok` executable product (W11-S1 composition).
//
// Bootstrap composition wires the OpenGrokCLI runner to stdout/stderr. The
// final W11-S1 composition wires OpenGrokCLI to OpenGrokPager /
// OpenGrokPagerMinimal / OpenGrokShell for interactive, minimal, headless, and
// ACP modes; those targets are stubbed until their owning slices land, and the
// dependency edges are already predeclared in Package.swift.

import Foundation
import OpenGrokCLI

let args = Array(CommandLine.arguments.dropFirst())
let exitCode = CLIRunner.main(args, streams: CLIStreams.standard)
exit(exitCode)
