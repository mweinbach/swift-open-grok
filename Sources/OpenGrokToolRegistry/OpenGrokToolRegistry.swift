// OpenGrokToolRegistry.swift
//
// Open Grok — Swift port of `xai-grok-tools` registry / finalization / bridge
// (crates/codegen/xai-grok-tools/src/registry, tool_taxonomy, versions, util/truncate,
// bridge). W5-S1 owns registry construction/finalization plus selection filters.
// Concrete file/edit tools live in `OpenGrokFileTools` and register via tool packs.
//
// Rust crate mapping: crates/codegen/xai-grok-tools (W5-S1 / R19). See CRATE_MAP.md.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

/// Default maximum output size (bytes) for tool results sent to the model.
/// 40 KB ≈ 10 000 tokens. Mirrors Rust `DEFAULT_TOOL_OUTPUT_BYTES`.
public let defaultToolOutputBytes: Int = 40_000

/// Default maximum output size (characters) for shell-style tool results.
/// 20 000 chars ≈ 5 000 tokens. Mirrors Rust `DEFAULT_TOOL_OUTPUT_CHARS`.
public let defaultToolOutputChars: Int = 20_000

/// Canonical `_meta` key for tool identity stamps (`x.ai/tool`).
public let toolMetaKey: String = "x.ai/tool"

/// Wire version for `_meta` payloads.
public let toolMetaVersion: UInt32 = 1

/// Maximum accepted `message` body size in bytes for agent mailbox tools (32 KB = 32,768 bytes).
/// Mirrors Rust `MAX_AGENT_MESSAGE_BYTES`.
public let defaultMailboxMessageByteLimit: Int = 32 * 1024

/// Default maximum lines returned by `read_file` (1,000 lines).
/// Mirrors Rust `MAX_LINES_READ`.
public let defaultMaxLinesRead: Int = 1_000

