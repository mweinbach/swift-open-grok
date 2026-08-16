// LiveAntigravity.swift
//
// Antigravity CLI (`agy`) subagent integration — presence probe, config
// reader, output classification, and the injectable services seam.
//
// Rust reference at pin 650c1db7:
//   * `crates/codegen/xai-grok-shell/src/agent/antigravity.rs`
//   * `crates/codegen/xai-grok-shell/src/agent/subagent/antigravity_runner.rs`
//
// The live runner also tails the agy log for phase heartbeats and the
// short-lived LanguageServer HTTP port, whose quota/model payloads are cached
// process-wide for spawn validation and `/usage`.

import Foundation
import OpenGrokConfig
import OpenGrokHTTP

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

    /// Blessed base model, surfaced first in model guidance and suggested when
    /// a cached availability payload rejects another model.
    public static let referenceModel = "gemini-3.6-flash"

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

    /// Whether a spawn could actually accept an `antigravity:<model>` slug —
    /// the same two cheap checks the spawn gate applies first
    /// (`antigravity_runner.rs:100-127`), so the advertised contract and the
    /// refusal path agree. Deliberately does NOT probe `agy models`: this runs
    /// during session construction and the roster costs a 15s-timeout
    /// subprocess.
    public static func antigravitySelectable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let config = LiveAntigravityConfig.load(environment: environment)
        return config.enabled
            && LiveAntigravityServices.productionIsCLIInstalled(config.binary, environment)
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

    static func invalidateCaches() {
        LiveAntigravityCache.shared.invalidate()
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

    /// Roster as task-tool slugs (`prefixed_models`, antigravity.rs:110-118),
    /// with the reference base model first, then its effort siblings, then the
    /// remaining probe order.
    var prefixedModels: [String] {
        models.enumerated()
            .sorted { lhs, rhs in
                let leftRank = antigravityReferenceRank(lhs.element)
                let rightRank = antigravityReferenceRank(rhs.element)
                return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
            }
            .map { LiveAntigravityComposition.modelPrefix + $0.element }
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

/// One `--print` invocation (`AgyRun`, antigravity.rs:434-453).
struct LiveAntigravityRun: Sendable {
    var binary: String
    var model: String
    var effort: String? = nil
    var modelRoster: [String] = []
    var prompt: String
    var workspaceDirectory: URL
    var logFile: URL
    var timeout: TimeInterval
    var skipPermissions: Bool
    var conversationID: String? = nil
}

enum LiveAntigravityRunOutcome: Sendable, Equatable {
    case success(output: String, conversationID: String?)
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
    var fetchQuotaSummary: @Sendable (UInt16) async -> [LiveAntigravityQuotaBucket]?
    var fetchAvailableModels: @Sendable (UInt16) async -> [LiveAntigravityModelAvailability]?

    init(
        loadConfig: @escaping @Sendable ([String: String]) -> LiveAntigravityConfig,
        isCLIInstalled: @escaping @Sendable (_ binary: String, _ environment: [String: String]) -> Bool,
        probeModels: @escaping @Sendable (_ binary: String) async -> LiveAntigravityStatus,
        runPrint: @escaping @Sendable (LiveAntigravityRun) async -> LiveAntigravityRunOutcome,
        fetchQuotaSummary: @escaping @Sendable (UInt16) async -> [LiveAntigravityQuotaBucket]? = { _ in nil },
        fetchAvailableModels: @escaping @Sendable (UInt16) async -> [LiveAntigravityModelAvailability]? = { _ in nil }
    ) {
        self.loadConfig = loadConfig
        self.isCLIInstalled = isCLIInstalled
        self.probeModels = probeModels
        self.runPrint = runPrint
        self.fetchQuotaSummary = fetchQuotaSummary
        self.fetchAvailableModels = fetchAvailableModels
    }

    static let production = LiveAntigravityServices(
        loadConfig: { LiveAntigravityConfig.load(environment: $0) },
        isCLIInstalled: { productionIsCLIInstalled($0, $1) },
        probeModels: { binary in
            await productionProbeModels(binary: binary)
        },
        runPrint: { run in
            await productionRunPrint(run)
        },
        fetchQuotaSummary: { port in
            await productionFetchQuotaSummary(port: port)
        },
        fetchAvailableModels: { port in
            await productionFetchAvailableModels(port: port)
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

struct LiveAntigravityModelPlan: Sendable, Equatable {
    var model: String
    var effort: String?
}

func normalizeAntigravityEffort(_ effort: String) -> String? {
    switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "minimal", "low": return "low"
    case "medium": return "medium"
    case "high", "xhigh", "max", "ultra": return "high"
    default: return nil
    }
}

private let antigravityEffortSuffixes = ["-low", "-medium", "-high"]

func baseAntigravityModelID(_ model: String) -> String {
    for suffix in antigravityEffortSuffixes where model.hasSuffix(suffix) {
        return String(model.dropLast(suffix.count))
    }
    return model
}

func planAntigravityModelArguments(
    model: String,
    effort: String?,
    roster: [String]
) -> LiveAntigravityModelPlan {
    let normalized = effort.flatMap(normalizeAntigravityEffort)
    let base = baseAntigravityModelID(model)
    if base != model {
        if let normalized {
            let candidate = "\(base)-\(normalized)"
            if candidate != model, roster.contains(candidate) {
                return LiveAntigravityModelPlan(model: candidate, effort: nil)
            }
        }
        return LiveAntigravityModelPlan(model: model, effort: nil)
    }
    return LiveAntigravityModelPlan(model: model, effort: normalized)
}

private func antigravityReferenceRank(_ model: String) -> Int {
    if model == LiveAntigravityComposition.referenceModel { return 0 }
    if baseAntigravityModelID(model) == LiveAntigravityComposition.referenceModel { return 1 }
    return 2
}

/// `build_command` argv shape (antigravity.rs:549-576), including effort and
/// conversation continuation.
func antigravityArguments(for run: LiveAntigravityRun) -> [String] {
    let plan = planAntigravityModelArguments(
        model: run.model,
        effort: run.effort,
        roster: run.modelRoster
    )
    return antigravityArguments(for: run, model: plan.model, effort: plan.effort)
}

private func antigravityArguments(
    for run: LiveAntigravityRun,
    model: String,
    effort: String?
) -> [String] {
    let printTimeout = max(Int(run.timeout.rounded(.down)), 30)
    var args = [
        "--print", run.prompt,
        "--model", model,
        "--add-dir", run.workspaceDirectory.path,
        "--log-file", run.logFile.path,
        "--print-timeout", "\(printTimeout)s",
    ]
    if let effort {
        args.append(contentsOf: ["--effort", effort])
    }
    if let conversationID = run.conversationID {
        args.append(contentsOf: ["--conversation", conversationID])
    }
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
       let millis = Double(raw), millis > 0, millis.isFinite,
       // `Double("1e309")` is `.infinity` and `Double("1e30")` is finite but
       // far past `Int.max`; both reach `Int(timeout.rounded(.down))` in
       // `antigravityArguments`, which traps. A user typo in an env var must
       // not be able to kill the process before the child is even launched.
       millis / 1000.0 <= antigravityMaxRunTimeout {
        return millis / 1000.0
    }
    return 600
}

/// Upper bound on a configured run timeout. Chosen so the value stays exactly
/// representable as the `Int` seconds `agy --print-timeout` takes, with room
/// for the `+ 30` hard-kill grace added on top. Cost: a caller who genuinely
/// wants a longer-than-a-day budget silently gets the 600s default instead of
/// an error — the env var has no error channel, and defaulting is the same
/// thing an unparseable value already does.
let antigravityMaxRunTimeout: TimeInterval = 86_400

let antigravityMaxPromptBytes = 512 * 1_024

// MARK: - Runtime log, quota, and availability

struct LiveAntigravityQuotaBucket: Sendable, Equatable {
    var group: String
    var displayName: String
    var bucketID: String?
    var window: String?
    var remainingFraction: Double
    var resetTime: String?

    var label: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? group.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }

    var isExhausted: Bool { remainingFraction <= 0 }
}

struct LiveAntigravityQuotaSummary: Sendable, Equatable {
    var buckets: [LiveAntigravityQuotaBucket]
    var fetchedAt: Date

    func age(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(fetchedAt))
    }

    var firstExhausted: LiveAntigravityQuotaBucket? {
        buckets.first(where: \.isExhausted)
    }
}

struct LiveAntigravityModelAvailability: Sendable, Equatable {
    var key: String
    var remainingFraction: Double

    var isExhausted: Bool { remainingFraction <= 0 }
}

enum LiveAntigravityAvailabilityIssue: Sendable, Equatable {
    case exhausted
    case absent
}

final class LiveAntigravityCache: @unchecked Sendable {
    static let shared = LiveAntigravityCache()

    private struct StatusEntry {
        var binary: String
        var fetchedAt: Date
        var status: LiveAntigravityStatus
    }

    private let lock = NSLock()
    private var statusEntry: StatusEntry?
    private var quota: LiveAntigravityQuotaSummary?
    private var availableModels: [LiveAntigravityModelAvailability]?

    func status(binary: String, now: Date = Date()) -> LiveAntigravityStatus? {
        lock.lock()
        defer { lock.unlock() }
        guard let statusEntry, statusEntry.binary == binary else { return nil }
        let ttl: TimeInterval = statusEntry.status.signedIn ? 300 : 30
        guard now.timeIntervalSince(statusEntry.fetchedAt) < ttl else { return nil }
        return statusEntry.status
    }

    func store(status: LiveAntigravityStatus, binary: String, now: Date = Date()) {
        lock.lock()
        statusEntry = StatusEntry(binary: binary, fetchedAt: now, status: status)
        lock.unlock()
    }

    func quotaSummary() -> LiveAntigravityQuotaSummary? {
        lock.lock()
        defer { lock.unlock() }
        return quota
    }

    func store(quota buckets: [LiveAntigravityQuotaBucket], now: Date = Date()) {
        lock.lock()
        quota = LiveAntigravityQuotaSummary(buckets: buckets, fetchedAt: now)
        lock.unlock()
    }

    func models() -> [LiveAntigravityModelAvailability]? {
        lock.lock()
        defer { lock.unlock() }
        return availableModels
    }

    func store(models: [LiveAntigravityModelAvailability]) {
        lock.lock()
        availableModels = models
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        statusEntry = nil
        quota = nil
        availableModels = nil
        lock.unlock()
    }
}

func parseAntigravityHTTPPort(_ log: String) -> UInt16? {
    let marker = "listening on random port at "
    for line in log.split(whereSeparator: \.isNewline) {
        let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("for HTTP"), let range = text.range(of: marker) else { continue }
        let digits = text[range.upperBound...].prefix(while: \.isNumber)
        guard let port = UInt16(digits), port != 0 else { continue }
        return port
    }
    return nil
}

func antigravityPhase(from log: String) -> String {
    if log.contains("Language server shutting down") { return "Wrapping up" }
    if log.contains("cascade")
        || log.contains("Cascade")
        || log.contains("tool_call")
        || log.contains("ExecuteCommand")
        || log.contains("RunCommand") {
        return "Working"
    }
    if log.contains("for HTTP") && log.contains("listening on random port at") {
        return "Language server ready"
    }
    if log.contains("Print mode: conversation=") || log.contains("Created conversation ") {
        return "Model resolved"
    }
    return "Starting"
}

func extractAntigravityConversationID(_ log: String) -> String? {
    for marker in ["Print mode: conversation=", "Created conversation "] {
        for line in log.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: marker) else { continue }
            let identifier = line[range.upperBound...].prefix {
                $0.isHexDigit || $0 == "-"
            }
            if identifier.count >= 32 { return String(identifier) }
        }
    }
    return nil
}

