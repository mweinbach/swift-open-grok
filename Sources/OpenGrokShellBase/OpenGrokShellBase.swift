import Foundation

public enum ShellKind: String, Codable, Sendable, Equatable, Hashable {
    case bash
    case zsh
    case sh
    case powerShell
    case cmd

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellKind {
        #if os(Windows)
        let configured = environment["GROK_SHELL"] ?? environment["SHELL"] ?? ""
        let name = shellExecutableName(configured)
        if name.contains("cmd") {
            return .cmd
        }
        if name.contains("zsh") {
            return .zsh
        }
        if name == "sh" || name == "sh.exe" || name == "dash" || name == "dash.exe" {
            return .sh
        }
        if name.contains("bash") {
            return .bash
        }
        return .powerShell
        #else
        let name = shellExecutableName(environment["GROK_SHELL"] ?? environment["SHELL"] ?? "")
        if name.contains("zsh") {
            return .zsh
        }
        if name == "sh" || name == "dash" {
            return .sh
        }
        return .bash
        #endif
    }

    public var dialect: ShellDialect {
        switch self {
        case .bash, .zsh, .sh:
            return .posix
        case .powerShell:
            return .powerShell
        case .cmd:
            return .cmd
        }
    }

    public var binaryName: String {
        switch self {
        case .bash:
            return "bash"
        case .zsh:
            return "zsh"
        case .sh:
            return "sh"
        case .powerShell:
            #if os(Windows)
            return "powershell.exe"
            #else
            return "pwsh"
            #endif
        case .cmd:
            return "cmd.exe"
        }
    }

    public var fallbackBinaryPath: String {
        switch self {
        case .bash:
            return "/bin/bash"
        case .zsh:
            return "/bin/zsh"
        case .sh:
            return "/bin/sh"
        case .powerShell:
            #if os(Windows)
            return "powershell.exe"
            #else
            return "pwsh"
            #endif
        case .cmd:
            return "cmd.exe"
        }
    }

    public var rcFileName: String? {
        switch self {
        case .bash:
            return ".bashrc"
        case .zsh:
            return ".zshrc"
        case .sh, .powerShell, .cmd:
            return nil
        }
    }

    public func binaryPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let configured = [environment["GROK_SHELL"], environment["SHELL"]].compactMap { $0 }
        if let match = configured.first(where: { matchesConfiguredPath($0) && isExecutableFile(URL(fileURLWithPath: $0)) }) {
            return match
        }
        if let pathMatch = which(binaryName, environment: environment) {
            return pathMatch
        }
        for directory in Self.commonShellDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(binaryName)
            if isExecutableFile(candidate) {
                return candidate.path
            }
        }
        return fallbackBinaryPath
    }

    private func matchesConfiguredPath(_ path: String) -> Bool {
        let name = shellExecutableName(path)
        switch self {
        case .bash:
            return name == "bash"
        case .zsh:
            return name == "zsh"
        case .sh:
            return name == "sh" || name == "dash"
        case .powerShell:
            return name == "pwsh" || name == "powershell" || name == "powershell.exe"
        case .cmd:
            return name == "cmd" || name == "cmd.exe"
        }
    }

    #if os(Windows)
    private static let commonShellDirectories: [String] = []
    #else
    private static let commonShellDirectories = [
        "/bin",
        "/usr/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin"
    ]
    #endif
}

public enum ShellDialect: String, Codable, Sendable, Equatable, Hashable {
    case posix
    case powerShell
    case cmd
    case direct
}

