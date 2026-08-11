// LiveAntigravity.swift
//
// Antigravity CLI (`agy`) subagent integration — presence probe, config
// reader, output classification, and the injectable services seam.
//
// Rust reference at pin 650c1db7:
//   * `crates/codegen/xai-grok-shell/src/agent/antigravity.rs`
//   * `crates/codegen/xai-grok-shell/src/agent/subagent/antigravity_runner.rs`
//
// Deliberately absent this slice (recorded in the deliverable): log-tail
// phase heartbeats, Language-Server HTTP quota/models probe, `/usage`
// Antigravity section, `--conversation` resume, effort-suffix retries, and
// process-global probe TTL caches. Cost of skipping the caches: one
// ~1s `agy models` probe per antigravity spawn.

import Foundation
import OpenGrokConfig

// MARK: - Public capability surface (settings honesty)

/// Settings-row gate for Antigravity. Mirrors `LiveVoiceCapabilities`: rows
/// stay hidden unless the CLI is present (upstream
/// `setting_row_visible` / `ui_config.rs:89-91` at pin 650c1db7 — "the
/// settings row is hidden otherwise").
public struct LiveAntigravityCapabilities: Sendable, Equatable {
    public let cliInstalled: Bool

    public init(cliInstalled: Bool) {
        self.cliInstalled = cliInstalled
    }

    public var isAvailable: Bool { cliInstalled }

    public static let settingsKeys: [String] = [
        "antigravity_subagents",
        "antigravity_skip_permissions",
    ]

    public static func hiddenSettingsKeys(
        when capabilities: LiveAntigravityCapabilities
    ) -> Set<String> {
        capabilities.isAvailable ? [] : Set(settingsKeys)
    }
}

public enum LiveAntigravityComposition {
    /// Namespace prefix that marks a task/swarm/workflow `model` argument as
    /// an Antigravity model (`MODEL_PREFIX`, antigravity.rs:35).
    public static let modelPrefix = "antigravity:"

    /// Default binary name (`DEFAULT_BINARY`, antigravity.rs:41).
    public static let defaultBinary = "agy"

    /// `Some(model)` when `slug` is `antigravity:<model>` with a non-empty
    /// model (`strip_model_prefix`, antigravity.rs:55-59).
    public static func stripModelPrefix(_ slug: String) -> String? {
        guard slug.hasPrefix(modelPrefix) else { return nil }
        let rest = slug.dropFirst(modelPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : String(rest)
    }

    public static func isAntigravitySlug(_ slug: String) -> Bool {
        stripModelPrefix(slug) != nil
    }

    /// Config binary name + PATH/file presence (`cli_installed`,
    /// antigravity.rs:79-81). Cheap and synchronous — settings visibility
    /// must not spawn `agy models`.
    public static func resolveCapabilities(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LiveAntigravityCapabilities {
        let config = LiveAntigravityConfig.load(environment: environment)
        return LiveAntigravityCapabilities(
            cliInstalled: LiveAntigravityServices.productionIsCLIInstalled(
                config.binary,
                environment
            )
        )
    }
}

// MARK: - Config

/// `[ui].antigravity_subagents` + `[antigravity]` knobs via ConfigLayers →
/// effectiveConfigBase(), the `LiveUpdateComposition.cliAutoUpdateConfigValue`
/// pattern. Defaults match upstream: subagents off (`ui_enabled`,
/// antigravity.rs:84-86), skip_permissions on (`antigravity_runner.rs:259-263`),
/// binary `"agy"` (`binary_name`, antigravity.rs:67-75).
struct LiveAntigravityConfig: Sendable, Equatable {
    var enabled: Bool
    var binary: String
    var skipPermissions: Bool

    static func load(environment: [String: String]) -> LiveAntigravityConfig {
        let document = (try? ConfigLayers.load(environment: environment))?.effectiveConfigBase()
        let enabled: Bool
        if case .boolean(let value)? = document?[path: ["ui", "antigravity_subagents"]] {
            enabled = value
        } else {
            enabled = false
        }
        let binary: String
        if case .string(let raw)? = document?[path: ["antigravity", "binary"]] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            binary = trimmed.isEmpty ? LiveAntigravityComposition.defaultBinary : trimmed
        } else {
            binary = LiveAntigravityComposition.defaultBinary
        }
        let skipPermissions: Bool
        if case .boolean(let value)? = document?[path: ["antigravity", "skip_permissions"]] {
            skipPermissions = value
        } else {
            skipPermissions = true
        }
        return LiveAntigravityConfig(
            enabled: enabled,
            binary: binary,
            skipPermissions: skipPermissions
        )
    }
}

// MARK: - Probe status

/// Result of probing `agy models` (`AntigravityStatus`, antigravity.rs:89-97).
struct LiveAntigravityStatus: Sendable, Equatable {
    var signedIn: Bool
    /// Native model ids as reported by `agy models` (no `antigravity:` prefix).
    var models: [String]
    var detail: String?

