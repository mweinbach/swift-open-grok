// OpenGrokComputerHubSDK.swift
//
// Tool-server and harness SDK (Swift port of `xai-computer-hub-sdk`).
//
// Shared substrate: connection pool, cancel-on-drop, cancel registry,
// demux, auth credentials, ToolHarness for local + remote dispatch, and the
// production WebSocket transport used by live workspace exposure.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime

/// Re-export workspace-unavailable detection for SDK-only consumers.
public func isWorkspaceUnavailable(_ err: ToolError) -> Bool {
    OpenGrokComputerHubCore.isWorkspaceUnavailable(err)
}

/// Re-export wire decode helpers used by harness remote paths.
public func decodeCallResult(
    toolId: ToolId,
    value: JSONValue
) -> Result<TypedToolOutput, ToolError> {
    OpenGrokComputerHubCore.decodeCallResult(toolId: toolId, value: value)
}

public func toolErrorFromWire(_ wire: ToolErrorWire) -> ToolError {
    OpenGrokComputerHubCore.toolErrorFromWire(wire)
}