public enum ShellQuoting {
    public static func posix(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func powerShell(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    public static func cmd(_ value: String) -> String {
        if value.isEmpty {
            return "\"\""
        }
        let metacharacters = "&|<>^()"
        let needsQuotes = value.contains { $0.isWhitespace || metacharacters.contains($0) || $0 == "\"" }
        guard needsQuotes else {
            return value
        }

        var result = "\""
        var backslashes = 0
        for character in value {
            if character == "\\" {
                backslashes += 1
                continue
            }
            if character == "\"" {
                result += String(repeating: "\\", count: backslashes * 2 + 1)
                result.append(character)
                backslashes = 0
                continue
            }
            if backslashes > 0 {
                result += String(repeating: "\\", count: backslashes)
                backslashes = 0
            }
            result.append(character)
        }
        if backslashes > 0 {
            result += String(repeating: "\\", count: backslashes * 2)
        }
        result.append("\"")
        return result
    }

    public static func quote(_ value: String, dialect: ShellDialect) -> String {
        switch dialect {
        case .posix, .direct:
            return posix(value)
        case .powerShell:
            return powerShell(value)
        case .cmd:
            return cmd(value)
        }
    }

    public static func commandLine(program: String, arguments: [String], dialect: ShellDialect) -> String {
        ([program] + arguments).map { quote($0, dialect: dialect) }.joined(separator: " ")
    }
}

public struct ShellCommand: Codable, Sendable, Equatable, Hashable {
    public let program: String?
    public let arguments: [String]
    public let script: String?
    public let dialect: ShellDialect

    public init(script: String, dialect: ShellDialect = .posix) {
        self.program = nil
        self.arguments = []
        self.script = script
        self.dialect = dialect
    }

    public init(program: String, arguments: [String] = [], dialect: ShellDialect = .direct) {
        self.program = program
        self.arguments = arguments
        self.script = nil
        self.dialect = dialect
    }

    public var isScript: Bool {
        script != nil
    }

    public var rendered: String {
        if let script {
            return script
        }
        guard let program else {
            return ""
        }
        return ShellQuoting.commandLine(program: program, arguments: arguments, dialect: dialect)
    }
}

public enum ShellEnvironmentInheritance: String, Codable, Sendable, Equatable, Hashable {
    case core
    case all
    case none
}

public struct ShellEnvironmentPolicy: Codable, Sendable, Equatable {
    public var inherit: ShellEnvironmentInheritance
    public var ignoreDefaultExcludes: Bool
    public var exclude: [String]
    public var set: [String: String]
    public var includeOnly: [String]

    public init(
        inherit: ShellEnvironmentInheritance = .all,
        ignoreDefaultExcludes: Bool = true,
        exclude: [String] = [],
        set: [String: String] = [:],
        includeOnly: [String] = []
    ) {
        self.inherit = inherit
        self.ignoreDefaultExcludes = ignoreDefaultExcludes
        self.exclude = exclude
        self.set = set
        self.includeOnly = includeOnly
    }

    public static let `default` = ShellEnvironmentPolicy()

    public var isNoop: Bool {
        inherit == .all && ignoreDefaultExcludes && exclude.isEmpty && set.isEmpty && includeOnly.isEmpty
    }

    public func allows(_ name: String) -> Bool {
        if !ignoreDefaultExcludes && Self.defaultSecretExcludes.contains(where: { shellGlobMatches($0, name) }) {
            return false
        }
        if exclude.contains(where: { shellGlobMatches($0, name) }) {
            return false
        }
        return includeOnly.isEmpty || includeOnly.contains(where: { shellGlobMatches($0, name) })
    }

    public func allowsInherited(_ name: String) -> Bool {
        switch inherit {
        case .none:
            return false
        case .core:
            guard Self.coreEnvironmentNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                return false
            }
        case .all:
            break
        }
        return allows(name)
    }

    public func baseEnvironment(from environment: [String: String]) -> [String: String] {
        var result: [String: String]
        switch inherit {
        case .all:
            result = environment
        case .core:
            result = environment.filter { key, _ in
                Self.coreEnvironmentNames.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame })
            }
        case .none:
            result = [:]
        }
        result = result.filter { allows($0.key) }
        for (key, value) in set where allows(key) {
            result[key] = value
        }
        return result
    }

    private static let defaultSecretExcludes = ["*KEY*", "*SECRET*", "*TOKEN*"]

    #if os(Windows)
    private static let coreEnvironmentNames = [
        "PATH", "PATHEXT", "SHELL", "COMSPEC", "SYSTEMROOT", "SYSTEMDRIVE", "USERNAME",
        "USERDOMAIN", "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "PROGRAMFILES", "PROGRAMFILES(X86)",
        "PROGRAMW6432", "PROGRAMDATA", "LOCALAPPDATA", "APPDATA", "TEMP", "TMP", "TMPDIR", "POWERSHELL", "PWSH"
    ]
    #else
    private static let coreEnvironmentNames = [
        "PATH", "SHELL", "TMPDIR", "TEMP", "TMP", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "USER"
    ]
    #endif
}

public let GROK_AGENT_ENV = "GROK_AGENT"
public let GROK_AGENT_ENV_VALUE = "1"

public func shellEnvOverrides() -> [String: String] {
    [
        "TERM": "dumb",
        "NO_COLOR": "1",
        "FORCE_COLOR": "0",
        GROK_AGENT_ENV: GROK_AGENT_ENV_VALUE
    ]
}

public func pagerEnvironment() -> [String: String] {
    [
        "PAGER": "cat",
        "GIT_PAGER": "cat",
        "SYSTEMD_PAGER": "cat",
        "GH_PAGER": "cat",
        "PSQL_PAGER": "cat",
        "MANPAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0",
        "LESS": "-FRX"
    ]
}

public func colorEnvironment() -> [String: String] {
    [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "FORCE_COLOR": "1",
        "CLICOLOR_FORCE": "1",
        "CLICOLOR": "1",
        "CARGO_TERM_PROGRESS_WHEN": "always",
        "CARGO_TERM_PROGRESS_WIDTH": "80",
        "CI": "true",
        "NPM_CONFIG_PROGRESS": "true",
        "PIP_PROGRESS_BAR": "on",
        "GRADLE_OPTS": "-Dorg.gradle.console=rich",
        "MAVEN_OPTS": "-Dstyle.color=always"
    ]
}

public func noColorEnvironment() -> [String: String] {
    [
        "NO_COLOR": "1",
        "TERM": "dumb",
        "FORCE_COLOR": "0",
        "CLICOLOR_FORCE": "0",
        "CLICOLOR": "0",
        "CARGO_TERM_COLOR": "never",
        "NPM_CONFIG_COLOR": "false",
        "PIP_NO_COLOR": "1",
        "PIP_PROGRESS_BAR": "off",
        "GRADLE_OPTS": "-Dorg.gradle.console=plain",
        "MAVEN_OPTS": "-Dstyle.color=never"
    ]
}

public enum ShellEnvironmentBuilder {
    public static func make(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        request: [String: String] = [:],
        policy: ShellEnvironmentPolicy = .default,
        overrides: [String: String] = shellEnvOverrides()
    ) -> [String: String] {
        var result = policy.baseEnvironment(from: inherited)
        for (key, value) in request where policy.allows(key) {
            result[key] = value
        }
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }

    public static func terminal(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        request: [String: String] = [:],
        policy: ShellEnvironmentPolicy = .default,
        color: Bool = false
    ) -> [String: String] {
        var overrides = color ? colorEnvironment() : noColorEnvironment()
        overrides.merge(pagerEnvironment()) { _, new in new }
        overrides.merge(shellEnvOverrides()) { _, new in new }
        return make(inherited: inherited, request: request, policy: policy, overrides: overrides)
    }
}

public enum ShellWorkingDirectoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPath(String)
    case notDirectory(String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            return "Invalid working directory path: \(path)"
        case let .notDirectory(path):
            return "Working directory is not a directory: \(path)"
        }
    }
}