    static func unavailable(_ detail: String) -> LiveAntigravityStatus {
        LiveAntigravityStatus(signedIn: false, models: [], detail: detail)
    }

    /// Roster as task-tool slugs (`prefixed_models`, antigravity.rs:110-118)
    /// without the reference-model reordering (out of scope this slice).
    var prefixedModels: [String] {
        models.map { LiveAntigravityComposition.modelPrefix + $0 }
    }

    /// Parse `agy models` output. Exit status is deliberately ignored: agy
    /// reports sign-in errors on stdout with exit code 0
    /// (`parse_models_output`, antigravity.rs:145-172).
    static func parse(stdout: String, stderr: String) -> LiveAntigravityStatus {
        let combined = stdout.splitAntigravityLines() + stderr.splitAntigravityLines()
        if let line = combined.first(where: {
            $0.hasPrefix("Error:") || $0.lowercased().contains("sign in")
        }) {
            return .unavailable(line)
        }
        let models = stdout.splitAntigravityLines().filter { line in
            !line.isEmpty && !line.contains(" ") && !line.hasPrefix("-")
        }
        if models.isEmpty {
            return LiveAntigravityStatus(
                signedIn: true,
                models: [],
                detail: "`agy models` reported no models"
            )
        }
        return LiveAntigravityStatus(signedIn: true, models: models, detail: nil)
    }
}

// MARK: - Run request / outcome

/// One `--print` invocation (`AgyRun`, antigravity.rs:434-453) minus
/// effort/conversation — those pairs are out of scope (effort needs the
/// retry-without-effort fallback; conversation needs resume metadata).
struct LiveAntigravityRun: Sendable {
    var binary: String
    var model: String
    var prompt: String
    var workspaceDirectory: URL
    var logFile: URL
    var timeout: TimeInterval
    var skipPermissions: Bool
}

enum LiveAntigravityRunOutcome: Sendable, Equatable {
    case success(output: String)
    case failure(String)
    case cancelled
}

// MARK: - Injectable services

/// Injection seam so tests drive spawn without a real `agy` binary.
struct LiveAntigravityServices: Sendable {
    var loadConfig: @Sendable ([String: String]) -> LiveAntigravityConfig
    var isCLIInstalled: @Sendable (_ binary: String, _ environment: [String: String]) -> Bool
    var probeModels: @Sendable (_ binary: String) async -> LiveAntigravityStatus
    var runPrint: @Sendable (LiveAntigravityRun) async -> LiveAntigravityRunOutcome

    static let production = LiveAntigravityServices(
        loadConfig: { LiveAntigravityConfig.load(environment: $0) },
        isCLIInstalled: { productionIsCLIInstalled($0, $1) },
        probeModels: { binary in
            await productionProbeModels(binary: binary)
        },
        runPrint: { run in
            await productionRunPrint(run)
        }
    )

    /// Absolute-path override uses a direct executable check; bare names go
    /// through PATH (`cli_installed` / `is_command_available`,
    /// antigravity.rs:79-81).
    static func productionIsCLIInstalled(
        _ binary: String,
        _ environment: [String: String]
    ) -> Bool {
        if binary.contains("/") {
            return FileManager.default.isExecutableFile(atPath: binary)
        }
        return isCommandAvailable(binary, environment: environment)
    }
}

// MARK: - Pure argv + classify

/// `build_command` argv shape (antigravity.rs:549-576), without
/// `--effort` / `--conversation` this slice.
func antigravityArguments(for run: LiveAntigravityRun) -> [String] {
    let printTimeout = max(Int(run.timeout.rounded(.down)), 30)
    var args = [
        "--print", run.prompt,
        "--model", run.model,
        "--add-dir", run.workspaceDirectory.path,
        "--log-file", run.logFile.path,
        "--print-timeout", "\(printTimeout)s",
    ]
    if run.skipPermissions {
        args.append("--dangerously-skip-permissions")
    }
    return args
}

/// Classification of a finished `agy --print` process. Not `Result` —
/// Failure would need `Error` conformance under Swift 6, and the message is
/// already the wire-facing payload.
enum AntigravityClassification: Sendable, Equatable {
    case success(String)
    case failure(String)
}

/// Classify a finished `agy --print` process. agy exits 0 even on errors, so
/// stdout/stderr text is inspected first (`classify_output`,
/// antigravity.rs:483-526). Only the FIRST non-empty stdout line is checked
/// for the `Error:` prefix — a subagent's legitimate report may contain
/// "Error:" further down. The `jetski: no output produced` diagnostic is
/// matched anywhere.
func classifyAntigravityOutput(
    stdout: String,
    stderr: String,
    exitOK: Bool
) -> AntigravityClassification {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let stdoutLines = trimmed.splitAntigravityLines()
    let firstLineError = stdoutLines.first.flatMap { line -> String? in
        line.hasPrefix("Error:") ? line : nil
    }
    let jetskiLine = stdoutLines.first(where: { $0.hasPrefix("jetski: no output produced") })
    if let line = firstLineError ?? jetskiLine {
        var message = line
        if line.lowercased().contains("sign in") {
            message += " (run `agy` once in a terminal to sign in)"
        }
        return .failure(message)
    }
    if trimmed.isEmpty {
        let stderrLines = stderr.splitAntigravityLines()
        if let line = stderrLines.first(where: {
            $0.hasPrefix("Error:") || $0.hasPrefix("jetski: no output produced")
        }) {
            return .failure(line)
        }
    }
    if !exitOK {
        let stderrTrimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let tailSource = stderrTrimmed.isEmpty ? trimmed : stderrTrimmed
        let tail = String(tailSource.suffix(500))
        return .failure("Antigravity CLI exited with an error: \(tail)")
    }
    if trimmed.isEmpty {
        return .failure("Antigravity CLI produced no output")
    }
    return .success(trimmed)
}

/// Fallback wall-clock budget when `OPENGROK_SUBAGENT_TIMEOUT_MS` is unset
/// (`DEFAULT_RUN_TIMEOUT`, antigravity_runner.rs:37-38).
func antigravityRunTimeout(environment: [String: String]) -> TimeInterval {
    if let raw = environment["OPENGROK_SUBAGENT_TIMEOUT_MS"],
       let millis = Double(raw), millis > 0 {
        return millis / 1000.0
    }
    return 600
}

// MARK: - Refusal copy (verbatim from antigravity_runner.rs:100-127)

enum LiveAntigravityRefusal {
    static let featureDisabled =
        "Antigravity subagents are disabled. Enable the \"Antigravity "
        + "subagents\" setting (`[ui].antigravity_subagents`) first."

