import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

/// A fork directive remains outside the transcript until the child submits it
/// as its first genuine user turn. The inherited-prefix digest prevents a
/// relocated or rewritten session from acquiring another fork's authority.
struct LivePendingForkDirective: Codable, Sendable, Equatable {
    let sessionID: String
    let parentSessionID: String
    let workingDirectory: String
    let directive: String
    let inheritedItemCount: Int
    let inheritedPrefixDigest: String
    var claimID: String?

    init(
        sessionID: String,
        parentSessionID: String,
        workingDirectory: URL,
        directive: String,
        inheritedItems: [ConversationItem]
    ) throws {
        guard !directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIApplicationError.failed("fork directive must not be empty")
        }
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.workingDirectory = workingDirectory.standardizedFileURL.path
        self.directive = directive
        self.inheritedItemCount = inheritedItems.count
        self.inheritedPrefixDigest = try Self.digest(inheritedItems)
        self.claimID = nil
    }

    func validate(record: LiveConversationRecord, workingDirectory: URL? = nil) throws {
        guard record.sessionID == sessionID,
              record.parentSessionID == parentSessionID,
              inheritedItemCount >= 0,
              inheritedItemCount <= record.items.count,
              !directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LiveToolExecutor.workspaceRootsMatch(
                URL(fileURLWithPath: self.workingDirectory, isDirectory: true),
                URL(fileURLWithPath: record.workingDirectory, isDirectory: true)
              ),
              workingDirectory.map({
                LiveToolExecutor.workspaceRootsMatch(
                    URL(fileURLWithPath: self.workingDirectory, isDirectory: true),
                    $0
                )
              }) ?? true,
              try Self.digest(Array(record.items.prefix(inheritedItemCount)))
                == inheritedPrefixDigest
        else {
            throw CLIApplicationError.failed(
                "pending fork directive does not match its child session, workspace, or inherited conversation"
            )
        }
    }

    private static func digest(_ items: [ConversationItem]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hexDigest(try encoder.encode(items))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case parentSessionID = "parent_session_id"
        case workingDirectory = "working_directory"
        case directive
        case inheritedItemCount = "inherited_item_count"
        case inheritedPrefixDigest = "inherited_prefix_digest"
        case claimID = "claim_id"
    }
}
