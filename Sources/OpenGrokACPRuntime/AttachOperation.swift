// AttachOperation.swift
//
// Attach operation taxonomy and active model reuse detection on session resume.
// Ported from `crates/codegen/xai-grok-shell/src/agent/mvp_agent/session_setup.rs`.

import Foundation
import OpenGrokACP

/// What the two attach methods (load vs resume) do differently.
public enum AttachOperation: Sendable, Equatable {
    case load
    case resume
}

/// The provenance of the selected model during session attach.
public enum LoadModelSelectionOrigin: Sendable, Equatable {
    case persistedIdentity
    case explicitOverride
    case unavailableFallback
}

/// Determine whether session/resume reattaches to an active resident model
/// turn without issuing a mid-turn model mutation.
public func resumeReusesActiveModel(
    operation: AttachOperation,
    requestedModelID: String?,
    selectionOrigin: LoadModelSelectionOrigin,
    liveModelID: String?,
    resolvedModelID: String,
    runningPromptID: String?
) -> Bool {
    operation == .resume
        && requestedModelID == nil
        && selectionOrigin == .persistedIdentity
        && liveModelID == resolvedModelID
        && runningPromptID != nil
}
