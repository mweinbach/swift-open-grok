// OpenGrokComputerHubSDK.swift
//
// Tool-server and harness SDK (Swift port of `xai-computer-hub-sdk`).
//
// Shared substrate: connection pool, cancel-on-drop, auth credentials,
// and ToolHarness for local + remote dispatch. WebSocket wire transport
// remains a later integration concern; tests use channel-backed mocks.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokToolRuntime

/// Re-export workspace-unavailable detection for SDK-only consumers.
public func isWorkspaceUnavailable(_ err: ToolError) -> Bool {
    OpenGrokComputerHubCore.isWorkspaceUnavailable(err)
}