public enum ShellWorkingDirectory {
    public static func resolve(requested: String?, relativeTo base: URL) throws -> URL {
        guard let requested, !requested.isEmpty else {
            return base.standardizedFileURL
        }
        guard !requested.utf8.contains(0) else {
            throw ShellWorkingDirectoryError.invalidPath(requested)
        }

        let expanded: String
        if requested == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if requested.hasPrefix("~/") || requested.hasPrefix("~\\") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(requested.dropFirst(2)))
                .path
        } else {
            expanded = requested
        }

        if isAbsolutePath(expanded) {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    public static func resolve(requested: URL?, relativeTo base: URL) throws -> URL {
        guard let requested else {
            return base.standardizedFileURL
        }
        return try resolve(requested: requested.path, relativeTo: base)
    }

    public static func validate(_ directory: URL, fileManager: FileManager = .default) throws -> URL {
        guard !directory.path.utf8.contains(0) else {
            throw ShellWorkingDirectoryError.invalidPath(directory.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw ShellWorkingDirectoryError.invalidPath(directory.path)
        }
        guard isDirectory.boolValue else {
            throw ShellWorkingDirectoryError.notDirectory(directory.path)
        }
        return directory.standardizedFileURL
    }
}

public struct PreparedShellCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let displayCommand: String

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        displayCommand: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.displayCommand = displayCommand
    }
}

public enum ShellCommandPreparation {
    public static func prepare(
        command: String,
        shell: ShellKind = .detect(),
        requestedWorkingDirectory: String? = nil,
        baseWorkingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        requestEnvironment: [String: String] = [:],
        environmentPolicy: ShellEnvironmentPolicy = .default,
        validateWorkingDirectory: Bool = false,
        terminalColor: Bool = false
    ) throws -> PreparedShellCommand {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShellError.invalidCommand
        }
        var workingDirectory = try ShellWorkingDirectory.resolve(
            requested: requestedWorkingDirectory,
            relativeTo: baseWorkingDirectory
        )
        if validateWorkingDirectory {
            workingDirectory = try ShellWorkingDirectory.validate(workingDirectory)
        }
        let environment = ShellEnvironmentBuilder.terminal(
            inherited: inheritedEnvironment,
            request: requestEnvironment,
            policy: environmentPolicy,
            color: terminalColor
        )
        return PreparedShellCommand(
            executable: shell.binaryPath(environment: inheritedEnvironment),
            arguments: shellArguments(for: shell, command: command),
            environment: environment,
            workingDirectory: workingDirectory,
            displayCommand: command
        )
    }

    public static func prepare(
        request: ShellCommandRequest,
        baseWorkingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        validateWorkingDirectory: Bool = false,
        terminalColor: Bool = false
    ) throws -> PreparedShellCommand {
        let requested = request.workingDirectory.path
        var workingDirectory = try ShellWorkingDirectory.resolve(requested: requested, relativeTo: baseWorkingDirectory)
        if validateWorkingDirectory {
            workingDirectory = try ShellWorkingDirectory.validate(workingDirectory)
        }
        guard !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShellError.invalidCommand
        }
        let environment = ShellEnvironmentBuilder.terminal(
            inherited: inheritedEnvironment,
            request: request.environment,
            policy: request.environmentPolicy,
            color: terminalColor
        )
        return PreparedShellCommand(
            executable: request.shell.binaryPath(environment: inheritedEnvironment),
            arguments: shellArguments(for: request.shell, command: request.command),
            environment: environment,
            workingDirectory: workingDirectory,
            displayCommand: request.displayCommand ?? request.command
        )
    }

    private static func shellArguments(for shell: ShellKind, command: String) -> [String] {
        switch shell.dialect {
        case .posix:
            return ["-lc", command]
        case .powerShell:
            return ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]
        case .cmd:
            return ["/D", "/S", "/C", command]
        case .direct:
            return [command]
        }
    }
}

public enum ShellIOErrorKind: String, Codable, Sendable, Equatable, Hashable {
    case permissionDenied
    case notFound
    case invalidArgument
    case notDirectory
    case alreadyExists
    case interrupted
    case other
}

public enum ShellCapability: String, Codable, Sendable, Equatable, Hashable {
    case processExecution
    case environmentOverrides
    case workingDirectory
    case outputStreaming
    case gracefulTermination
    case forcefulTermination
    case processGroups
    case persistentShellState
    case pseudoTerminal
}

public enum ShellError: Error, Sendable, Equatable, CustomStringConvertible {
    case io(message: String, kind: ShellIOErrorKind?)
    case invalidCommand
    case commandNotQuoted
    case unsupported(capability: ShellCapability, platform: String)
    case cancelled
    case timedOut
    case invalidRequest(String)

    public static func io(_ message: String) -> ShellError {
        .io(message: message, kind: nil)
    }

    public static func ioWithKind(_ message: String, _ kind: ShellIOErrorKind) -> ShellError {
        .io(message: message, kind: kind)
    }

    public var ioErrorKind: ShellIOErrorKind? {
        if case let .io(_, kind) = self {
            return kind
        }
        return nil
    }

    public var description: String {
        switch self {
        case let .io(message, _):
            return "IO Error: \(message)"
        case .invalidCommand:
            return "Command is empty"
        case .commandNotQuoted:
            return "Command could not be quoted"
        case let .unsupported(capability, platform):
            return "Unsupported capability \(capability.rawValue) on \(platform)"
        case .cancelled:
            return "Command cancelled"
        case .timedOut:
            return "Command timed out"
        case let .invalidRequest(message):
            return message
        }
    }
}

public enum ShellTaskKind: String, Codable, Sendable, Equatable, Hashable {
    case bash
    case monitor
}

