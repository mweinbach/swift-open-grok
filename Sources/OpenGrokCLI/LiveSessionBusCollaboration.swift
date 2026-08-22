import Foundation
import OpenGrokAgentControlTools

enum LiveSessionBusTranscript {
    private static let maximumEntryScalars = 2_000
    private static let maximumTotalScalars = 64 * 1_024

    static func extract(
        data: Data,
        maxUpdates: Int
    ) -> [SessionCollaborationTranscriptEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let maximumUpdates = min(200, max(1, maxUpdates))
        var collected: [SessionCollaborationTranscriptEntry] = []

        for line in text.split(whereSeparator: \.isNewline) {
            guard let bytes = String(line).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: bytes)
                    as? [String: Any],
                  let method = value["method"] as? String,
                  let params = value["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let kind = update["sessionUpdate"] as? String
            else { continue }

            let entry: SessionCollaborationTranscriptEntry?
            switch (method, kind) {
            case ("session/update", "user_message_chunk"):
                entry = transcriptEntry(role: "user", update: update)
            case ("session/update", "agent_message_chunk"):
                entry = transcriptEntry(role: "agent", update: update)
            case ("_x.ai/session/update", "peer_session_message"):
                guard let body = update["body"] as? String else { continue }
                entry = SessionCollaborationTranscriptEntry(role: "peer", text: body)
            default:
                entry = nil
            }
            if let entry {
                collected.append(entry)
            }
        }

        var result: [SessionCollaborationTranscriptEntry] = []
        var scalarCount = 0
        for entry in collected.suffix(maximumUpdates) {
            let text: String
            if entry.text.unicodeScalars.count > maximumEntryScalars {
                let prefix = entry.text.unicodeScalars.prefix(maximumEntryScalars)
                text = String(String.UnicodeScalarView(prefix)) + "…"
            } else {
                text = entry.text
            }
            let count = text.unicodeScalars.count
            guard scalarCount + count <= maximumTotalScalars else { break }
            scalarCount += count
            result.append(SessionCollaborationTranscriptEntry(role: entry.role, text: text))
        }
        return result
    }

    private static func transcriptEntry(
        role: String,
        update: [String: Any]
    ) -> SessionCollaborationTranscriptEntry? {
        guard let content = update["content"] as? [String: Any],
              let text = content["text"] as? String
        else { return nil }
        return SessionCollaborationTranscriptEntry(role: role, text: text)
    }
}
