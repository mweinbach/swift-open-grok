import Foundation

public enum CLIParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case invalidValue(option: String, value: String, expected: String)
    case conflictingOptions(String, String)
    case missingSubcommand(String)

    public var description: String {
        switch self {
        case .unknownCommand(let command):
            return "unknown command '\(command)'"
        case .unknownOption(let option):
            return "unknown option '\(option)'"
        case .missingValue(let option):
            return "option '\(option)' requires a value"
        case .unexpectedArgument(let argument):
            return "unexpected argument '\(argument)'"
        case .invalidValue(let option, let value, let expected):
            return "invalid value '\(value)' for \(option); expected \(expected)"
        case .conflictingOptions(let first, let second):
            return "options \(first) and \(second) cannot be used together"
        case .missingSubcommand(let command):
            return "command '\(command)' requires a subcommand"
        }
    }
}

public enum CLIOutputFormat: String, Sendable, Equatable {
    case plain
    case json
    case streamingJSON = "streaming-json"
    case streamingMessagesJSON = "streaming-messages-json"
}

public enum CLIRunMode: String, Sendable, Equatable {
    case interactive
    case minimal
    case headless
    case acp
    case serve
    case leader
}

public struct CLICommonOptions: Sendable, Equatable {
    public var cwd: String?
    public var model: String?
    public var provider: String?
    public var profile: String?
    public var pluginDirectories: [String]
    public var mcpConfig: String?
    public var workflow: String?
    public var leader: Bool
    public var noLeader: Bool

    public init(
        cwd: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        profile: String? = nil,
        pluginDirectories: [String] = [],
        mcpConfig: String? = nil,
        workflow: String? = nil,
        leader: Bool = false,
        noLeader: Bool = false
    ) {
        self.cwd = cwd
        self.model = model
        self.provider = provider
        self.profile = profile
        self.pluginDirectories = pluginDirectories
        self.mcpConfig = mcpConfig
        self.workflow = workflow
        self.leader = leader
        self.noLeader = noLeader
    }
}

public struct CLIExecutionOptions: Sendable, Equatable {
    public var mode: CLIRunMode
    public var common: CLICommonOptions
    public var prompt: String?
    public var promptJSON: String?
    public var promptFile: String?
    public var outputFormat: CLIOutputFormat
    public var sessionID: String?
    public var resume: String?
    public var continueSession: Bool
    public var forkSession: Bool
    public var noAltScreen: Bool
    public var fullscreen: Bool

    public init(
        mode: CLIRunMode = .interactive,
        common: CLICommonOptions = CLICommonOptions(),
        prompt: String? = nil,
        promptJSON: String? = nil,
        promptFile: String? = nil,
        outputFormat: CLIOutputFormat = .plain,
        sessionID: String? = nil,
        resume: String? = nil,
        continueSession: Bool = false,
        forkSession: Bool = false,
        noAltScreen: Bool = false,
        fullscreen: Bool = false
    ) {
        self.mode = mode
        self.common = common
        self.prompt = prompt
        self.promptJSON = promptJSON
        self.promptFile = promptFile
        self.outputFormat = outputFormat
        self.sessionID = sessionID
        self.resume = resume
        self.continueSession = continueSession
        self.forkSession = forkSession
        self.noAltScreen = noAltScreen
        self.fullscreen = fullscreen
    }
}

public struct CLIServeOptions: Sendable, Equatable {
    public var common: CLICommonOptions
    public var bind: String
    public var secret: String?
    public var remote: String?
    public var grokWSOrigin: String?
    public var grokWSURL: String?

    public init(
        common: CLICommonOptions = CLICommonOptions(),
        bind: String = "127.0.0.1:2419",
        secret: String? = nil,
        remote: String? = nil,
        grokWSOrigin: String? = nil,
        grokWSURL: String? = nil
    ) {
        self.common = common
        self.bind = bind
        self.secret = secret
        self.remote = remote
        self.grokWSOrigin = grokWSOrigin
        self.grokWSURL = grokWSURL
    }
}

public struct CLILeaderOptions: Sendable, Equatable {
    public var common: CLICommonOptions
    public var noExitOnDisconnect: Bool
    public var relayOnDemand: Bool
    public var noAutoUpdate: Bool
    public var grokWSOrigin: String?
    public var grokWSURL: String?

