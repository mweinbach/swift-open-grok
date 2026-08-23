import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes

/// One deployment decision for every surface capable of exposing conversation
/// content. The process latch can only tighten after initialization.
struct LiveSessionSearchPolicy: Sendable {
    let environment: [String: String]
    let document: TOMLValue?
    let requirements: [TOMLValue]?
    let remote: Bool?
    let gate: SessionSearchGate

    init(
        environment: [String: String],
        document: TOMLValue? = nil,
        requirements: [TOMLValue]? = nil,
        remote: Bool? = nil,
        gate: SessionSearchGate = .shared
    ) {
        self.environment = environment
        self.document = document
        self.requirements = requirements
        self.remote = remote
        self.gate = gate
    }

    @discardableResult
    func apply() -> Bool {
        gate.isIndexEnabled(
            environment: environment,
            resolved: resolveSessionSearchSetting(
                environment: environment,
                document: document,
                requirements: requirements,
                remote: remote
            )
        )
    }

    var disabledReason: String? {
        gate.sessionSearchTurnedOffBy()
    }
}
