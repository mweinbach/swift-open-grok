import Foundation
import OpenGrokCompaction
import OpenGrokPagerRender
import OpenGrokProviderSession
import OpenGrokSamplingTypes

extension LiveInteractiveControllerRenderer {
    func refreshUsageReport(
        context: ContextUsage?,
        items: [ConversationItem]
    ) async -> LiveUsageReport {
        let report = await LiveUsageComposition.report(
            context: context,
            items: items,
            usageSources: usageSources
        )
        creditStatus = report.quotaWindows.compactMap { window -> PagerCreditStatus? in
            guard let provider = waveEUsageProvider(window.provider),
                  let limit = window.limit,
                  limit > 0 else { return nil }
            return PagerCreditStatus(
                provider: provider,
                used: Double(window.used),
                limit: Double(limit)
            )
        }.first
        return report
    }

    func waveEUsageBlock(_ report: LiveUsageReport) async -> PagerUsageBlock {
        var sections = report.quotaWindows.compactMap { window -> PagerUsageSection? in
            guard let provider = waveEUsageProvider(window.provider) else { return nil }
            return PagerUsageSection(
                provider: provider,
                used: Double(window.used),
                limit: window.limit.map(Double.init),
                unit: "units",
                resetDescription: window.resetAt.map {
                    "resets \(LiveSessionsComposition.timestamp($0))"
                },
                isAuthoritative: true
            )
        }
        sections.append(contentsOf: report.antigravityQuota?.buckets.map { bucket in
            PagerUsageSection(
                provider: .antigravity,
                used: max(0, min(1, 1 - bucket.remainingFraction)) * 100,
                limit: 100,
                unit: "%",
                resetDescription: bucket.resetTime.map { "resets \($0)" },
                isAuthoritative: true
            )
        } ?? [])
        if sections.isEmpty {
            sections.append(PagerUsageSection(
                provider: await activeWaveEUsageProvider(),
                used: Double(report.estimatedSessionTokens),
                limit: nil,
                unit: "tokens",
                isAuthoritative: false
            ))
        }
        return PagerUsageBlock(id: "usage", sections: sections)
    }

    private func activeWaveEUsageProvider() async -> PagerUsageProvider {
        if modelName.localizedCaseInsensitiveContains("antigravity") {
            return .antigravity
        }
        guard let provider = await modelSwitch?.snapshot().provider else { return .xai }
        return waveEUsageProvider(provider) ?? .xai
    }

    private func waveEUsageProvider(_ provider: ModelProvider) -> PagerUsageProvider? {
        switch provider {
        case .xai: return .xai
        case .codex: return .codex
        case .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer, .zai:
            return nil
        }
    }
}