    static func cliNotInstalled(binary: String) -> String {
        "Antigravity CLI (`\(binary)`) was not found on this system."
    }

    static func notSignedIn(binary: String, detail: String) -> String {
        "Antigravity CLI is not signed in (\(detail)). Run `\(binary)` once in a terminal "
            + "to sign in, then retry."
    }

    static func unknownModel(_ model: String, available: [String]) -> String {
        "Unknown antigravity model \"\(model)\". Available: \(available.joined(separator: ", "))"
    }

    /// Resume without a stored conversation id is refused rather than falling
    /// through to in-process transcript resume — that silent path would be
    /// the §3 failure mode (antigravity_runner.rs:145-154).
    static func cannotResume(subagentID: String) -> String {
        "Cannot resume antigravity subagent '\(subagentID)': no stored Antigravity "
            + "conversation id (the source may predate this feature)."
    }
}

// MARK: - Production probe / run (async wrappers around bounded process)

private func productionProbeModels(binary: String) async -> LiveAntigravityStatus {
    let outcome = await Task.detached(priority: .userInitiated) {
        runBoundedAntigravityProcess(
            executable: binary,
            arguments: ["models"],
            currentDirectory: nil,
            environment: ProcessInfo.processInfo.environment,
            timeout: 15
        )
    }.value
    switch outcome {
    case .exited(_, let stdout, let stderr):
        return LiveAntigravityStatus.parse(stdout: stdout, stderr: stderr)
    case .timedOut:
        return .unavailable("`\(binary) models` timed out after 15s")
    case .failedToStart(let message):
        return .unavailable("failed to run `\(binary) models`: \(message)")
    }
}

private func productionRunPrint(_ run: LiveAntigravityRun) async -> LiveAntigravityRunOutcome {
    if Task.isCancelled { return .cancelled }
    let args = antigravityArguments(for: run)
    // Hard-kill grace past `--print-timeout` (`KILL_GRACE`, antigravity.rs:51).
    let hardDeadline = run.timeout + 30
    let outcome = await Task.detached(priority: .userInitiated) {
        runBoundedAntigravityProcess(
            executable: run.binary,
            arguments: args,
            currentDirectory: run.workspaceDirectory,
            environment: ProcessInfo.processInfo.environment,
            timeout: hardDeadline
        )
    }.value
    if Task.isCancelled { return .cancelled }
    switch outcome {
    case .exited(let status, let stdout, let stderr):
        switch classifyAntigravityOutput(
            stdout: stdout,
            stderr: stderr,
            exitOK: status == 0
        ) {
        case .success(let output):
            return .success(output: output)
        case .failure(let message):
            return .failure(message)
        }
    case .timedOut:
        return .failure("Antigravity CLI timed out after \(Int(run.timeout))s")
    case .failedToStart(let message):
        return .failure("failed to launch `\(run.binary)`: \(message)")
    }
}

// MARK: - Line splitting (CRLF-safe)

private extension String {
    /// Split on any newline (`Character.isNewline`), then strip trailing `\r`
    /// so CRLF streams don't leave a carriage return on the last token —
    /// `\r\n` is one `Character` in Swift, and byte-level `"\n"` scans miss
    /// `"\r\n\r\n"` (AGENTS.md §2).
    func splitAntigravityLines() -> [String] {
        split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
