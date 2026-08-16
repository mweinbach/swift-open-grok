import Foundation
import OpenGrokPagerRender

enum LiveWaveETurnPhase: Sendable, Equatable {
    case thinking
    case responding
    case retrying(attempt: Int, maximum: Int, reason: String)
    case waiting(String)
    case tool(String)
    case preparingTool
    case cancelling
    case compacting
    case bash(String?)
    case mcpStartup(String?)
    case drainBlocked
    case watcher(String?)
    case failed(String)
    case custom(String)

    var label: String {
        switch self {
        case .thinking: return "Thinking\u{2026}"
        case .responding: return "Responding\u{2026}"
        case .retrying(let attempt, let maximum, let reason):
            return "Retrying (\(attempt)/\(maximum)): \(reason)"
        case .waiting(let reason): return "Waiting on you: \(reason)"
        case .tool(let name): return name
        case .preparingTool: return "Preparing tool\u{2026}"
        case .cancelling: return "Cancelling\u{2026}"
        case .compacting: return "Compacting context\u{2026}"
        case .bash(let command): return command.map { "Running bash: \($0)" } ?? "Running bash\u{2026}"
        case .mcpStartup(let server): return server.map { "Starting MCP: \($0)" } ?? "Starting MCP\u{2026}"
        case .drainBlocked: return "Waiting for queued work\u{2026}"
        case .watcher(let activity): return activity ?? "Watching background work\u{2026}"
        case .failed(let kind): return "Failed (\(kind))"
        case .custom(let label): return label
        }
    }

    var indicator: PagerTurnIndicator {
        switch self {
        case .waiting, .drainBlocked: return .pendingUserDiamond
        case .watcher: return .idleMonitor
        default: return .spinner
        }
    }

    var allowsCancel: Bool {
        switch self {
        case .cancelling, .failed, .watcher: return false
        default: return true
        }
    }

    static func status(_ text: String) -> LiveWaveETurnPhase {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("compact") { return .compacting }
        if lower.contains("mcp") && (lower.contains("start") || lower.contains("connect")) {
            return .mcpStartup(trimmed)
        }
        if lower.contains("bash") || lower.hasPrefix("running command") {
            return .bash(trimmed)
        }
        if lower.contains("drain") || lower.contains("queued work") {
            return .drainBlocked
        }
        if lower.contains("watcher") || lower.contains("monitor") {
            return .watcher(trimmed)
        }
        if lower.contains("waiting") || lower.contains("permission") {
            return .waiting(trimmed)
        }
        if lower.contains("cancel") { return .cancelling }
        return .custom(trimmed)
    }
}
