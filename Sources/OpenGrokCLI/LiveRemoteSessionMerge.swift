import Foundation
import OpenGrokCLIChatProxyTypes

/// Merge the authenticated registry lane without confusing repositories that
/// happen to share an owner/path on different Git hosts.
///
/// Rust: `session/merge.rs:285-417`; `workspace/session/git.rs:285-338`.
enum LiveRemoteSessionMerge {
    enum Source: String, Sendable, Equatable {
        case local
        case remote
        case both
    }

    struct Entry: Sendable, Equatable {
        let listing: LiveSessionListing
        let source: Source
        let firstPrompt: String?
    }

    static let maximumRows = 10_000
    static let maximumRepositoryBytes = 4_096
    static let maximumDisplayBytes = 16_384

    static func merge(
        local: [LiveSessionListing],
        remote: [SessionReplicaResponse],
        repositoryRemotes: [String],
        limit: Int
    ) -> [Entry] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, maximumRows)
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(min(maximumRows, local.count + min(remote.count, maximumRows)))

        for listing in local.prefix(maximumRows) where validLocalListing(listing) {
            var sanitized = listing
            sanitized.messageCount = max(0, listing.messageCount)
            sanitized.userMessageCount = max(0, listing.userMessageCount)
            sanitized.assistantMessageCount = max(0, listing.assistantMessageCount)
            entries[listing.sessionID] = Entry(
                listing: sanitized,
                source: .local,
                firstPrompt: nil
            )
        }

        let scopedToRepository = !repositoryRemotes.isEmpty
        let allowedRepositories = Set(repositoryRemotes.prefix(256).compactMap(
            normalizeRepositoryURL
        ))

        for replica in remote.prefix(maximumRows) {
            guard validRemoteReplica(replica) else { continue }
            if scopedToRepository {
                guard let remoteURL = replica.repoRemoteURL,
                      let repository = normalizeRepositoryURL(remoteURL),
                      allowedRepositories.contains(repository)
                else { continue }
            }

            let previous = entries[replica.sessionId]
            let previousListing = previous?.listing
            let source: Source = previous?.source == .local || previous?.source == .both
                ? .both
                : .remote
            let remoteActivity = replica.lastActiveAt ?? replica.updatedAt
            let lastActivity = previousListing.map {
                max($0.lastActivityAt, remoteActivity)
            } ?? remoteActivity
            let remoteMessages = max(0, Int(replica.lastTurnNumber))
            let parentSessionID = previousListing == nil
                ? replica.parentSessionId
                : previousListing?.parentSessionID
            let listing = LiveSessionListing(
                sessionID: replica.sessionId,
                workingDirectory: replica.cwd,
                parentSessionID: parentSessionID,
                title: replica.summary.isEmpty ? nil : replica.summary,
                model: replica.modelId,
                createdAt: replica.createdAt,
                lastActivityAt: lastActivity,
                messageCount: max(previousListing?.messageCount ?? 0, remoteMessages),
                userMessageCount: max(previousListing?.userMessageCount ?? 0, 0),
                assistantMessageCount: max(previousListing?.assistantMessageCount ?? 0, 0),
                foreignSource: previousListing?.foreignSource
            )
            entries[replica.sessionId] = Entry(
                listing: listing,
                source: source,
                firstPrompt: replica.firstPrompt
            )
        }

        let sorted = entries.values.sorted { left, right in
            if left.listing.lastActivityAt == right.listing.lastActivityAt {
                return left.listing.sessionID < right.listing.sessionID
            }
            return left.listing.lastActivityAt > right.listing.lastActivityAt
        }

        var result: [Entry] = []
        result.reserveCapacity(min(boundedLimit, sorted.count))
        var emptyDirectories = Set<String>()
        for entry in sorted {
            if entry.listing.messageCount == 0,
               !emptyDirectories.insert(normalizeWorkingDirectory(
                   entry.listing.workingDirectory
               )).inserted {
                continue
            }
            result.append(entry)
            if result.count == boundedLimit { break }
        }
        return result
    }

    /// Transport and optional credentials disappear; the host never does.
    /// The memory normalizer deliberately drops that host and therefore
    /// cannot safely decide whether two remote sessions share a repository.
    static func normalizeRepositoryURL(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumRepositoryBytes,
              !containsControlCharacter(raw)
        else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("\\"),
              !value.contains("?"),
              !value.contains("#")
        else { return nil }

        let authority: Substring
        let rawPath: Substring
        if let delimiter = value.range(of: "://") {
            let scheme = value[..<delimiter.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme) else { return nil }
            let remainder = value[delimiter.upperBound...]
            guard let slash = remainder.firstIndex(of: "/") else { return nil }
            authority = remainder[..<slash]
            rawPath = remainder[slash...]
        } else {
            guard let separator = value.firstIndex(of: ":") else { return nil }
            authority = value[..<separator]
            rawPath = value[value.index(after: separator)...]
        }

        guard let host = normalizedHost(authority),
              let path = normalizedRepositoryPath(rawPath)
        else { return nil }
        return "\(host)/\(path)"
    }

    private static func normalizedHost(_ authority: Substring) -> String? {
        guard !authority.isEmpty,
              authority.utf8.count <= 512,
              !authority.contains(where: { $0.isWhitespace })
        else { return nil }

        let components = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count <= 2,
              let candidate = components.last,
              !candidate.isEmpty
        else { return nil }
        if components.count == 2, components[0].isEmpty {
            return nil
        }

        let host: Substring
        if candidate.hasPrefix("[") {
            guard let closing = candidate.firstIndex(of: "]") else { return nil }
            let address = candidate[candidate.index(after: candidate.startIndex)..<closing]
            guard address.contains(":"),
                  address.allSatisfy({ character in
                      character == ":" || character.isHexDigit
                  })
            else { return nil }
            let remainder = candidate[candidate.index(after: closing)...]
            if !remainder.isEmpty {
                guard remainder.first == ":",
                      validPort(remainder.dropFirst())
                else { return nil }
            }
            return "[\(address.lowercased())]"
        }

        if let separator = candidate.lastIndex(of: ":") {
            host = candidate[..<separator]
            guard validPort(candidate[candidate.index(after: separator)...]) else {
                return nil
            }
        } else {
            host = candidate
        }

        guard !host.isEmpty,
              host.utf8.count <= 253,
              host.allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber
                      || character == "." || character == "-")
              })
        else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
        }) else { return nil }
        return host.lowercased()
    }

    private static func validPort(_ port: Substring) -> Bool {
        guard !port.isEmpty, port.allSatisfy(\.isNumber),
              let value = UInt16(port)
        else { return false }
        return value != 0
    }

    private static func normalizedRepositoryPath(_ value: Substring) -> String? {
        var path = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        guard !path.isEmpty,
              path.utf8.count <= maximumRepositoryBytes,
              !path.contains(where: { $0.isWhitespace })
        else { return nil }

        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !segment.isEmpty,
                  segment != ".",
                  segment != "..",
                  let decoded = String(segment).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !containsControlCharacter(decoded)
            else { return nil }
        }
        return path
    }

    private static func validLocalListing(_ listing: LiveSessionListing) -> Bool {
        validSessionID(listing.sessionID)
            && safeDisplayString(listing.workingDirectory)
            && safeDisplayString(listing.title)
            && safeDisplayString(listing.model)
            && listing.createdAt.timeIntervalSinceReferenceDate.isFinite
            && listing.lastActivityAt.timeIntervalSinceReferenceDate.isFinite
    }

    private static func validRemoteReplica(_ replica: SessionReplicaResponse) -> Bool {
        validSessionID(replica.sessionId)
            && safeDisplayString(replica.cwd)
            && safeDisplayString(replica.summary)
            && safeDisplayString(replica.modelId)
            && safeDisplayString(replica.firstPrompt)
            && (replica.parentSessionId.map(validSessionID) ?? true)
            && replica.createdAt.timeIntervalSinceReferenceDate.isFinite
            && replica.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && (replica.lastActiveAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
    }

    private static func validSessionID(_ value: String) -> Bool {
        do {
            try LiveConversationStore.validateSessionID(value)
            return true
        } catch {
            return false
        }
    }

    private static func safeDisplayString(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumDisplayBytes && !containsControlCharacter(value)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
        }
    }

    private static func normalizeWorkingDirectory(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") {
            result.removeLast()
        }
        if result.isEmpty { return "/" }
        while result.contains("/./") {
            result = result.replacingOccurrences(of: "/./", with: "/")
        }
        return result
    }
}
