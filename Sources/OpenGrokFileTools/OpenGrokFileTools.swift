// OpenGrokFileTools.swift
//
// Open Grok — Swift port of `xai-grok-tools` file/edit/search tools
// (read_file, list_dir, grep, glob, search_replace, apply_patch, hashline,
// OpenCode edit/write, view_image). W5-S1 / R19.
//
// Execution/web/media tools are out of scope (W5-S2).
//
// Rust crate mapping: crates/codegen/xai-grok-tools implementations under
// grok_build/, codex/, opencode/, grok_build_hashline/, read_file/.

import Foundation
import OpenGrokToolRegistry

/// Default max lines returned by `read_file` (parity with Rust `MAX_LINES_READ`).
public let maxLinesRead: Int = 1_000

/// Register the file-tool pack into the process-global pack list.
/// Safe to call multiple times; handlers replace catalog entries on finalize.
public func registerFileToolPack() {
    registerToolPack { builder in
        FileToolPack.install(into: &builder)
    }
}
