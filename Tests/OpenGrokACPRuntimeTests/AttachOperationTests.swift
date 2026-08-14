// AttachOperationTests.swift
//
// Unit tests for active model reuse on session resume, matching upstream
// `session_resume_close_tests.rs`.

import Testing
import Foundation
@testable import OpenGrokACPRuntime

@Suite("AttachOperation and model reuse")
struct AttachOperationTests {
    @Test("only resume of the same active persisted model skips restore")
    func resumeReusesActivePersistedModel() {
        let liveModel = "grok-4.5"
        let otherModel = "replacement-model"
        let requestedModel = "grok-4.5"

        // 1. Resume + requested is nil + PersistedIdentity + matching live model + running prompt => TRUE
        #expect(
            resumeReusesActiveModel(
                operation: .resume,
                requestedModelID: nil,
                selectionOrigin: .persistedIdentity,
                liveModelID: liveModel,
                resolvedModelID: liveModel,
                runningPromptID: "turn-1"
            )
        )

        // 2. Load (not Resume) => FALSE
        #expect(
            !resumeReusesActiveModel(
                operation: .load,
                requestedModelID: nil,
                selectionOrigin: .persistedIdentity,
                liveModelID: liveModel,
                resolvedModelID: liveModel,
                runningPromptID: "turn-1"
            )
        )

        // 3. Requested model ID is explicitly provided => FALSE
        #expect(
            !resumeReusesActiveModel(
                operation: .resume,
                requestedModelID: requestedModel,
                selectionOrigin: .persistedIdentity,
                liveModelID: liveModel,
                resolvedModelID: liveModel,
                runningPromptID: "turn-1"
            )
        )

        // 4. Selection origin is unavailable fallback => FALSE
        #expect(
            !resumeReusesActiveModel(
                operation: .resume,
                requestedModelID: nil,
                selectionOrigin: .unavailableFallback,
                liveModelID: liveModel,
                resolvedModelID: liveModel,
                runningPromptID: "turn-1"
            )
        )

        // 5. Live model does not match resolved model => FALSE
        #expect(
            !resumeReusesActiveModel(
                operation: .resume,
                requestedModelID: nil,
                selectionOrigin: .persistedIdentity,
                liveModelID: liveModel,
                resolvedModelID: otherModel,
                runningPromptID: "turn-1"
            )
        )

        // 6. Running prompt ID is nil (no live turn in progress) => FALSE
        #expect(
            !resumeReusesActiveModel(
                operation: .resume,
                requestedModelID: nil,
                selectionOrigin: .persistedIdentity,
                liveModelID: liveModel,
                resolvedModelID: liveModel,
                runningPromptID: nil
            )
        )
    }
}