public struct ShellDuration: Sendable, Equatable, Hashable, Comparable {
    public var timeInterval: TimeInterval

    public init(timeInterval: TimeInterval) {
        self.timeInterval = timeInterval
    }

    public static let zero = ShellDuration(timeInterval: 0)

    public static func seconds(_ value: TimeInterval) -> ShellDuration {
        ShellDuration(timeInterval: value)
    }

    public static func seconds(_ value: Int) -> ShellDuration {
        ShellDuration(timeInterval: TimeInterval(value))
    }

    public static func seconds(_ value: Int64) -> ShellDuration {
        ShellDuration(timeInterval: TimeInterval(value))
    }

    public static func milliseconds(_ value: TimeInterval) -> ShellDuration {
        ShellDuration(timeInterval: value / 1_000)
    }

    public static func milliseconds(_ value: Int) -> ShellDuration {
        ShellDuration(timeInterval: TimeInterval(value) / 1_000)
    }

    public static func milliseconds(_ value: Int64) -> ShellDuration {
        ShellDuration(timeInterval: TimeInterval(value) / 1_000)
    }

    public static func < (lhs: ShellDuration, rhs: ShellDuration) -> Bool {
        lhs.timeInterval < rhs.timeInterval
    }
}

public struct ShellCommandRequest: Sendable, Equatable {
    public var command: String
    public var workingDirectory: URL
    public var environment: [String: String]
    public var timeout: ShellDuration
    public var outputByteLimit: Int
    public var outputFile: URL?
    public var toolCallID: String?
    public var displayCommand: String?
    public var autoBackgroundOnTimeout: Bool
    public var foregroundBlockBudget: ShellDuration?
    public var kind: ShellTaskKind
    public var ownerSessionID: String?
    public var description: String?
    public var shell: ShellKind
    public var environmentPolicy: ShellEnvironmentPolicy
    public var stream: Bool

    public init(
        command: String,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = [:],
        timeout: ShellDuration = .seconds(30),
        outputByteLimit: Int = 30_000,
        outputFile: URL? = nil,
        toolCallID: String? = nil,
        displayCommand: String? = nil,
        autoBackgroundOnTimeout: Bool = false,
        foregroundBlockBudget: ShellDuration? = nil,
        kind: ShellTaskKind = .bash,
        ownerSessionID: String? = nil,
        description: String? = nil,
        shell: ShellKind = .detect(),
        environmentPolicy: ShellEnvironmentPolicy = .default,
        stream: Bool = true
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.outputByteLimit = max(0, outputByteLimit)
        self.outputFile = outputFile
        self.toolCallID = toolCallID
        self.displayCommand = displayCommand
        self.autoBackgroundOnTimeout = autoBackgroundOnTimeout
        self.foregroundBlockBudget = foregroundBlockBudget
        self.kind = kind
        self.ownerSessionID = ownerSessionID
        self.description = description
        self.shell = shell
        self.environmentPolicy = environmentPolicy
        self.stream = stream
    }

    public func validate() throws {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShellError.invalidCommand
        }
        guard timeout >= .zero else {
            throw ShellError.invalidRequest("timeout must not be negative")
        }
        guard !workingDirectory.path.utf8.contains(0) else {
            throw ShellError.invalidRequest("working directory contains a NUL byte")
        }
    }
}

public struct ShellBackgroundHandle: Sendable, Equatable {
    public let taskID: String
    public let outputFile: URL?
    public let processID: Int32?

    public init(taskID: String, outputFile: URL? = nil, processID: Int32? = nil) {
        self.taskID = taskID
        self.outputFile = outputFile
        self.processID = processID
    }
}

public enum ShellTerminationReason: Sendable, Equatable, Hashable {
    case cancellation
    case timeout
    case backgrounded
    case signal(ShellSignal)
}

public struct ShellCommandResult: Sendable, Equatable {
    public var combinedOutput: String
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32?
    public var signal: String?
    public var truncated: Bool
    public var timedOut: Bool
    public var cancelled: Bool
    public var backgrounded: Bool
    public var outputFile: URL?
    public var totalBytes: Int
    public var processID: Int32?
    public var taskID: String?
    public var startedAt: Date
    public var endedAt: Date
    public var terminationReason: ShellTerminationReason?

    public init(
        combinedOutput: String,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32? = nil,
        signal: String? = nil,
        truncated: Bool = false,
        timedOut: Bool = false,
        cancelled: Bool = false,
        backgrounded: Bool = false,
        outputFile: URL? = nil,
        totalBytes: Int? = nil,
        processID: Int32? = nil,
        taskID: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date = Date(),
        terminationReason: ShellTerminationReason? = nil
    ) {
        self.combinedOutput = combinedOutput
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.signal = signal
        self.truncated = truncated
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.backgrounded = backgrounded
        self.outputFile = outputFile
        self.totalBytes = totalBytes ?? combinedOutput.utf8.count
        self.processID = processID
        self.taskID = taskID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.terminationReason = terminationReason
    }
}

public enum ShellOutputChannel: String, Codable, Sendable, Equatable, Hashable {
    case stdout
    case stderr
}

public enum ShellProcessState: String, Codable, Sendable, Equatable, Hashable {
    case starting
    case running
    case backgrounded
    case completed
    case cancelled
    case timedOut
    case failed
}

public enum ShellOutputEvent: Sendable, Equatable {
    case started(taskID: String, processID: Int32?, timestamp: Date)
    case output(taskID: String, channel: ShellOutputChannel, data: Data, sequence: UInt64)
    case stateChanged(taskID: String, state: ShellProcessState)
    case completed(taskID: String, result: ShellCommandResult)
}

public enum ShellStopCause: Sendable, Equatable {
    case cancellation
    case timeout
    case backgrounded
    case signal(ShellSignal)
}