    public init(
        common: CLICommonOptions = CLICommonOptions(),
        noExitOnDisconnect: Bool = false,
        relayOnDemand: Bool = false,
        noAutoUpdate: Bool = false,
        grokWSOrigin: String? = nil,
        grokWSURL: String? = nil
    ) {
        self.common = common
        self.noExitOnDisconnect = noExitOnDisconnect
        self.relayOnDemand = relayOnDemand
        self.noAutoUpdate = noAutoUpdate
        self.grokWSOrigin = grokWSOrigin
        self.grokWSURL = grokWSURL
    }
}

public enum CLISessionAction: String, Sendable, Equatable {
    case list
    case new
    case resume
    case restore
    case export
}

public struct CLISessionOptions: Sendable, Equatable {
    public var action: CLISessionAction
    public var identifier: String?
    public var output: String?
    public var json: Bool
    public var fork: Bool

    public init(
        action: CLISessionAction = .list,
        identifier: String? = nil,
        output: String? = nil,
        json: Bool = false,
        fork: Bool = false
    ) {
        self.action = action
        self.identifier = identifier
        self.output = output
        self.json = json
        self.fork = fork
    }
}

public enum CLIModelAction: String, Sendable, Equatable {
    case list
    case `default`
}

public struct CLIModelsOptions: Sendable, Equatable {
    public var action: CLIModelAction
    public var json: Bool

    public init(action: CLIModelAction = .list, json: Bool = false) {
        self.action = action
        self.json = json
    }
}

public struct CLIResourceOptions: Sendable, Equatable {
    public var action: String
    public var target: String?
    public var values: [String]
    public var options: [String: String]
    public var json: Bool
    public var force: Bool

    public init(
        action: String,
        target: String? = nil,
        values: [String] = [],
        options: [String: String] = [:],
        json: Bool = false,
        force: Bool = false
    ) {
        self.action = action
        self.target = target
        self.values = values
        self.options = options
        self.json = json
        self.force = force
    }
}

public struct CLIUtilityOptions: Sendable, Equatable {
    public var name: String
    public var values: [String]
    public var options: [String: String]
    public var json: Bool
    public var force: Bool

    public init(
        name: String,
        values: [String] = [],
        options: [String: String] = [:],
        json: Bool = false,
        force: Bool = false
    ) {
        self.name = name
        self.values = values
        self.options = options
        self.json = json
        self.force = force
    }
}

public enum CLICommand: Sendable, Equatable {
    case version(json: Bool)
    case help(topic: String?)
    case paths(json: Bool)
    case inspect(json: Bool)
    case doctor
    case completions(shell: String)
    case launch(CLIExecutionOptions)
    case serve(CLIServeOptions)
    case leader(CLILeaderOptions)
    case sessions(CLISessionOptions)
    case models(CLIModelsOptions)
    case plugin(CLIResourceOptions)
    case mcp(CLIResourceOptions)
    case workflow(CLIResourceOptions)
    case utility(CLIUtilityOptions)
    case invalid(CLIParseError)

    public var routeName: String {
        switch self {
        case .version: return "version"
        case .help: return "help"
        case .paths: return "paths"
        case .inspect: return "inspect"
        case .doctor: return "doctor"
        case .completions: return "completions"
        case .launch(let options): return options.mode.rawValue
        case .serve: return "serve"
        case .leader: return "leader"
        case .sessions: return "sessions"
        case .models: return "models"
        case .plugin: return "plugin"
        case .mcp: return "mcp"
        case .workflow: return "workflow"
        case .utility(let options): return options.name
        case .invalid: return "invalid"
        }
    }
}

public enum CLICommandParser {
    public static func parse(_ args: [String]) -> CLICommand {
        do {
            return try parseOrThrow(args)
        } catch let error as CLIParseError {
            return .invalid(error)
        } catch {
            return .invalid(.unexpectedArgument(String(describing: error)))
        }
    }

