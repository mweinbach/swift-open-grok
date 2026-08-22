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
            usageSources: usageSources,
            sessionUsage: await conversationHistory?.usageSnapshot
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
        if let usage = report.sessionUsage {
            let provider = await activeWaveEUsageProvider()
            let authoritative = report.sessionUsageIsAuthoritative
            let status: String?
            if usage.incomplete {
                status = "incomplete provider accounting"
            } else if usage.totals.costIsPartial {
                status = "provider-reported tokens; cost incomplete"
            } else {
                status = nil
            }

            if report.hasMeasuredSessionUsage || !usage.incomplete {
                sections.append(PagerUsageSection(
                    provider: provider,
                    used: Double(usage.totals.totalTokens),
                    unit: "session tokens",
                    resetDescription: status,
                    isAuthoritative: authoritative
                ))
                for bucket in [
                    (usage.totals.inputTokens, "input tokens"),
                    (usage.totals.outputTokens, "output tokens"),
                    (usage.totals.cachedReadTokens, "cache-read input tokens"),
                    (usage.totals.cacheCreationTokens, "cache-creation input tokens"),
                ] {
                    sections.append(PagerUsageSection(
                        provider: provider,
                        used: Double(bucket.0),
                        unit: bucket.1,
                        isAuthoritative: authoritative
                    ))
                }
            } else {
                sections.append(PagerUsageSection(
                    provider: provider,
                    used: Double(usage.totals.modelCalls),
                    unit: "model calls; token usage unavailable",
                    resetDescription: status,
                    isAuthoritative: false
                ))
            }

            if let ticks = usage.trustedCostUsdTicks {
                sections.append(PagerUsageSection(
                    provider: provider,
                    used: Double(ticks) / 10_000_000_000,
                    unit: "USD",
                    resetDescription: "\(ticks) exact USD ticks",
                    isAuthoritative: true
                ))
            }

            for model in usage.models {
                let modelProvider = modelCatalog.first(where: {
                    $0.id == model.modelID || $0.name == model.modelID
                }).flatMap { entry -> PagerUsageProvider? in
                    switch entry.providerID.lowercased() {
                    case "xai": return .xai
                    case "codex": return .codex
                    case "antigravity": return .antigravity
                    default: return nil
                    }
                } ?? provider
                sections.append(PagerUsageSection(
                    provider: modelProvider,
                    used: Double(model.totals.totalTokens),
                    unit: "\(model.modelID) tokens",
                    resetDescription:
                        "\(model.totals.inputTokens) input, \(model.totals.outputTokens) output, "
                            + "\(model.totals.cachedReadTokens) cache read, "
                            + "\(model.totals.cacheCreationTokens) cache creation",
                    isAuthoritative: authoritative
                ))
            }
        } else if sections.isEmpty {
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
