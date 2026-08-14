// OpenGrokVersionBuildPlugin.swift
//
// Build-tool plugin that generates `CompiledVersion.generated.swift` from
// the `GROK_VERSION` environment variable at build time — the SwiftPM
// equivalent of the Rust crate's `option_env!("GROK_VERSION")` compile-time
// injection and `cargo:rerun-if-env-changed=GROK_VERSION` directive.
//
// Resolution order (matches the Rust reference + the Open Grok release
// script):
//   1. `GROK_VERSION` environment variable, if set and non-empty.
//   2. The first line of `OPEN_GROK_VERSION` at the package root, if present.
//   3. The canonical Open Grok release string `0.1.220-open-grok.58`.
//
// The plugin runs during SwiftPM's build planning phase. It determines the
// version string and invokes a declared Swift generator executable to write
// the source file to the plugin work directory. SwiftPM compiles the generated
// file as part of the `OpenGrokVersion` target.

import Foundation
import PackagePlugin

@main
struct OpenGrokVersionBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let outputFile = context.pluginWorkDirectoryURL.appendingPathComponent("CompiledVersion.generated.swift")

        // Resolve the version string (same resolution order as the Rust
        // crate and `regenerate-compiled-version.sh`).
        let env = ProcessInfo.processInfo.environment
        let defaultVersion = "1.0.0-open-grok.62"

        let version: String
        if let grokVersion = env["GROK_VERSION"], !grokVersion.isEmpty {
            version = grokVersion
        } else {
            let versionFilePath = context.package.directoryURL
                .appendingPathComponent("OPEN_GROK_VERSION")
                .path
            if FileManager.default.fileExists(atPath: versionFilePath) {
                let content = (try? String(contentsOfFile: versionFilePath, encoding: .utf8))?
                    .components(separatedBy: "\n").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                version = content.isEmpty ? defaultVersion : content
            } else {
                version = defaultVersion
            }
        }

        // Validate the version is non-empty.
        guard !version.isEmpty else {
            throw NSError(
                domain: "OpenGrokVersionBuildPlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Resolved version is empty"]
            )
        }

        let shortCommit = env["GROK_COMMIT"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        let generator = try context.tool(named: "OpenGrokVersionGenerator")

        var arguments = [outputFile.path, version]
        if let shortCommit, !shortCommit.isEmpty {
            arguments.append(shortCommit)
        }

        return [
            .buildCommand(
                displayName: "Generate OpenGrokVersion from GROK_VERSION=\(version)",
                executable: generator.url,
                arguments: arguments,
                inputFiles: [],
                outputFiles: [outputFile]
            )
        ]
    }
}
