// OpenGrokComputerHubCore.swift
//
// xAI Computer Hub — transport + registry + resolver core
// (Swift port of `xai-computer-hub-core`).
//
// Modules:
//   * Transport / Principal / capability admission
//   * CompoundResolver (local-shadows-remote) + InnerDispatch
//   * LocalTransport / RemoteTransport / ConnectionClient
//   * Wire codec: decodeCallResult, toolErrorFromWire, workspace_unavailable

import Foundation