func parseAntigravityQuotaSummary(_ data: Data) -> [LiveAntigravityQuotaBucket]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = root["response"] as? [String: Any],
          let groups = response["groups"] as? [[String: Any]] else { return nil }
    var result: [LiveAntigravityQuotaBucket] = []
    for group in groups {
        let groupName = group["displayName"] as? String ?? ""
        guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
        for bucket in buckets {
            result.append(LiveAntigravityQuotaBucket(
                group: groupName,
                displayName: bucket["displayName"] as? String ?? "",
                bucketID: bucket["bucketId"] as? String,
                window: bucket["window"] as? String,
                remainingFraction: (bucket["remainingFraction"] as? NSNumber)?.doubleValue ?? 1,
                resetTime: bucket["resetTime"] as? String
            ))
        }
    }
    return result.isEmpty ? nil : result
}

func parseAntigravityAvailableModels(_ data: Data) -> [LiveAntigravityModelAvailability]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = root["response"] as? [String: Any],
          let models = response["models"] as? [String: Any] else { return nil }
    let result = models.compactMap { key, value -> LiveAntigravityModelAvailability? in
        guard let entry = value as? [String: Any] else { return nil }
        let quota = entry["quotaInfo"] as? [String: Any]
        return LiveAntigravityModelAvailability(
            key: key,
            remainingFraction: (quota?["remainingFraction"] as? NSNumber)?.doubleValue ?? 1
        )
    }
    return result.isEmpty ? nil : result
}

