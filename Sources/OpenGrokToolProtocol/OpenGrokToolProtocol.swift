// OpenGrokToolProtocol.swift
//
// Open Grok — Swift port of `xai-tool-protocol` (crates/common/xai-tool-protocol).
//
// Wire-protocol types for the computer hub: identifier newtypes, registration
// payloads, capabilities, hook events, handshake messages, the JSON-RPC 2.0
// envelope and method catalog, `ToolErrorWire` / `ToolOutputWire` /
// `WireToolNotification`, every method's params/result payload, and the
// numeric ↔ string error-code mapping.
//
// Rust crate mapping: crates/common/xai-tool-protocol. See CRATE_MAP.md (W1-S1 / R01).

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

// Re-export surface is the module itself; all public types live in sibling files.