public enum ShellSignal: String, Codable, Sendable, Equatable, Hashable {
    case interrupt
    case terminate
    case kill
    case hangup

    public var portableValue: Int32 {
        switch self {
        case .interrupt:
            return 2
        case .terminate:
            return 15
        case .kill:
            return 9
        case .hangup:
            return 1
        }
    }

    public var displayName: String {
        switch self {
        case .interrupt:
            return "SIGINT"
        case .terminate:
            return "SIGTERM"
        case .kill:
            return "SIGKILL"
        case .hangup:
            return "SIGHUP"
        }
    }
}

public enum ShellTimeoutBehavior: String, Codable, Sendable, Equatable, Hashable {
    case terminate
    case background
}

public enum ShellResultMapping {
    public static func applying(
        _ cause: ShellStopCause,
        to result: ShellCommandResult,
        endedAt: Date = Date()
    ) -> ShellCommandResult {
        var mapped = result
        mapped.exitCode = nil
        mapped.endedAt = endedAt
        switch cause {
        case .cancellation:
            mapped.cancelled = true
            mapped.timedOut = false
            mapped.backgrounded = false
            mapped.signal = ShellSignal.terminate.displayName
            mapped.terminationReason = .cancellation
        case .timeout:
            mapped.cancelled = false
            mapped.timedOut = true
            mapped.backgrounded = false
            mapped.signal = ShellSignal.terminate.displayName
            mapped.terminationReason = .timeout
        case .backgrounded:
            mapped.cancelled = false
            mapped.timedOut = false
            mapped.backgrounded = true
            mapped.signal = "backgrounded"
            mapped.terminationReason = .backgrounded
        case let .signal(signal):
            mapped.cancelled = false
            mapped.timedOut = false
            mapped.backgrounded = false
            mapped.signal = signal.displayName
            mapped.terminationReason = .signal(signal)
        }
        return mapped
    }

    public static func boundedOutput(_ data: Data, limit: Int) -> (data: Data, truncated: Bool) {
        guard limit >= 0, data.count > limit else {
            return (data, false)
        }
        guard limit > 0 else {
            return (Data(), true)
        }
        let bytes = Array(data)
        var start = bytes.count - limit
        while start < bytes.count, (bytes[start] & 0xC0) == 0x80 {
            start += 1
        }
        return (Data(bytes[start...]), true)
    }
}

public struct ShellOutputAccumulator: Sendable, Equatable {
    public let limit: Int
    public private(set) var combinedData: Data
    public private(set) var stdoutData: Data
    public private(set) var stderrData: Data
    public private(set) var totalBytes: Int
    public private(set) var truncated: Bool
    public private(set) var nextSequence: UInt64

    public init(limit: Int = 30_000) {
        self.limit = max(0, limit)
        self.combinedData = Data()
        self.stdoutData = Data()
        self.stderrData = Data()
        self.totalBytes = 0
        self.truncated = false
        self.nextSequence = 0
    }

    public mutating func append(_ data: Data, channel: ShellOutputChannel, taskID: String) -> ShellOutputEvent {
        totalBytes += data.count
        combinedData.append(data)
        let boundedCombined = ShellResultMapping.boundedOutput(combinedData, limit: limit)
        combinedData = boundedCombined.data
        truncated = truncated || boundedCombined.truncated

        switch channel {
        case .stdout:
            stdoutData.append(data)
            stdoutData = ShellResultMapping.boundedOutput(stdoutData, limit: limit).data
        case .stderr:
            stderrData.append(data)
            stderrData = ShellResultMapping.boundedOutput(stderrData, limit: limit).data
        }

        let event = ShellOutputEvent.output(taskID: taskID, channel: channel, data: data, sequence: nextSequence)
        nextSequence += 1
        return event
    }

    public func result(
        taskID: String? = nil,
        processID: Int32? = nil,
        outputFile: URL? = nil,
        exitCode: Int32? = nil,
        signal: String? = nil,
        timedOut: Bool = false,
        cancelled: Bool = false,
        backgrounded: Bool = false,
        startedAt: Date,
        endedAt: Date
    ) -> ShellCommandResult {
        ShellCommandResult(
            combinedOutput: String(decoding: combinedData, as: UTF8.self),
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: exitCode,
            signal: signal,
            truncated: truncated,
            timedOut: timedOut,
            cancelled: cancelled,
            backgrounded: backgrounded,
            outputFile: outputFile,
            totalBytes: totalBytes,
            processID: processID,
            taskID: taskID,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }
}

public struct ShellTaskSnapshot: Codable, Sendable, Equatable {
    public var taskID: String
    public var command: String
    public var displayCommand: String?
    public var cwd: URL
    public var startTime: Date
    public var endTime: Date?
    public var output: String
    public var outputFile: URL?
    public var truncated: Bool
    public var outputTotalBytes: Int
    public var exitCode: Int32?
    public var signal: String?
    public var completed: Bool
    public var kind: ShellTaskKind
    public var blockWaited: Bool
    public var explicitlyKilled: Bool
    public var ownerSessionID: String?
    public var description: String?
    public var isBackgrounded: Bool

    public init(
        taskID: String,
        command: String,
        displayCommand: String? = nil,
        cwd: URL,
        startTime: Date = Date(),
        endTime: Date? = nil,
        output: String = "",
        outputFile: URL? = nil,
        truncated: Bool = false,
        outputTotalBytes: Int = 0,
        exitCode: Int32? = nil,
        signal: String? = nil,
        completed: Bool = false,
        kind: ShellTaskKind = .bash,
        blockWaited: Bool = false,
        explicitlyKilled: Bool = false,
        ownerSessionID: String? = nil,
        description: String? = nil,
        isBackgrounded: Bool = false
    ) {
        self.taskID = taskID
        self.command = command
        self.displayCommand = displayCommand
        self.cwd = cwd
        self.startTime = startTime
        self.endTime = endTime
        self.output = output
        self.outputFile = outputFile
        self.truncated = truncated
        self.outputTotalBytes = outputTotalBytes
        self.exitCode = exitCode
        self.signal = signal
        self.completed = completed
        self.kind = kind
        self.blockWaited = blockWaited
        self.explicitlyKilled = explicitlyKilled
        self.ownerSessionID = ownerSessionID
        self.description = description
        self.isBackgrounded = isBackgrounded
    }