private func antigravityAvailabilityKeyMatches(
    _ key: String,
    model: String,
    base: String
) -> Bool {
    key.caseInsensitiveCompare(model) == .orderedSame
        || key.caseInsensitiveCompare(base) == .orderedSame
        || baseAntigravityModelID(key).caseInsensitiveCompare(base) == .orderedSame
}

func antigravityModelAvailabilityIssue(
    model: String,
    roster: [String]
) -> LiveAntigravityAvailabilityIssue? {
    guard let models = LiveAntigravityCache.shared.models(), !models.isEmpty else { return nil }
    let base = baseAntigravityModelID(model)
    if let entry = models.first(where: {
        antigravityAvailabilityKeyMatches($0.key, model: model, base: base)
    }) {
        return entry.isExhausted ? .exhausted : nil
    }
    let compatible = roster.contains { rosterID in
        let rosterBase = baseAntigravityModelID(rosterID)
        return models.contains {
            antigravityAvailabilityKeyMatches($0.key, model: rosterID, base: rosterBase)
        }
    }
    return compatible ? .absent : nil
}

func antigravityExhaustedQuotaNote() -> String? {
    guard let bucket = LiveAntigravityCache.shared.quotaSummary()?.firstExhausted else { return nil }
    if let reset = bucket.resetTime?.trimmingCharacters(in: .whitespacesAndNewlines), !reset.isEmpty {
        return "Antigravity quota: \(bucket.label) exhausted, resets \(reset)"
    }
    return "Antigravity quota: \(bucket.label) exhausted"
}

