// CodeModeTransportProjection.swift
//
// What the model sees versus what stays hidden.
//
// The rule is item 8 of the Code Mode compatibility contract
// (docs/code-mode-port.md): "`exec` and `wait` remain in model history but
// are transport details, not TUI tool cards. The UI shows only the decoded
// nested tools and their ordinary structured results; raw JavaScript, wait
// arguments, and cell transport output stay hidden during live streaming and
// session replay." The Rust engine enforces the model-facing half by
// construction — `RuntimeResponse.content_items` is the whole payload it
// hands back (service.rs:366), and cell ids, pending nested-call ids and
// stored values never appear in it.
//
// This file states that split explicitly so the presentation layer does not
// have to rediscover it.

import Foundation
import OpenGrokCodeModeProtocol

public enum CodeModeTransportProjection {
    /// The `exec` and `wait` names, which are transport plumbing rather
    /// than user-visible tools.
    public static func isTransportTool(_ toolName: ToolName) -> Bool {
        toolName.namespace == nil
            && (toolName.name == PUBLIC_TOOL_NAME || toolName.name == WAIT_TOOL_NAME)
    }

    /// Everything the model is allowed to see for one cell observation —
    /// exactly the response's content items, nothing more.
    public static func modelVisibleContent(
        _ response: RuntimeResponse
    ) -> [FunctionCallOutputContentItem] {
        response.contentItems
    }

    /// Whether a response should produce a user-visible tool card. It never
    /// should: the cards come from the nested tool calls the cell made,
    /// which the host dispatcher already renders.
    public static func producesUserVisibleCard(_ response: RuntimeResponse) -> Bool {
        false
    }

    /// The pieces the transport keeps to itself. Useful for asserting in
    /// tests that none of them leak into a rendered turn.
    public struct HiddenDetails: Sendable, Equatable {
        public var cellId: CellId
        public var pendingToolCallIds: [String]
        /// Present only on the pending-frontier path.
        public var isPendingFrontier: Bool
    }

    public static func hiddenDetails(_ response: RuntimeResponse) -> HiddenDetails {
        HiddenDetails(
            cellId: response.cellId,
            pendingToolCallIds: [],
            isPendingFrontier: false
        )
    }

    public static func hiddenDetails(_ outcome: ExecuteToPendingOutcome) -> HiddenDetails {
        switch outcome {
        case .pending(let cellId, _, let pendingToolCallIds):
            return HiddenDetails(
                cellId: cellId,
                pendingToolCallIds: pendingToolCallIds,
                isPendingFrontier: true
            )
        case .completed(let response):
            return hiddenDetails(response)
        }
    }
}
