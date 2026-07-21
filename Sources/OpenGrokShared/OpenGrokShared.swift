// OpenGrokShared.swift
//
// Shared utilities used by both `xai-grok-shell` and its downstream clients
// (e.g. `xai-grok-pager-render`, `xai-grok-tools`). This Swift target sits
// upstream of most Open Grok targets so it must never depend on them.
//
// Contents:
//   * Stable Sendable Codable identifiers (SessionID, TurnID, ToolCallID,
//    TaskID, WorktreeID, ModelID, RequestID, HunkID) — see Identifiers.swift.
//   * JSONValue and unknown-field retention utilities — see JSONValue.swift.
//   * ErrorEnvelope with machine code, user message, retryability, and
//    structured details — see ErrorEnvelope.swift.
//   * SessionInfo and directory resolution protocol — see SessionInfo.swift.
//   * Pure placeholder image parsing/validation — see PlaceholderImages.swift.
//   * UI configuration types (UiConfig, ToolModePreference, ContextualHints,
//    DisplayRefreshSettings) — see UIConfig.swift.
//   * Clipboard value types and protocol — see Clipboard.swift.
//   * Stderr locking protocol — see Stderr.swift.
//
// Rust crate mapping: xai-grok-shared (crates/codegen/xai-grok-shared).
// See CRATE_MAP.md and PORT_PLAN.md (W0-S4).

import Foundation
import OpenGrokCLIChatProxyTypes

// Re-export shared feedback wire types used by downstream crates
// (e.g. xai-grok-pager-render), mirroring the Rust
// `pub use prod_mc_cli_chat_proxy_types::feedback_types::FeedbackTerminalInfo;`
// in `xai-grok-shared/src/session/mod.rs`. Downstream consumers can import
// `FeedbackTerminalInfo` from `OpenGrokShared` directly without importing
// `OpenGrokCLIChatProxyTypes`, preserving the Rust-compatible
// `OpenGrokShared` boundary.
public typealias FeedbackTerminalInfo = OpenGrokCLIChatProxyTypes.FeedbackTerminalInfo