func antigravityUnavailableModelMessage(
    model: String,
    issue: LiveAntigravityAvailabilityIssue
) -> String {
    var message: String
    switch issue {
    case .exhausted:
        message = "Antigravity model \"\(model)\" is out of quota."
    case .absent:
        message = "Antigravity model \"\(model)\" is not currently available."
    }
    if baseAntigravityModelID(model) != LiveAntigravityComposition.referenceModel {
        message += " Try the reference model `\(LiveAntigravityComposition.modelPrefix)\(LiveAntigravityComposition.referenceModel)`."
    }
    if let note = antigravityExhaustedQuotaNote() {
        message += "\n\(note)"
    }
    return message
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
    if let cached = LiveAntigravityCache.shared.status(binary: binary) {
        return cached
    }
    let outcome = await Task.detached(priority: .userInitiated) {
        runBoundedAntigravityProcess(
            executable: binary,
            arguments: ["models"],
            currentDirectory: nil,
            environment: ProcessInfo.processInfo.environment,
            timeout: 15
        )
    }.value
    let status: LiveAntigravityStatus
    switch outcome {
    case .exited(_, let stdout, let stderr):
        status = LiveAntigravityStatus.parse(stdout: stdout, stderr: stderr)
    case .timedOut:
        status = .unavailable("`\(binary) models` timed out after 15s")
    case .failedToStart(let message):
        status = .unavailable("failed to run `\(binary) models`: \(message)")
    }
    LiveAntigravityCache.shared.store(status: status, binary: binary)
    return status
}