    public func duration(at date: Date = Date()) -> TimeInterval {
        max(0, (endTime ?? date).timeIntervalSince(startTime))
    }

    public var isOutstanding: Bool {
        !completed
    }

    public var isOutstandingBackground: Bool {
        !completed && isBackgrounded
    }
}

public enum ShellKillOutcome: String, Codable, Sendable, Equatable, Hashable {
    case killed
    case alreadyExited
    case notFound
}

public protocol ShellProcessHandle: Sendable {
    var taskID: String { get }
    var processID: Int32? { get }
    func output() -> AsyncThrowingStream<ShellOutputEvent, Error>
    func waitForCompletion(timeout: ShellDuration?) async -> ShellTaskSnapshot?
    func send(_ signal: ShellSignal) async throws
    func cancel() async
}

public protocol ShellProcessBackend: Sendable {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult
    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle
    func getTask(_ taskID: String) async -> ShellTaskSnapshot?
    func killTask(_ taskID: String) async -> ShellKillOutcome
    func killForegroundCommands() async
    func killForegroundCommands(ownerSessionID: String) async
    func killAllBackgroundTasks() async
    func killAllBackgroundTasks(ownerSessionID: String) async
    func warmShell(at cwd: URL) async
    func backgroundForegroundCommand(toolCallID: String) async -> Bool
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot?
    func listTasks() async -> [ShellTaskSnapshot]
    func shellCWD() async -> URL?
}

public protocol AsyncFileSystem: Sendable {
    func readFile(at url: URL) async throws -> Data
    func writeFile(_ data: Data, at url: URL) async throws
    func deleteFile(at url: URL) async throws
}

public enum ShellLifecycleTransitionError: Error, Sendable, Equatable, CustomStringConvertible {
    case taskNotFound(String)
    case taskAlreadyExists(String)
    case invalidOutputSequence(taskID: String, expected: UInt64, received: UInt64)
    case invalidTransition(taskID: String, from: ShellProcessState, to: ShellProcessState)

