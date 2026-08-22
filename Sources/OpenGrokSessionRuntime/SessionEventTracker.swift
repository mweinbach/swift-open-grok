import Dispatch
import Foundation
import OpenGrokShared

/// Owns the per-turn state behind the append-only session event log.
///
/// Sampling callbacks and concurrent tool tasks enter through this actor so
/// every event has a single ordering and cancellation cannot publish a turn
/// terminal before its outstanding tool terminals.
public actor SessionEventTracker {
    public static let maximumActiveTools = 256

    public nonisolated let log: SessionEventLog

    private struct ActiveTool: Sendable {
        let name: String
        let startedAt: DispatchTime
        let source: SessionEventToolSource
    }

    private var nextTurnNumber: UInt64
    private var nextLoopIndex: UInt32 = 0
    private var tokenSeenInRound = false
    private var currentPhase: SessionEventPhase?
    private var turnIsActive = false
    private var activeTools: [String: ActiveTool] = [:]

    public init(log: SessionEventLog, initialTurnNumber: UInt64 = 0) {
        self.log = log
        self.nextTurnNumber = initialTurnNumber
    }

    @discardableResult
    public func beginTurn(
        sessionID: String,
        modelID: String,
        yoloMode: Bool,
        conversationMessageCount: Int,
        relationship: SessionEventRelationship = .primary,
        redirectKind: SessionEventRedirectKind? = nil
    ) -> Bool {
        if turnIsActive {
            finishActiveTools(outcome: .cancelled)
            _ = log.emit(.turnEnded(
                outcome: .cancelled,
                cancellationCategory: .midTurnAbort,
                cancellationContext: nil
            ))
        }

        let turnNumber = nextTurnNumber
        if nextTurnNumber < .max { nextTurnNumber += 1 }
        nextLoopIndex = 0
        tokenSeenInRound = false
        currentPhase = nil
        activeTools.removeAll(keepingCapacity: true)
        turnIsActive = true

        return log.emit(.turnStarted(
            sessionID: sessionID,
            turnNumber: turnNumber,
            modelID: modelID,
            yoloMode: yoloMode,
            conversationMessageCount: conversationMessageCount,
            relationship: relationship,
            redirectKind: redirectKind
        ))
    }

    @discardableResult
    public func beginSamplerRound() -> Bool {
        guard turnIsActive else { return false }
        let loopIndex = nextLoopIndex
        if nextLoopIndex < .max { nextLoopIndex += 1 }
        tokenSeenInRound = false
        currentPhase = nil
        let loopWritten = log.emit(.loopStarted(loopIndex))
        let phaseWritten = changePhase(.waitingForModel)
        return loopWritten && phaseWritten
    }

    @discardableResult
    public func noteToken(phase: SessionEventPhase) -> Bool {
        guard turnIsActive else { return false }
        var succeeded = true
        if !tokenSeenInRound {
            tokenSeenInRound = true
            succeeded = log.emit(.firstToken)
        }
        return changePhase(phase) && succeeded
    }

    @discardableResult
    public func changePhase(_ phase: SessionEventPhase) -> Bool {
        guard turnIsActive else { return false }
        guard currentPhase != phase else { return true }
        currentPhase = phase
        return log.emit(.phaseChanged(phase))
    }

    @discardableResult
    public func toolStarted(
        name: String,
        callID: String,
        source: SessionEventToolSource = .shell
    ) -> Bool {
        guard turnIsActive, activeTools[callID] == nil else { return false }
        guard activeTools.count < Self.maximumActiveTools else { return false }
        activeTools[callID] = ActiveTool(name: name, startedAt: .now(), source: source)
        let phaseWritten = changePhase(.toolExecution)
        return log.emit(.toolStarted(toolName: name)) && phaseWritten
    }

    @discardableResult
    public func toolCompleted(callID: String, outcome: SessionEventToolOutcome) -> Bool {
        guard turnIsActive, let active = activeTools.removeValue(forKey: callID) else {
            return false
        }
        return emitCompletion(callID: callID, active: active, outcome: outcome)
    }

    @discardableResult
    public func permissionRequested(toolName: String) -> Bool {
        guard turnIsActive else { return false }
        let phaseWritten = changePhase(.permissionPrompt)
        return log.emit(.permissionRequested(toolName: toolName)) && phaseWritten
    }

    @discardableResult
    public func permissionResolved(
        toolName: String,
        decision: SessionEventPermissionDecision,
        waitMilliseconds: UInt64
    ) -> Bool {
        guard turnIsActive else { return false }
        return log.emit(.permissionResolved(
            toolName: toolName,
            decision: decision,
            waitMilliseconds: waitMilliseconds
        ))
    }

    @discardableResult
    public func interjected(
        source: SessionEventInterjectionSource,
        imageCount: UInt32 = 0
    ) -> Bool {
        guard turnIsActive else { return false }
        return log.emit(.interjected(source: source, imageCount: imageCount))
    }

    @discardableResult
    public func emit(_ event: SessionEventLogEvent) -> Bool {
        log.emit(event)
    }

    @discardableResult
    public func endTurn(
        outcome: SessionEventTurnOutcome,
        cancellationCategory: SessionEventCancellationCategory? = nil,
        cancellationContext: JSONValue? = nil
    ) -> Bool {
        guard turnIsActive else { return false }
        let toolsWritten = finishActiveTools(outcome: .cancelled)
        turnIsActive = false
        currentPhase = nil
        let terminalWritten = log.emit(.turnEnded(
            outcome: outcome,
            cancellationCategory: cancellationCategory,
            cancellationContext: cancellationContext
        ))
        return terminalWritten && toolsWritten
    }

    @discardableResult
    private func finishActiveTools(outcome: SessionEventToolOutcome) -> Bool {
        let pending = activeTools.sorted { $0.key < $1.key }
        activeTools.removeAll(keepingCapacity: true)
        var succeeded = true
        for (callID, active) in pending {
            if !emitCompletion(callID: callID, active: active, outcome: outcome) {
                succeeded = false
            }
        }
        return succeeded
    }

    private func emitCompletion(
        callID: String,
        active: ActiveTool,
        outcome: SessionEventToolOutcome
    ) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let startedAt = active.startedAt.uptimeNanoseconds
        let elapsedNanoseconds = now >= startedAt ? now - startedAt : 0
        let total = elapsedNanoseconds / 1_000_000
        return log.emit(.toolCompleted(
            toolName: active.name,
            durationMilliseconds: total,
            outcome: outcome,
            toolCallID: callID,
            source: active.source
        ))
    }
}