private func productionRunPrint(_ run: LiveAntigravityRun) async -> LiveAntigravityRunOutcome {
    if Task.isCancelled { return .cancelled }
    guard run.prompt.lengthOfBytes(using: .utf8) <= antigravityMaxPromptBytes else {
        return .failure(
            "prompt too large for the Antigravity CLI "
                + "(\(run.prompt.lengthOfBytes(using: .utf8)) bytes > \(antigravityMaxPromptBytes))"
        )
    }
    let plan = planAntigravityModelArguments(
        model: run.model,
        effort: run.effort,
        roster: run.modelRoster
    )
    let first = await productionRunPrintOnce(
        run,
        model: plan.model,
        effort: plan.effort
    )
    let outcome: LiveAntigravityRunOutcome
    switch first {
    case .failure(let message) where plan.effort != nil && message.contains("--effort is not supported"):
        outcome = await productionRunPrintOnce(run, model: plan.model, effort: nil)
    default:
        outcome = first
    }
    guard case .success(let output, _) = outcome else { return outcome }
    let log = (try? String(contentsOf: run.logFile, encoding: .utf8)) ?? ""
    let conversationID = extractAntigravityConversationID(log) ?? run.conversationID
    return .success(output: output, conversationID: conversationID)
}

private func productionRunPrintOnce(
    _ run: LiveAntigravityRun,
    model: String,
    effort: String?
) async -> LiveAntigravityRunOutcome {
    if Task.isCancelled { return .cancelled }
    let args = antigravityArguments(for: run, model: model, effort: effort)
    // Hard-kill grace past `--print-timeout` (`KILL_GRACE`, antigravity.rs:51).
    let hardDeadline = run.timeout + 30
    // `Task.detached(...).value` is not a cancellation point for a nonthrowing
    // task, so the child has to be reachable from the cancellation handler.
    // Without this the acknowledgement was a lie: the turn reported cancelled
    // while `agy --dangerously-skip-permissions` kept running.
    let canceller = AntigravityProcessCanceller()
    let outcome = await withTaskCancellationHandler {
        await Task.detached(priority: .userInitiated) {
            runBoundedAntigravityProcess(
                executable: run.binary,
                arguments: args,
                currentDirectory: run.workspaceDirectory,
                environment: ProcessInfo.processInfo.environment,
                timeout: hardDeadline,
                canceller: canceller
            )
        }.value
    } onCancel: {
        canceller.cancel()
    }
    if Task.isCancelled { return .cancelled }
    switch outcome {
    case .exited(let status, let stdout, let stderr):
        switch classifyAntigravityOutput(
            stdout: stdout,
            stderr: stderr,
            exitOK: status == 0
        ) {
        case .success(let output):
            return .success(output: output, conversationID: nil)
        case .failure(let message):
            return .failure(message)
        }
    case .timedOut:
        return .failure("Antigravity CLI timed out after \(Int(run.timeout))s")
    case .failedToStart(let message):
        return .failure("failed to launch `\(run.binary)`: \(message)")
    }
}

private func productionFetchQuotaSummary(port: UInt16) async -> [LiveAntigravityQuotaBucket]? {
    guard let data = await productionAntigravityRPC(port: port, method: "RetrieveUserQuotaSummary") else {
        return nil
    }
    return parseAntigravityQuotaSummary(data)
}

private func productionFetchAvailableModels(port: UInt16) async -> [LiveAntigravityModelAvailability]? {
    guard let data = await productionAntigravityRPC(port: port, method: "GetAvailableModels") else {
        return nil
    }
    return parseAntigravityAvailableModels(data)
}

private func productionAntigravityRPC(port: UInt16, method: String) async -> Data? {
    guard let url = URL(string:
        "http://localhost:\(port)/exa.language_server_pb.LanguageServerService/\(method)"
    ) else { return nil }
    let request = HTTPRequest(
        method: .post,
        url: url,
        headers: [
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
        ],
        body: Data("{}".utf8),
        timeout: 3,
        idempotency: .nonIdempotent
    )
    guard let response = try? await URLSessionHTTPTransport().send(request),
          (200..<300).contains(response.metadata.statusCode) else { return nil }
    return response.body
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