    public var description: String {
        switch self {
        case let .taskNotFound(taskID):
            return "Shell task not found: \(taskID)"
        case let .taskAlreadyExists(taskID):
            return "Shell task already exists: \(taskID)"
        case let .invalidOutputSequence(taskID, expected, received):
            return "Invalid shell output sequence \(taskID): expected \(expected), received \(received)"
        case let .invalidTransition(taskID, from, to):
            return "Invalid shell task transition \(taskID): \(from.rawValue) -> \(to.rawValue)"
        }
    }
}

public actor ShellProcessLifecycle {
    private struct Entry {
        var snapshot: ShellTaskSnapshot
        var state: ShellProcessState
        var events: [ShellOutputEvent]
        var continuations: [UUID: AsyncThrowingStream<ShellOutputEvent, Error>.Continuation]
        var outputData: Data
        var outputLimit: Int
        var nextSequence: UInt64
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register(
        request: ShellCommandRequest,
        taskID: String = UUID().uuidString,
        processID: Int32? = nil,
        startedAt: Date = Date()
    ) throws -> ShellTaskSnapshot {
        try request.validate()
        guard entries[taskID] == nil else {
            throw ShellLifecycleTransitionError.taskAlreadyExists(taskID)
        }
        let snapshot = ShellTaskSnapshot(
            taskID: taskID,
            command: request.command,
            displayCommand: request.displayCommand,
            cwd: request.workingDirectory,
            startTime: startedAt,
            outputFile: request.outputFile,
            kind: request.kind,
            ownerSessionID: request.ownerSessionID,
            description: request.description
        )
        let event = ShellOutputEvent.started(taskID: taskID, processID: processID, timestamp: startedAt)
        entries[taskID] = Entry(
            snapshot: snapshot,
            state: .starting,
            events: [event, .stateChanged(taskID: taskID, state: .starting)],
            continuations: [:],
            outputData: Data(),
            outputLimit: request.outputByteLimit,
            nextSequence: 0
        )
        return snapshot
    }

    public func handle(
        for taskID: String,
        processID: Int32? = nil,
        signalHandler: @escaping @Sendable (ShellSignal) async throws -> Void = { _ in
            throw ShellError.unsupported(capability: .gracefulTermination, platform: "unprovided")
        }
    ) throws -> ShellLifecycleProcessHandle {
        guard entries[taskID] != nil else {
            throw ShellLifecycleTransitionError.taskNotFound(taskID)
        }
        return ShellLifecycleProcessHandle(
            taskID: taskID,
            processID: processID,
            lifecycle: self,
            signalHandler: signalHandler
        )
    }

    public func transition(taskID: String, to state: ShellProcessState) throws {
        guard var entry = entries[taskID] else {
            throw ShellLifecycleTransitionError.taskNotFound(taskID)
        }
        guard canTransition(from: entry.state, to: state) else {
            throw ShellLifecycleTransitionError.invalidTransition(taskID: taskID, from: entry.state, to: state)
        }
        entry.state = state
        entry.events.append(.stateChanged(taskID: taskID, state: state))
        yield(.stateChanged(taskID: taskID, state: state), to: &entry)
        entries[taskID] = entry
    }

    public func appendOutput(taskID: String, channel: ShellOutputChannel, data: Data, sequence: UInt64) throws {
        guard var entry = entries[taskID] else {
            throw ShellLifecycleTransitionError.taskNotFound(taskID)
        }
        guard sequence == entry.nextSequence else {
            throw ShellLifecycleTransitionError.invalidOutputSequence(taskID: taskID, expected: entry.nextSequence, received: sequence)
        }
        let event = ShellOutputEvent.output(taskID: taskID, channel: channel, data: data, sequence: sequence)
        entry.events.append(event)
        yield(event, to: &entry)
        entry.snapshot.outputTotalBytes += data.count
        entry.outputData.append(data)
        let bounded = ShellResultMapping.boundedOutput(entry.outputData, limit: entry.outputLimit)
        entry.outputData = bounded.data
        entry.snapshot.output = String(decoding: bounded.data, as: UTF8.self)
        entry.snapshot.truncated = entry.snapshot.truncated || bounded.truncated
        entry.nextSequence += 1
        entries[taskID] = entry
    }

    public func markBackgrounded(taskID: String) throws {
        guard var entry = entries[taskID] else {
            throw ShellLifecycleTransitionError.taskNotFound(taskID)
        }
        guard canTransition(from: entry.state, to: .backgrounded) else {
            throw ShellLifecycleTransitionError.invalidTransition(taskID: taskID, from: entry.state, to: .backgrounded)
        }
        entry.state = .backgrounded
        entry.snapshot.isBackgrounded = true
        entry.events.append(.stateChanged(taskID: taskID, state: .backgrounded))
        yield(.stateChanged(taskID: taskID, state: .backgrounded), to: &entry)
        entries[taskID] = entry
    }

    public func complete(taskID: String, result: ShellCommandResult) throws {
        guard var entry = entries[taskID] else {
            throw ShellLifecycleTransitionError.taskNotFound(taskID)
        }
        let target: ShellProcessState = result.cancelled ? .cancelled : (result.timedOut ? .timedOut : (result.exitCode == 0 ? .completed : .failed))
        if entry.state != target {
            guard canTransition(from: entry.state, to: target) else {
                throw ShellLifecycleTransitionError.invalidTransition(taskID: taskID, from: entry.state, to: target)
            }
            entry.state = target
            entry.events.append(.stateChanged(taskID: taskID, state: target))
            yield(.stateChanged(taskID: taskID, state: target), to: &entry)
        }
        entry.snapshot.endTime = result.endedAt
        entry.snapshot.output = result.combinedOutput
        entry.snapshot.outputTotalBytes = result.totalBytes
        entry.snapshot.truncated = result.truncated
        entry.snapshot.exitCode = result.exitCode
        entry.snapshot.signal = result.signal
        entry.snapshot.completed = true
        entry.snapshot.isBackgrounded = result.backgrounded
        let event = ShellOutputEvent.completed(taskID: taskID, result: result)
        entry.events.append(event)
        yield(event, to: &entry)
        for continuation in entry.continuations.values {
            continuation.finish()
        }
        entry.continuations.removeAll()
        entries[taskID] = entry
    }

    public func snapshot(taskID: String) -> ShellTaskSnapshot? {
        entries[taskID]?.snapshot
    }

    public func list() -> [ShellTaskSnapshot] {
        entries.values.map(\.snapshot).sorted { $0.startTime < $1.startTime }
    }

    public nonisolated func outputStream(taskID: String) -> AsyncThrowingStream<ShellOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.attach(continuation, taskID: taskID) }
        }
    }

    public func waitForCompletion(taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        guard entries[taskID] != nil else {
            return nil
        }
        let deadline = timeout.map { Date().addingTimeInterval($0.timeInterval) }
        while let entry = entries[taskID], !entry.snapshot.completed {
            if let deadline, Date() >= deadline {
                break
            }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                break
            }
        }
        return entries[taskID]?.snapshot
    }

    private func attach(
        _ continuation: AsyncThrowingStream<ShellOutputEvent, Error>.Continuation,
        taskID: String
    ) {
        guard var entry = entries[taskID] else {
            continuation.finish(throwing: ShellLifecycleTransitionError.taskNotFound(taskID))
            return
        }
        for event in entry.events {
            continuation.yield(event)
        }
        if entry.snapshot.completed {
            continuation.finish()
        } else {
            entry.continuations[UUID()] = continuation
            entries[taskID] = entry
        }
    }

    private func yield(
        _ event: ShellOutputEvent,
        to entry: inout Entry
    ) {
        for continuation in entry.continuations.values {
            continuation.yield(event)
        }
    }

    private func canTransition(from: ShellProcessState, to: ShellProcessState) -> Bool {
        switch (from, to) {
        case (.starting, .running), (.starting, .backgrounded), (.starting, .cancelled), (.starting, .timedOut), (.starting, .failed), (.starting, .completed):
            return true
        case (.running, .backgrounded), (.running, .cancelled), (.running, .timedOut), (.running, .failed), (.running, .completed):
            return true
        case (.backgrounded, .cancelled), (.backgrounded, .timedOut), (.backgrounded, .failed), (.backgrounded, .completed):
            return true
        default:
            return false
        }
    }
}

public struct ShellLifecycleProcessHandle: ShellProcessHandle, Sendable {
    public let taskID: String
    public let processID: Int32?
    private let lifecycle: ShellProcessLifecycle
    private let signalHandler: @Sendable (ShellSignal) async throws -> Void

    public init(
        taskID: String,
        processID: Int32?,
        lifecycle: ShellProcessLifecycle,
        signalHandler: @escaping @Sendable (ShellSignal) async throws -> Void
    ) {
        self.taskID = taskID
        self.processID = processID
        self.lifecycle = lifecycle
        self.signalHandler = signalHandler
    }

