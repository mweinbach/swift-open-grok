import Foundation
import OpenGrokAuth
import OpenGrokModels

public enum CLIRunner {
    public enum ExitCode: Int32, Sendable {
        case success = 0
        case failure = 1
        case usage = 2
        case notImplemented = 3
        case cancelled = 130
    }

    @discardableResult
    public static func main(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        streams: CLIStreams,
        releaseValidationDependencies: LiveReleaseValidationDependencies = .live
    ) -> Int32 {
        let command = CLICommandParser.parse(args, environment: environment)
        switch command {
        case .version(let json):
            writeVersion(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .help(let topic):
            return writeHelp(topic: topic, streams: streams)
        case .completions(let shell):
            streams.out(OpenGrokCompletions.script(shell: shell))
            return ExitCode.success.rawValue
        case .paths(let json):
            writePaths(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .releaseValidate(let options):
            return LiveReleaseValidation.run(
                options: options,
                environment: environment,
                streams: streams,
                dependencies: releaseValidationDependencies
            )
        case .models(let options):
            writeModels(options: options, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .mcp(let options):
            // `LiveMCPComposition.run` is synchronous, so the `mcp` route needs
            // nothing from the async application seam and no longer has to
            // report itself unsupported on this path.
            do {
                try LiveMCPComposition.run(
                    options: options, environment: environment, streams: streams
                )
                return ExitCode.success.rawValue
            } catch let error as CLIApplicationError {
                streams.err("open-grok: \(error.description).\n")
                return error.isUnsupported
                    ? ExitCode.notImplemented.rawValue
                    : ExitCode.failure.rawValue
            } catch {
                streams.err("open-grok: \(error).\n")
                return ExitCode.failure.rawValue
            }
        // `sessions list|show|delete` reads and writes the session directory
        // synchronously, so like `mcp` it needs nothing from the async
        // application seam. The `where` clause is load-bearing: `new`,
        // `resume`, `restore` and `export` belong to the launch path, so they
        // must keep falling through to the fail-closed default rather than
        // being silently accepted here.
        case .sessions(let options) where LiveSessionsComposition.actions.contains(options.action):
            do {
                try LiveSessionsComposition.run(
                    options: options, environment: environment, streams: streams
                )
                return ExitCode.success.rawValue
            } catch let error as CLIApplicationError {
                streams.err("open-grok: \(error.description).\n")
                return error.isUnsupported
                    ? ExitCode.notImplemented.rawValue
                    : ExitCode.failure.rawValue
            } catch {
                streams.err("open-grok: \(error).\n")
                return ExitCode.failure.rawValue
            }
        case .utility(let options) where options.name == "worktree":
            do {
                try LiveWorktreeComposition.run(
                    options: options, environment: environment, streams: streams
                )
                return ExitCode.success.rawValue
            } catch let error as CLIApplicationError {
                streams.err("open-grok: \(error.description).\n")
                return error.isUnsupported
                    ? ExitCode.notImplemented.rawValue
                    : ExitCode.failure.rawValue
            } catch {
                streams.err("open-grok: \(error).\n")
                return ExitCode.failure.rawValue
            }
        // `doctor` is synchronous end to end (standalone probes + managed
        // config writes), so like `mcp` and `sessions` it runs without the
        // async application seam.
        case .doctor(let options):
            return LiveDoctorComposition.run(
                options: options, environment: environment, streams: streams
            )
        case .invalid(let error):
            writeUsageError(error, streams: streams)
            return ExitCode.usage.rawValue
        default:
            writeUnsupported(command, streams: streams)
            return ExitCode.notImplemented.rawValue
        }
    }

    @discardableResult
    public static func run(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        streams: CLIStreams,
        application: OpenGrokApplication = .unavailable,
        releaseValidationDependencies: LiveReleaseValidationDependencies = .live
    ) async -> Int32 {
        let command = CLICommandParser.parse(args, environment: environment)
        if let refusal = LiveVersionPolicyGate.refusal(
            for: command,
            environment: environment
        ) {
            streams.err(refusal + "\n")
            return ExitCode.failure.rawValue
        }
        switch command {
        case .version(let json):
            writeVersion(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .help(let topic):
            return writeHelp(topic: topic, streams: streams)
        case .completions(let shell):
            streams.out(OpenGrokCompletions.script(shell: shell))
            return ExitCode.success.rawValue
        case .paths(let json):
            writePaths(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .releaseValidate(let options):
            return LiveReleaseValidation.run(
                options: options,
                environment: environment,
                streams: streams,
                dependencies: releaseValidationDependencies
            )
        case .models(let options):
            writeModels(options: options, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        // Synchronous like the arms above; the live binary reaches `doctor`
        // through this entry point (`OpenGrokExecutable/main.swift`).
        case .doctor(let options):
            return LiveDoctorComposition.run(
                options: options, environment: environment, streams: streams
            )
        case .invalid(let error):
            writeUsageError(error, streams: streams)
            return ExitCode.usage.rawValue
        default:
            do {
                try await application.run(command: command, environment: environment, streams: streams)
                return ExitCode.success.rawValue
            } catch is CancellationError {
                streams.err("open-grok: operation cancelled.\n")
                return ExitCode.cancelled.rawValue
            } catch let error as CLIApplicationError {
                streams.err("open-grok: \(error.description).\n")
                return error.isUnsupported ? ExitCode.notImplemented.rawValue : ExitCode.failure.rawValue
            } catch {
                streams.err("open-grok: \(error).\n")
                return ExitCode.failure.rawValue
            }
        }
    }

    private static func writeVersion(json: Bool, environment: [String: String], streams: CLIStreams) {
        let version = OpenGrokCLIVersion.installedWithCommit(environment: environment)
        if json {
            writeJSON(VersionOutput(version: version), streams: streams)
        } else {
            streams.out("Open Grok \(version)\n")
        }
    }

    private static func writePaths(json: Bool, environment: [String: String], streams: CLIStreams) {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let managed = OpenGrokHomeResolver.managedBinaryURL(environment: environment)
        let output = PathsOutput(
            opengrokHome: home.path,
            managedBinary: managed.path,
            projectState: ".opengrok"
        )
        if json {
            writeJSON(output, streams: streams)
        } else {
            streams.out("OPENGROK_HOME: \(output.opengrokHome)\n")
            streams.out("managed binary: \(output.managedBinary)\n")
            streams.out("project state: \(output.projectState)\n")
        }
    }

    private static func writeModels(
        options: CLIModelsOptions,
        environment: [String: String],
        streams: CLIStreams
    ) {
        let embedded = embeddedDefaultModels()
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let workingDirectory = URL(
            fileURLWithPath: environment["PWD"] ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: false
        )
        var input = liveCatalogResolutionInput(
            workingDirectory: workingDirectory,
            environment: environment
        )
        input.models.default = security.document[path: ["models", "default"]]?.stringValue
        input.models.openRouterEnabledModels = security.document[
            path: ["models", "openrouter_enabled_models"]
        ]?.arrayValue?.compactMap(\.stringValue) ?? []
        input.configModels = parseConfiguredModelCatalog(
            from: security.document,
            environment: environment
        ).modelOverrides
        for (key, override) in (try? loadCustomModelOverrides(grokHome: home)) ?? [] {
            if let index = input.configModels.firstIndex(where: { $0.0 == key }) {
                input.configModels[index] = (key, override)
            } else {
                input.configModels.append((key, override))
            }
        }

        let store = LiveModelCatalogStore(
            input: input,
            environment: environment,
            openGrokHome: home
        )
        let runInfraBaseURL = RunInfraModels.apiBaseURL(environment: environment)
        let runInfraKey = RunInfraModels.selectAPIKey(
            baseURL: runInfraBaseURL,
            environmentKey: runInfraAPIKeyFromEnvironment(environment),
            storedKey: readRunInfraAPIKey(grokHome: home)
        )
        let runInfraPublished: Bool
        if let runInfraKey {
            runInfraPublished = store.applyRunInfraCatalog(RunInfraModelsCatalog(
                entries: RunInfraModels.curatedCatalog(baseURL: runInfraBaseURL),
                credentialFingerprint: RunInfraModels.credentialFingerprint(apiKey: runInfraKey)
            ))
        } else {
            runInfraPublished = false
        }

        let geminiBaseURL = GeminiModels.apiBaseURL(environment: environment)
        let geminiKey = GeminiModels.selectAPIKey(
            baseURL: geminiBaseURL,
            environmentKey: geminiAPIKeyFromEnvironment(environment),
            storedKey: readGeminiAPIKey(grokHome: home)
        )
        let geminiPublished: Bool
        if let geminiKey {
            geminiPublished = store.applyGeminiCatalog(GeminiModelsCatalog(
                entries: GeminiModels.curatedCatalog(baseURL: geminiBaseURL),
                credentialFingerprint: GeminiModels.credentialFingerprint(apiKey: geminiKey)
            ))
        } else {
            geminiPublished = false
        }

        let openRouterKey = OpenRouterModels.selectAPIKey(
            baseURL: OpenRouterModels.apiBaseURL(environment: environment),
            environmentKey: openRouterAPIKeyFromEnvironment(environment),
            storedKey: readOpenRouterAPIKey(grokHome: home)
        )
        let openRouterAllowlist = Set(input.models.openRouterEnabledModels)
        var snapshot = store.snapshot()
        snapshot.retain { key, entry in
            switch entry.info.provider {
            case .runinfra:
                return runInfraPublished
            case .gemini:
                return geminiPublished
            case .openRouter:
                return openRouterKey != nil
                    && (openRouterAllowlist.contains(key)
                        || openRouterAllowlist.contains(entry.model))
            default:
                return true
            }
        }

        var visibleModels = embedded.models
            .filter { !$0.hidden && $0.supportedInApi }
            .map(\.model)
        var seen = Set(visibleModels)
        for (key, entry) in snapshot.pairs() {
            guard entry.info.provider == .runinfra
                || entry.info.provider == .gemini
                || entry.info.provider == .openRouter,
                !entry.info.hidden,
                entry.info.supportedInApi,
                entry.info.userSelectable,
                seen.insert(key).inserted
            else { continue }
            visibleModels.append(key)
        }

        let resolvedDefault = resolveDefaultModel(
            input: input,
            catalog: snapshot,
            hasXaiSession: false,
            hasCodexSession: false,
            environment: environment
        )
        let defaultModel: String
        if seen.contains(resolvedDefault.catalogKey) {
            defaultModel = resolvedDefault.catalogKey
        } else if seen.contains(resolvedDefault.entry.model) {
            defaultModel = resolvedDefault.entry.model
        } else {
            defaultModel = embedded.default
        }
        switch options.action {
        case .default:
            if options.json {
                writeJSON(DefaultModelOutput(model: defaultModel), streams: streams)
            } else {
                streams.out("\(defaultModel)\n")
            }
        case .list:
            if options.json {
                writeJSON(ModelsOutput(defaultModel: defaultModel, models: visibleModels), streams: streams)
            } else {
                streams.out("Default: \(defaultModel)\n")
                for model in visibleModels {
                    streams.out("\(model)\n")
                }
            }
        }
    }

    private static func writeHelp(topic: String?, streams: CLIStreams) -> Int32 {
        guard let topic else {
            streams.out(OpenGrokHelp.text)
            return ExitCode.success.rawValue
        }
        if let text = OpenGrokHelp.topic(topic) {
            streams.out(text)
            return ExitCode.success.rawValue
        }
        // Silently printing the top-level blob for an unrecognized topic is
        // what the old behavior did, and it hides typos. Upstream errors here.
        streams.err("open-grok: no help topic named '\(topic)'.\n")
        streams.err("Topics: \(OpenGrokHelp.topics.joined(separator: ", ")).\n")
        return ExitCode.usage.rawValue
    }

    /// Why a recognized route has no implementation, and what to do instead.
    ///
    /// A route that parses and then refuses is only defensible if the refusal
    /// says which capability is missing; otherwise it reads as a bug. Keyed by
    /// route name so the parser stays the single source of truth for spelling.
    private static func unavailableDetail(for command: CLICommand) -> String {
        switch command {
        case .inspect:
            return "Configuration discovery is not wired up yet. "
                + "'open-grok paths' reports the resolved state directories today."
        case .plugin(let options):
            if LivePluginComposition.actions.contains(options.action) {
                return "The live plugin action '\(options.action)' requires the live application composition."
            }
            return "Plugin action '\(options.action)' is not implemented in this build."
        case .utility(let options):
            switch options.name {
            case "wrap":
                return "PTY wrapping with OSC 52 clipboard forwarding is not "
                    + "implemented; run the command directly instead."
            case "export":
                return "Transcript export is not implemented; "
                    + "'open-grok sessions show <ID>' prints the transcript."
            case "trace":
                return "Trace export and upload are not implemented."
            case "setup":
                return "Managed configuration fetch and install are not implemented."
            case "share":
                return "Session sharing is fail-closed in the synchronous runner; the live route refuses before upload because signed-URL and backend share clients are not ported."
            case "memory":
                return "Cross-session memory management is not implemented."
            case "dashboard":
                return "The agent dashboard is not implemented."
            default:
                return "No success path is installed for this capability."
            }
        case .sessions(let options):
            return "'sessions \(options.action.rawValue)' is not installed; "
                + "'list', 'show' and 'delete' are."
        default:
            return "No success path is installed for this capability."
        }
    }

    private static func writeUnsupported(_ command: CLICommand, streams: CLIStreams) {
        streams.err("open-grok: route '\(command.routeName)' is recognized but unavailable in this Swift composition.\n")
        streams.err("\(unavailableDetail(for: command))\n")
    }

    private static func writeUsageError(_ error: CLIParseError, streams: CLIStreams) {
        streams.err("open-grok: \(error.description).\n")
        streams.err("Run 'open-grok help' for usage.\n")
    }

    private static func writeJSON<T: Encodable>(_ value: T, streams: CLIStreams) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            streams.out(String(decoding: data, as: UTF8.self) + "\n")
        } catch {
            streams.err("open-grok: failed to encode output: \(error).\n")
        }
    }
}

private extension CLIApplicationError {
    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

private struct VersionOutput: Encodable {
    let version: String
}

private struct PathsOutput: Encodable {
    let opengrokHome: String
    let managedBinary: String
    let projectState: String

    enum CodingKeys: String, CodingKey {
        case opengrokHome = "opengrok_home"
        case managedBinary = "managed_binary"
        case projectState = "project_state"
    }
}

private struct DefaultModelOutput: Encodable {
    let model: String
}

private struct ModelsOutput: Encodable {
    let defaultModel: String
    let models: [String]

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default"
        case models
    }
}
