import Foundation
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
        streams: CLIStreams
    ) -> Int32 {
        let command = CLICommandParser.parse(args)
        switch command {
        case .version(let json):
            writeVersion(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .help:
            streams.out(OpenGrokHelp.text)
            return ExitCode.success.rawValue
        case .paths(let json):
            writePaths(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .models(let options):
            writeModels(options: options, streams: streams)
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
        application: OpenGrokApplication = .unavailable
    ) async -> Int32 {
        let command = CLICommandParser.parse(args)
        switch command {
        case .version(let json):
            writeVersion(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .help:
            streams.out(OpenGrokHelp.text)
            return ExitCode.success.rawValue
        case .paths(let json):
            writePaths(json: json, environment: environment, streams: streams)
            return ExitCode.success.rawValue
        case .models(let options):
            writeModels(options: options, streams: streams)
            return ExitCode.success.rawValue
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
        let version = OpenGrokCLIVersion.installed(environment: environment)
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

    private static func writeModels(options: CLIModelsOptions, streams: CLIStreams) {
        let catalog = embeddedDefaultModels()
        let visibleModels = catalog.models.filter { !$0.hidden && $0.supportedInApi }.map(\.model)
        switch options.action {
        case .default:
            if options.json {
                writeJSON(DefaultModelOutput(model: catalog.default), streams: streams)
            } else {
                streams.out("\(catalog.default)\n")
            }
        case .list:
            if options.json {
                writeJSON(ModelsOutput(defaultModel: catalog.default, models: visibleModels), streams: streams)
            } else {
                streams.out("Default: \(catalog.default)\n")
                for model in visibleModels {
                    streams.out("\(model)\n")
                }
            }
        }
    }

    private static func writeUnsupported(_ command: CLICommand, streams: CLIStreams) {
        streams.err("open-grok: route '\(command.routeName)' is recognized but unavailable in this Swift composition.\n")
        streams.err("No success path is installed for this capability.\n")
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