    public func output() -> AsyncThrowingStream<ShellOutputEvent, Error> {
        lifecycle.outputStream(taskID: taskID)
    }

    public func waitForCompletion(timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        await lifecycle.waitForCompletion(taskID: taskID, timeout: timeout)
    }

    public func send(_ signal: ShellSignal) async throws {
        try await signalHandler(signal)
    }

    public func cancel() async {
        try? await signalHandler(.terminate)
    }
}

public struct ShellCapabilities: Codable, Sendable, Equatable {
    public let platform: String
    public let supported: Set<ShellCapability>

    public init(platform: String, supported: Set<ShellCapability>) {
        self.platform = platform
        self.supported = supported
    }

    public func supports(_ capability: ShellCapability) -> Bool {
        supported.contains(capability)
    }

    public func require(_ capability: ShellCapability) throws {
        guard supports(capability) else {
            throw UnsupportedShellCapabilityError(capability: capability, platform: platform)
        }
    }
}

public protocol ShellCapabilityProvider: Sendable {
    var capabilities: ShellCapabilities { get }
}

public struct FoundationShellCapabilities: ShellCapabilityProvider, Sendable, Equatable {
    public let capabilities: ShellCapabilities

    public init(capabilities: ShellCapabilities = FoundationShellCapabilities.currentCapabilities) {
        self.capabilities = capabilities
    }

    public static var currentCapabilities: ShellCapabilities {
        #if os(Windows)
        return ShellCapabilities(
            platform: "windows",
            supported: [.processExecution, .environmentOverrides, .workingDirectory, .outputStreaming, .gracefulTermination, .forcefulTermination]
        )
        #elseif os(macOS)
        return ShellCapabilities(
            platform: "macos",
            supported: [.processExecution, .environmentOverrides, .workingDirectory, .outputStreaming, .gracefulTermination, .forcefulTermination, .processGroups]
        )
        #else
        return ShellCapabilities(
            platform: "unix",
            supported: [.processExecution, .environmentOverrides, .workingDirectory, .outputStreaming, .gracefulTermination, .forcefulTermination, .processGroups]
        )
        #endif
    }
}

public struct UnsupportedShellCapabilityError: Error, Sendable, Equatable, CustomStringConvertible {
    public let capability: ShellCapability
    public let platform: String

    public init(capability: ShellCapability, platform: String) {
        self.capability = capability
        self.platform = platform
    }

    public var description: String {
        "Unsupported capability \(capability.rawValue) on \(platform)"
    }
}

public protocol ShellPlatformAdapter: ShellCapabilityProvider {
    func isProcessAlive(_ processID: Int32) async -> Bool
    func terminate(_ signal: ShellSignal, processID: Int32) async throws
}

public typealias ComputerError = ShellError
public typealias TerminalRunRequest = ShellCommandRequest
public typealias TerminalRunResult = ShellCommandResult
public typealias BackgroundHandle = ShellBackgroundHandle
public typealias TaskSnapshot = ShellTaskSnapshot
public typealias TaskKind = ShellTaskKind
public typealias KillOutcome = ShellKillOutcome
public typealias TerminalBackend = ShellProcessBackend

private func shellExecutableName(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init)
        .map { $0.lowercased() }
        ?? ""
}

private func isAbsolutePath(_ path: String) -> Bool {
    if path.hasPrefix("/") || path.hasPrefix("\\") {
        return true
    }
    guard path.count >= 3 else {
        return false
    }
    let characters = Array(path)
    return characters[1] == ":" && (characters[2] == "/" || characters[2] == "\\")
}

private func isExecutableFile(_ url: URL) -> Bool {
    #if os(Windows)
    FileManager.default.fileExists(atPath: url.path)
    #else
    FileManager.default.isExecutableFile(atPath: url.path)
    #endif
}

private func which(_ name: String, environment: [String: String]) -> String? {
    #if os(Windows)
    let pathValue = environment["PATH"] ?? environment["Path"] ?? ""
    let separator: Character = ";"
    let pathExt = environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD"
    let extensions = pathExt.split(separator: ";").map(String.init)
    let hasKnownExtension = extensions.contains {
        name.lowercased().hasSuffix($0.lowercased())
    }
    let suffixes = hasKnownExtension ? [""] : extensions
    #else
    let pathValue = environment["PATH"] ?? ""
    let separator: Character = ":"
    let suffixes = [""]
    #endif
    for directory in pathValue.split(separator: separator, omittingEmptySubsequences: false) {
        for suffix in suffixes {
            #if os(Windows)
            let candidate = (String(directory) as NSString).appendingPathComponent(name + suffix)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            #else
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name + suffix)
            if isExecutableFile(candidate) {
                return candidate.path
            }
            #endif
        }
    }
    return nil
}

private func shellGlobMatches(_ pattern: String, _ value: String) -> Bool {
    let pattern = Array(pattern.lowercased())
    let value = Array(value.lowercased())
    var patternIndex = 0
    var valueIndex = 0
    var starIndex: Int?
    var retryValueIndex = 0

    while valueIndex < value.count {
        if patternIndex < pattern.count && (pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex]) {
            patternIndex += 1
            valueIndex += 1
        } else if patternIndex < pattern.count && pattern[patternIndex] == "*" {
            starIndex = patternIndex
            retryValueIndex = valueIndex
            patternIndex += 1
        } else if let starIndex {
            patternIndex = starIndex + 1
            retryValueIndex += 1
            valueIndex = retryValueIndex
        } else {
            return false
        }
    }

    while patternIndex < pattern.count && pattern[patternIndex] == "*" {
        patternIndex += 1
    }
    return patternIndex == pattern.count
}
