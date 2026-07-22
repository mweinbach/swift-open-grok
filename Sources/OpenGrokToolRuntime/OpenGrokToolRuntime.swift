// OpenGrokToolRuntime.swift
//
// Open Grok — Swift port of `xai-tool-runtime` (crates/common/xai-tool-runtime).
//
// Unified runtime contract: `Tool` protocol, `ToolDispatch`, `ToolError`,
// `ToolNotification`, `ToolSearchIndex`, `ToolCallContext`, streaming
// helpers, and model-facing output extraction.
//
// Rust crate mapping: crates/common/xai-tool-runtime. See CRATE_MAP.md (W1-S1 / R01).

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolTypes
