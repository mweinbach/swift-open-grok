import Foundation
import OpenGrokFileUtils
import OpenGrokMemory
import OpenGrokSamplingTypes

#if os(Windows)
import COpenGrokSockets
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LiveMemorySessionEndResult: Sendable, Equatable {
    case disabled
    case configuredOff
    case subagent
    case providerBoundaryClosed
    case ephemeralWorkspace
    case sessionMismatch
    case workspaceMismatch
    case tooFewPrompts
    case tooFewQueryBytes
    case alreadySaved(path: String)
    case written(path: String)
    case failed(String)
}

enum LiveMemoryLifecycleError: Error, Equatable {
    case unsafeSessionID(String)
    case insecureDirectory(String)
    case indexUnavailable(String)
    case summaryWasNotIndexed(String)
}

enum LiveMemorySessionSummary {
    static let minimumUserMessages = 3
    static let minimumTotalQueryBytes = 50

    private static let autoContinuePrompt = """
    Continue the conversation from where it left off without asking the user any further questions. Resume directly - do not acknowledge the summary, do not recap what was happening, do not preface with "I'll continue" or similar.
    Pick up the last task as if the break never happened.
    """

    private static let metadataTags = [
        "user_info",
        "project_layout",
        "git_status",
        "fork-context",
        "system-reminder",
        "agent-memory",
        "system_reminder",
        "background_context",
        "command-name",
        "command-message",
        "command-args",
    ]

    static func realUserQueries(_ conversation: [ConversationItem]) -> [String] {
        conversation.compactMap { item in
            guard case .user(let user) = item, user.syntheticReason == nil else {
                return nil
            }

            let query = extractUserQuery(item.textContent())
            let containsImage = user.content.contains { part in
                if case .image = part { return true }
                return false
            }
            guard containsImage || (!query.isEmpty
                && query != "__auto_continue__"
                && query != autoContinuePrompt)
            else {
                return nil
            }
            return query
        }
    }

    static func render(
        conversation: [ConversationItem],
        realQueries: [String],
        date: Date
    ) -> String {
        let assistantCount = conversation.reduce(into: 0) { count, item in
            if case .assistant = item { count += 1 }
        }
        let toolCount = conversation.reduce(into: 0) { count, item in
            switch item {
            case .toolResult, .customToolOutput:
                count += 1
            default:
                break
            }
        }

        var result = "## Session Summary\n\n"
        result += "- **Messages:** \(realQueries.count) user, "
        result += "\(assistantCount) assistant, \(toolCount) tool results\n"
        result += "- **Date:** \(utcDate(date, format: "yyyy-MM-dd HH:mm 'UTC'"))\n\n"

        if !realQueries.isEmpty {
            result += "## Topics Discussed\n\n"
            for (offset, query) in realQueries.prefix(5).enumerated() {
                result += "\(offset + 1). \(String(query.prefix(100)))\n"
            }
            result += "\n"
        }
        return result
    }

    static func utcDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func extractUserQuery(_ text: String) -> String {
        let query: String
        if let open = text.range(of: "<user_query>"),
           let close = text.range(of: "</user_query>", range: open.upperBound..<text.endIndex)
        {
            query = String(text[open.upperBound..<close.lowerBound])
        } else {
            query = text
        }

        var stripped = query
        for tag in metadataTags {
            let opening = "<\(tag)>"
            let closing = "</\(tag)>"
            while let start = stripped.range(of: opening),
                  let end = stripped.range(of: closing, range: start.upperBound..<stripped.endIndex)
            {
                stripped.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LiveMemorySessionStorage {
    static func writeSummary(
        storage: MemoryStorage,
        sessionID: String,
        conversation: [ConversationItem],
        realQueries: [String],
        date: Date
    ) throws -> URL {
        guard !sessionID.isEmpty,
              sessionID != ".",
              sessionID != "..",
              !sessionID.contains("/"),
              !sessionID.contains("\\")
        else {
            throw LiveMemoryLifecycleError.unsafeSessionID(sessionID)
        }

        try secureDirectory(storage.globalDir)
        try secureDirectory(storage.workspaceDir)
        try secureDirectory(storage.sessionsDir)
        try storage.ensureInitialized()

        let dateComponent = LiveMemorySessionSummary.utcDate(date, format: "yyyy-MM-dd")
        let firstQuery = realQueries.first ?? ""
        let querySlug = slugify(firstQuery, maxLength: 30)
        let slug = querySlug.isEmpty ? "session" : querySlug
        let suffix = String(sessionID.prefix(8))
        let path = storage.sessionsDir.appendingPathComponent(
            "\(dateComponent)-\(slug)-\(suffix).md"
        )
        let summary = LiveMemorySessionSummary.render(
            conversation: conversation,
            realQueries: realQueries,
            date: date
        )
        try SecureFile.write(at: path, contents: summary)
        guard try SecureFile.isOwnerOnly(at: path) else {
            throw LiveMemoryLifecycleError.insecureDirectory(path.path)
        }
        return path
    }

    static func validateClearTarget(
        _ target: URL,
        root: URL,
        isDirectory: Bool
    ) throws {
        try PathSecurity.rejectHostileLexical(root.path)
        try PathSecurity.rejectHostileLexical(target.path)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalParent = target.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonicalParent == canonicalRoot else {
            throw LiveMemoryLifecycleError.insecureDirectory(target.path)
        }

        #if os(Windows)
        let values = try target.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .isRegularFileKey,
        ])
        guard values.isSymbolicLink != true,
              isDirectory ? values.isDirectory == true : values.isRegularFile == true
        else {
            throw LiveMemoryLifecycleError.insecureDirectory(target.path)
        }
        #else
        var information = stat()
        guard target.path.withCString({ lstat($0, &information) }) == 0,
              information.st_uid == getuid(),
              information.st_mode & mode_t(S_IFMT)
                == mode_t(isDirectory ? S_IFDIR : S_IFREG)
        else {
            throw LiveMemoryLifecycleError.insecureDirectory(target.path)
        }
        #endif
    }

    private static func secureDirectory(_ directory: URL) throws {
        try PathSecurity.rejectHostileLexical(directory.path)

        #if os(Windows)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let secured = directory.path.withCString { og_directory_secure_current_user($0) }
        guard secured == 0 else {
            throw LiveMemoryLifecycleError.insecureDirectory(directory.path)
        }
        #else
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var information = stat()
        guard directory.path.withCString({ lstat($0, &information) }) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == getuid()
        else {
            throw LiveMemoryLifecycleError.insecureDirectory(directory.path)
        }
        if information.st_mode & 0o777 != 0o700,
           directory.path.withCString({ chmod($0, mode_t(0o700)) }) != 0
        {
            throw LiveMemoryLifecycleError.insecureDirectory(directory.path)
        }
        #endif
    }
}
