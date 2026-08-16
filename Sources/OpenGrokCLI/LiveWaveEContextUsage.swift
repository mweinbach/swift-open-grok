import Foundation
import OpenGrokCompaction
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTokenEstimation

enum LiveWaveEContextUsage {
    static func block(
        usage: ContextUsage,
        items: [ConversationItem],
        tools: [ToolSpec]
    ) -> PagerContextBlock {
        let used = Int(clamping: usage.usedTokens)
        let total = Int(clamping: usage.contextWindow)
        let rawSystem = estimatedSystemTokens(items)
        let rawReasoning = estimatedReasoningTokens(items)
        let rawTools = estimatedToolTokens(tools)
        let fixed = rawSystem + rawReasoning + rawTools

        let system: Int
        let reasoning: Int
        let toolDefinitions: Int
        if fixed > used, fixed > 0 {
            let scale = Double(used) / Double(fixed)
            system = Int((Double(rawSystem) * scale).rounded(.down))
            reasoning = Int((Double(rawReasoning) * scale).rounded(.down))
            toolDefinitions = max(0, used - system - reasoning)
        } else {
            system = rawSystem
            reasoning = rawReasoning
            toolDefinitions = rawTools
        }
        let messages = max(0, used - system - reasoning - toolDefinitions)
        let free = max(0, total - used)

        return PagerContextBlock(
            id: "context-usage",
            totalTokens: total,
            rows: [
                PagerContextUsage(category: .system, tokens: system),
                PagerContextUsage(category: .messages, tokens: messages),
                PagerContextUsage(category: .reasoning, tokens: reasoning),
                PagerContextUsage(category: .toolDefinitions, tokens: toolDefinitions),
                PagerContextUsage(category: .free, tokens: free),
            ]
        )
    }

    private static func estimatedSystemTokens(_ items: [ConversationItem]) -> Int {
        Int(clamping: items.reduce(into: UInt64(0)) { total, item in
            switch item {
            case .system(let system):
                total &+= OpenGrokTokenEstimation.estimateTokens(system.content)
            case .user(let user) where user.syntheticReason != nil:
                for part in user.content {
                    if case .text(let text) = part {
                        total &+= OpenGrokTokenEstimation.estimateTokens(text)
                    }
                }
            default:
                break
            }
        })
    }

    private static func estimatedReasoningTokens(_ items: [ConversationItem]) -> Int {
        Int(clamping: items.reduce(into: UInt64(0)) { total, item in
            guard case .reasoning(let reasoning) = item else { return }
            if let data = try? JSONEncoder().encode(reasoning) {
                total &+= OpenGrokTokenEstimation.estimateTokens(String(decoding: data, as: UTF8.self))
            }
        })
    }

    private static func estimatedToolTokens(_ tools: [ToolSpec]) -> Int {
        guard let data = try? JSONEncoder().encode(tools) else { return 0 }
        return Int(clamping: OpenGrokTokenEstimation.estimateTokens(String(decoding: data, as: UTF8.self)))
    }
}
