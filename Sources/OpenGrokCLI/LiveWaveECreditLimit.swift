import Foundation
import OpenGrokPagerRender

enum LiveWaveECreditLimitClassifier {
    static let accountURL = "https://grok.com?_s=usage"

    static func action(message: String, kind: String? = nil) -> PagerCreditLimitAction? {
        let normalized = ([kind, message].compactMap { $0 }
            .joined(separator: " "))
            .lowercased()

        if normalized.contains("purchase credits")
            || normalized.contains("buy more credits")
            || normalized.contains("prepaid credits")
            || normalized.contains("credits exhausted")
            || normalized.contains("weekly limit")
        {
            return .purchaseCredits
        }
        if normalized.contains("spending cap")
            || normalized.contains("spending limit")
            || normalized.contains("payg limit")
            || normalized.contains("pay-as-you-go limit")
        {
            return .increasePayAsYouGoLimit
        }
        if normalized.contains("enable payg")
            || normalized.contains("enable pay-as-you-go")
            || normalized.contains("payg is disabled")
            || normalized.contains("pay-as-you-go is disabled")
            || normalized.contains("free credits limit")
            || normalized.contains("credit limit reached")
        {
            return .enablePayAsYouGo
        }
        return nil
    }

    static func body(for action: PagerCreditLimitAction) -> String {
        switch action {
        case .enablePayAsYouGo:
            return "You can continue by enabling pay-as-you-go usage."
        case .increasePayAsYouGoLimit:
            return "You can continue by increasing your spending limit."
        case .purchaseCredits:
            return "You can continue by purchasing more credits."
        }
    }
}

extension LiveInteractiveControllerRenderer {
    func upsertCreditLimitCard(message: String, kind: String? = nil) {
        guard let action = LiveWaveECreditLimitClassifier.action(
            message: message,
            kind: kind
        ) else { return }
        let marker = currentTurnMarkerID ?? "turn-\(turnMarkerSequence)"
        let heading = message.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.upsertBlock(.creditLimit(PagerCreditLimitBlock(
            id: "\(marker)-credit-limit",
            action: action,
            message: [heading, LiveWaveECreditLimitClassifier.body(for: action)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n"),
            accountURL: LiveWaveECreditLimitClassifier.accountURL
        )))
    }
}
