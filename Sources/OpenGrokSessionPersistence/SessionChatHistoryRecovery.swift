import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport

/// Rebuild provider-neutral history from the authoritative ACP replay stream.
///
/// Mirrors `xai-grok-shell/src/session/storage/mod.rs:129-445` at `650c1db7`:
/// adjacent streamed chunks form one message, assistant tool calls precede
/// their completed results, host turns stay invisible, and compaction markers
/// discard history from the preceding context window.
struct SessionChatHistoryRecovery {
    private var history: [ConversationItem] = []
    private var userParts: [ContentPart] = []
    private var assistantText = ""
    private var assistantToolCalls: [ToolCall] = []
    private var emittedToolResults = Set<String>()
    private var inUserTurn = false
    private var hasAssistantContent = false

    mutating func recover(from updates: [SessionUpdateEnvelope]) throws -> [JSONValue] {
        for envelope in updates {
            guard let payload = envelope.params.objectValue else { continue }
            let update = payload["update"]?.objectValue ?? payload
            guard let kind = update["sessionUpdate"]?.stringValue else { continue }

            if envelope.method == "_x.ai/session/update" {
                if kind == "compaction_checkpoint" {
                    reset()
                }
                continue
            }
            guard envelope.method == "session/update" else { continue }

            switch kind {
            case "user_message_chunk":
                consumeUser(update)
            case "agent_message_chunk":
                consumeAssistant(update)
            case "tool_call":
                consumeToolCall(update)
            case "tool_call_update":
                consumeToolUpdate(update)
            default:
                continue
            }
        }
        flushUser()
        flushAssistant()
        return try history.map(JSONValue.encode)
    }

    private mutating func consumeUser(_ update: [String: JSONValue]) {
        guard let content = update["content"]?.objectValue else { return }
        if isHostTurn(update: update, content: content) {
            flushUser()
            flushAssistant()
            inUserTurn = false
            return
        }
        if !inUserTurn {
            flushAssistant()
            inUserTurn = true
        }
        switch content["type"]?.stringValue {
        case "text":
            if let text = content["text"]?.stringValue {
                userParts.append(.text(text: text))
            }
        case "image":
            if let imageURL = content["uri"]?.stringValue ?? content["url"]?.stringValue {
                userParts.append(.image(url: imageURL))
            }
        default:
            break
        }
    }

    private mutating func consumeAssistant(_ update: [String: JSONValue]) {
        guard let content = update["content"]?.objectValue else { return }
        if isHostTurn(update: update, content: content) {
            flushUser()
            flushAssistant()
            inUserTurn = false
            return
        }
        if inUserTurn {
            flushUser()
            inUserTurn = false
        }
        guard content["type"]?.stringValue == "text",
              let text = content["text"]?.stringValue else { return }
        assistantText.append(text)
        hasAssistantContent = true
    }

    private mutating func consumeToolCall(_ update: [String: JSONValue]) {
        if inUserTurn {
            flushUser()
            inUserTurn = false
        }
        guard let callID = update["toolCallId"]?.stringValue
            ?? update["tool_call_id"]?.stringValue else { return }
        let name = update["title"]?.stringValue ?? update["name"]?.stringValue ?? ""
        let arguments = encodeToolArguments(update["rawInput"] ?? update["raw_input"])
        if let index = assistantToolCalls.firstIndex(where: { $0.id == callID }) {
            if assistantToolCalls[index].arguments.isEmpty {
                assistantToolCalls[index].arguments = arguments
            }
        } else {
            assistantToolCalls.append(ToolCall(id: callID, name: name, arguments: arguments))
        }
    }

    private mutating func consumeToolUpdate(_ update: [String: JSONValue]) {
        guard let callID = update["toolCallId"]?.stringValue
            ?? update["tool_call_id"]?.stringValue else { return }

        if let rawInput = update["rawInput"] ?? update["raw_input"],
           let index = assistantToolCalls.firstIndex(where: { $0.id == callID }),
           assistantToolCalls[index].arguments.isEmpty {
            assistantToolCalls[index].arguments = encodeToolArguments(rawInput)
        }

        guard let status = update["status"]?.stringValue,
              status == "completed" || status == "failed",
              emittedToolResults.insert(callID).inserted else { return }
        flushAssistant()
        history.append(.toolResult(toolCallId: callID, content: toolResultText(update)))
    }

    private mutating func flushUser() {
        guard !userParts.isEmpty else { return }
        history.append(.userWithParts(userParts))
        userParts.removeAll(keepingCapacity: true)
    }

    private mutating func flushAssistant() {
        guard hasAssistantContent || !assistantToolCalls.isEmpty else { return }
        history.append(.assistant(AssistantItem(
            content: assistantText,
            toolCalls: assistantToolCalls
        )))
        assistantText = ""
        assistantToolCalls.removeAll(keepingCapacity: true)
        hasAssistantContent = false
    }

    private mutating func reset() {
        history.removeAll(keepingCapacity: true)
        userParts.removeAll(keepingCapacity: true)
        assistantText = ""
        assistantToolCalls.removeAll(keepingCapacity: true)
        emittedToolResults.removeAll(keepingCapacity: true)
        inUserTurn = false
        hasAssistantContent = false
    }

    private func isHostTurn(
        update: [String: JSONValue],
        content: [String: JSONValue]
    ) -> Bool {
        let contentMetadata = content["_meta"]?.objectValue
        let updateMetadata = update["_meta"]?.objectValue
        return contentMetadata?["hostTurn"]?.boolValue == true
            || contentMetadata?["host_turn"]?.boolValue == true
            || updateMetadata?["hostTurn"]?.boolValue == true
            || updateMetadata?["host_turn"]?.boolValue == true
    }

    private func encodeToolArguments(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(value),
              let result = String(data: encoded, encoding: .utf8) else { return "" }
        return result
    }

    private func toolResultText(_ update: [String: JSONValue]) -> String {
        let text = update["content"]?.arrayValue?.compactMap { block in
            let object = block.objectValue
            let nested = object?["content"]?.objectValue
            guard nested?["type"]?.stringValue == "text" else { return nil }
            return nested?["text"]?.stringValue
        }.joined() ?? ""
        if !text.isEmpty { return text }
        guard let output = update["rawOutput"] ?? update["raw_output"] else { return "" }
        return encodeToolArguments(output)
    }
}