    public static func parseOrThrow(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else {
            return .launch(try parseLaunch([], mode: .interactive))
        }

        switch first {
        case "--version", "-v", "-V", "version":
            return .version(json: try parseJSONFlag(Array(args.dropFirst())))
        case "--help", "-h", "help":
            return .help(topic: try parseHelpTopic(Array(args.dropFirst())))
        case "paths", "path":
            return .paths(json: try parseJSONFlag(Array(args.dropFirst())))
        case "inspect":
            return .inspect(json: try parseJSONFlag(Array(args.dropFirst())))
        case "doctor":
            try requireNoArguments(Array(args.dropFirst()))
            return .doctor
        case "completions":
            return try parseCompletions(Array(args.dropFirst()))
        case "interactive":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .interactive))
        case "minimal":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .minimal))
        case "headless":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .headless))
        case "acp":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .acp))
        case "serve":
            return .serve(try parseServe(Array(args.dropFirst())))
        case "leader":
            return .leader(try parseLeader(Array(args.dropFirst())))
        case "agent":
            return try parseAgent(Array(args.dropFirst()))
        case "session", "sessions":
            return .sessions(try parseSessions(Array(args.dropFirst())))
        case "model", "models":
            return .models(try parseModels(Array(args.dropFirst())))
        case "plugin":
            return .plugin(try parseResource(Array(args.dropFirst()), command: "plugin"))
        case "mcp":
            return .mcp(try parseResource(Array(args.dropFirst()), command: "mcp"))
        case "workflow":
            return .workflow(try parseResource(Array(args.dropFirst()), command: "workflow"))
        case "login", "logout", "setup", "share", "wrap", "export", "trace", "update",
             "memory", "dashboard", "workspace", "worktree":
            return .utility(try parseUtility(Array(args.dropFirst()), name: first))
        default:
            throw CLIParseError.unknownCommand(first)
        }
    }

    private static func parseLaunch(_ args: [String], mode initialMode: CLIRunMode) throws -> CLIExecutionOptions {
        var cursor = ArgumentCursor(args)
        var common = CLICommonOptions()
        var mode = initialMode
        var prompt: String?
        var promptJSON: String?
        var promptFile: String?
        var outputFormat = CLIOutputFormat.plain
        var sessionID: String?
        var resume: String?
        var continueSession = false
        var forkSession = false
        var noAltScreen = false
        var fullscreen = false
        var positional: [String] = []

        while let token = cursor.pop() {
            if token == "--" {
                positional.append(contentsOf: cursor.remaining())
                break
            }
            guard let option = OptionToken(token) else {
                positional.append(token)
                continue
            }
            if try consumeCommon(option, cursor: &cursor, common: &common) { continue }
            switch option.name {
            case "--minimal":
                mode = .minimal
            case "--fullscreen":
                fullscreen = true
            case "--headless":
                mode = .headless
            case "--acp":
                mode = .acp
            case "--prompt", "-p":
                prompt = try cursor.value(for: option)
            case "--prompt-json":
                promptJSON = try cursor.value(for: option)
            case "--prompt-file":
                promptFile = try cursor.value(for: option)
            case "--output-format":
                let value = try cursor.value(for: option)
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(
                        option: option.name,
                        value: value,
                        expected: CLIOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")
                    )
                }
                outputFormat = parsed
            case "--session-id", "-s":
                sessionID = try cursor.value(for: option)
            case "--resume", "-r":
                resume = option.inlineValue ?? (cursor.peek?.hasPrefix("-") == true ? "" : cursor.pop())
            case "--continue", "-c":
                continueSession = true
            case "--fork-session":
                forkSession = true
            case "--no-alt-screen":
                noAltScreen = true
            case "--serve":
                mode = .serve
            case "--leader-mode":
                mode = .leader
            default:
                throw CLIParseError.unknownOption(option.name)
            }
        }

        if positional.count > 1 {
            throw CLIParseError.unexpectedArgument(positional[1])
        }
        if let value = positional.first {
            if mode == .headless {
                if prompt != nil { throw CLIParseError.conflictingOptions("PROMPT", "--prompt") }
                prompt = value
            } else if prompt == nil {
                prompt = value
            } else {
                throw CLIParseError.unexpectedArgument(value)
            }
        }
        if common.leader && common.noLeader {
            throw CLIParseError.conflictingOptions("--leader", "--no-leader")
        }
        if mode == .minimal && fullscreen {
            throw CLIParseError.conflictingOptions("--minimal", "--fullscreen")
        }
        let promptSources = [prompt != nil, promptJSON != nil, promptFile != nil].filter { $0 }.count
        if promptSources > 1 {
            throw CLIParseError.conflictingOptions("--prompt", "--prompt-json/--prompt-file")
        }
        if mode == .acp && promptSources > 0 {
            throw CLIParseError.conflictingOptions("ACP", "prompt source")
        }
        return CLIExecutionOptions(
            mode: mode,
            common: common,
            prompt: prompt,
            promptJSON: promptJSON,
            promptFile: promptFile,
            outputFormat: outputFormat,
            sessionID: sessionID,
            resume: resume,
            continueSession: continueSession,
            forkSession: forkSession,
            noAltScreen: noAltScreen,
            fullscreen: fullscreen
        )
    }

    private static func parseServe(_ args: [String]) throws -> CLIServeOptions {
        var cursor = ArgumentCursor(args)
        var common = CLICommonOptions()
        var bind = "127.0.0.1:2419"
        var secret: String?
        var remote: String?
        var origin: String?
        var url: String?
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else { throw CLIParseError.unexpectedArgument(token) }
            if try consumeCommon(option, cursor: &cursor, common: &common) { continue }
            switch option.name {
            case "--bind": bind = try cursor.value(for: option)
            case "--secret": secret = try cursor.value(for: option)
            case "--remote": remote = try cursor.value(for: option)
            case "--grok-ws-origin": origin = try cursor.value(for: option)
            case "--grok-ws-url": url = try cursor.value(for: option)
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        return CLIServeOptions(common: common, bind: bind, secret: secret, remote: remote, grokWSOrigin: origin, grokWSURL: url)
    }

    private static func parseLeader(_ args: [String]) throws -> CLILeaderOptions {
        var cursor = ArgumentCursor(args)
        var common = CLICommonOptions()
        var noExit = false
        var relay = false
        var noAutoUpdate = false
        var origin: String?
        var url: String?
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else { throw CLIParseError.unexpectedArgument(token) }
            if try consumeCommon(option, cursor: &cursor, common: &common) { continue }
            switch option.name {
            case "--no-exit-on-disconnect": noExit = true
            case "--relay-on-demand": relay = true
            case "--no-auto-update": noAutoUpdate = true
            case "--grok-ws-origin": origin = try cursor.value(for: option)
            case "--grok-ws-url": url = try cursor.value(for: option)
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        return CLILeaderOptions(common: common, noExitOnDisconnect: noExit, relayOnDemand: relay, noAutoUpdate: noAutoUpdate, grokWSOrigin: origin, grokWSURL: url)
    }

    private static func parseAgent(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else {
            return .launch(try parseLaunch([], mode: .interactive))
        }
        switch first {
        case "stdio", "acp":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .acp))
        case "headless":
            return .launch(try parseLaunch(Array(args.dropFirst()), mode: .headless))
        case "serve":
            return .serve(try parseServe(Array(args.dropFirst())))
        case "leader":
            return .leader(try parseLeader(Array(args.dropFirst())))
        default:
            return .launch(try parseLaunch(args, mode: .interactive))
        }
    }

    private static func parseSessions(_ args: [String]) throws -> CLISessionOptions {
        var cursor = ArgumentCursor(args)
        var action: CLISessionAction = .list
        var identifier: String?
        var output: String?
        var json = false
        var fork = false
        if let first = cursor.peek, !first.hasPrefix("-") {
            _ = cursor.pop()
            guard let parsed = CLISessionAction(rawValue: first) else { throw CLIParseError.unknownCommand(first) }
            action = parsed
        }
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else {
                if identifier == nil { identifier = token } else { throw CLIParseError.unexpectedArgument(token) }
                continue
            }
            switch option.name {
            case "--json": json = true
            case "--fork": fork = true
            case "--output", "-o": output = try cursor.value(for: option)
            case "--id", "--session-id": identifier = try cursor.value(for: option)
            default: throw CLIParseError.unknownOption(option.name)
            }
        }
        if action == .list && fork { throw CLIParseError.invalidValue(option: "--fork", value: "true", expected: "a resume or restore action") }
        return CLISessionOptions(action: action, identifier: identifier, output: output, json: json, fork: fork)
    }

    private static func parseModels(_ args: [String]) throws -> CLIModelsOptions {
        var cursor = ArgumentCursor(args)
        var action = CLIModelAction.list
        var json = false
        if let first = cursor.peek, !first.hasPrefix("-") {
            _ = cursor.pop()
            guard let parsed = CLIModelAction(rawValue: first) else { throw CLIParseError.unknownCommand(first) }
            action = parsed
        }
        while let token = cursor.pop() {
            guard let option = OptionToken(token), option.name == "--json" else {
                throw CLIParseError.unknownOption(token)
            }
            json = true
        }
        return CLIModelsOptions(action: action, json: json)
    }

    private static func parseResource(_ args: [String], command: String) throws -> CLIResourceOptions {
        var cursor = ArgumentCursor(args)
        guard let first = cursor.pop(), !first.hasPrefix("-") else { throw CLIParseError.missingSubcommand(command) }
        var target: String?
        var values: [String] = []
        var options: [String: String] = [:]
        var json = false
        var force = false
        while let token = cursor.pop() {
            guard let option = OptionToken(token) else {
                if target == nil { target = token } else { values.append(token) }
                continue
            }
            switch option.name {
            case "--json": json = true
            case "--force": force = true
            case "--source", "--url", "--command", "--transport", "--config", "--argument", "--output", "-o":
                options[option.name] = try cursor.value(for: option)
            default:
                throw CLIParseError.unknownOption(option.name)
            }
        }
        return CLIResourceOptions(action: first, target: target, values: values, options: options, json: json, force: force)
    }

    private static func parseUtility(_ args: [String], name: String) throws -> CLIUtilityOptions {
        var cursor = ArgumentCursor(args)
        var values: [String] = []
        var options: [String: String] = [:]
        var json = false
        var force = false
        while let token = cursor.pop() {
            if name == "wrap" {
                values.append(token)
                continue
            }
            guard let option = OptionToken(token) else {
                values.append(token)
                continue
            }
            switch option.name {
            case "--json": json = true
            case "--force", "--check":
                if option.name == "--force" { force = true } else { options[option.name] = "true" }
            case "--oauth", "--oidc", "--codex", "--device-auth", "--device-code", "--legacy":
                options[option.name] = "true"
            case "--version", "--output", "--shell", "--channel", "--session-id", "--id":
                options[option.name] = try cursor.value(for: option)
            default:
                throw CLIParseError.unknownOption(option.name)
            }
        }
        if name == "wrap" && values.isEmpty { throw CLIParseError.missingValue("wrap command") }
        return CLIUtilityOptions(name: name, values: values, options: options, json: json, force: force)
    }

    private static func parseCompletions(_ args: [String]) throws -> CLICommand {
        guard args.count == 1, let shell = args.first, !shell.hasPrefix("-") else {
            throw CLIParseError.invalidValue(option: "completions", value: args.joined(separator: " "), expected: "one shell name")
        }
        let supported = ["bash", "zsh", "fish", "powershell", "elvish"]
        guard supported.contains(shell.lowercased()) else {
            throw CLIParseError.invalidValue(option: "completions", value: shell, expected: supported.joined(separator: ", "))
        }
        return .completions(shell: shell.lowercased())
    }

    private static func consumeCommon(
        _ option: OptionToken,
        cursor: inout ArgumentCursor,
        common: inout CLICommonOptions
    ) throws -> Bool {
        switch option.name {
        case "--cwd": common.cwd = try cursor.value(for: option)
        case "--model", "-m": common.model = try cursor.value(for: option)
        case "--provider": common.provider = try cursor.value(for: option)
        case "--profile", "--agent-profile": common.profile = try cursor.value(for: option)
        case "--plugin-dir": common.pluginDirectories.append(try cursor.value(for: option))
        case "--mcp-config": common.mcpConfig = try cursor.value(for: option)
        case "--workflow": common.workflow = try cursor.value(for: option)
        case "--leader": common.leader = true
        case "--no-leader": common.noLeader = true
        default: return false
        }
        return true
    }

    private static func parseJSONFlag(_ args: [String]) throws -> Bool {
        guard args.count <= 1 else { throw CLIParseError.unexpectedArgument(args[1]) }
        guard let value = args.first else { return false }
        guard value == "--json" else { throw CLIParseError.unknownOption(value) }
        return true
    }

    private static func parseHelpTopic(_ args: [String]) throws -> String? {
        guard let first = args.first, !first.hasPrefix("-") else {
            if let first = args.first { throw CLIParseError.unknownOption(first) }
            return nil
        }
        if args.count > 1 { throw CLIParseError.unexpectedArgument(args[1]) }
        return first
    }

    private static func requireNoArguments(_ args: [String]) throws {
        if let first = args.first { throw CLIParseError.unexpectedArgument(first) }
    }
}

private struct OptionToken: Sendable, Equatable {
    var name: String
    var inlineValue: String?

    init?(_ token: String) {
        guard token.hasPrefix("-"), token != "-" else { return nil }
        if let separator = token.firstIndex(of: "=") {
            name = String(token[..<separator])
            inlineValue = String(token[token.index(after: separator)...])
        } else {
            name = token
            inlineValue = nil
        }
    }
}

private struct ArgumentCursor: Sendable {
    private var arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    var peek: String? {
        guard index < arguments.count else { return nil }
        return arguments[index]
    }

    mutating func pop() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func value(for option: OptionToken) throws -> String {
        if let inlineValue = option.inlineValue, !inlineValue.isEmpty { return inlineValue }
        guard let value = pop(), !value.isEmpty, !value.hasPrefix("-") else {
            throw CLIParseError.missingValue(option.name)
        }
        return value
    }

    mutating func remaining() -> [String] {
        let result = Array(arguments[index...])
        index = arguments.count
        return result
    }
}

private extension CLIOutputFormat {
    static var allCases: [CLIOutputFormat] {
        [.plain, .json, .streamingJSON, .streamingMessagesJSON]
    }
}
