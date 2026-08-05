// RhaiLimits.swift
//
// Port of the constants in crates/codegen/xai-workflow/src/lib.rs:8-17. These
// are the caps the engine, the meta validator, and the dry-run validator all
// enforce; they are re-declared with a `Rhai` prefix so the values stay pinned
// to the Rust source even though this target already exports same-valued
// constants under the older `maxWorkflow*` names.

import Foundation

/// lib.rs:8
public let rhaiMaxWorkflowNameLength = 64
/// lib.rs:9
public let rhaiMaxWorkflowDescriptionLength = 1_024
/// lib.rs:10
public let rhaiMaxWorkflowWhenToUseLength = 2_048
/// lib.rs:11
public let rhaiMaxWorkflowPhases = 64
/// lib.rs:12
public let rhaiMaxPhaseTitleLength = 128
/// lib.rs:13
public let rhaiMaxPhaseDetailLength = 1_024
/// lib.rs:14 — the most agents one `parallel()` call may fan out to.
public let rhaiMaxParallel = 1_024
/// lib.rs:15
public let rhaiDefaultAgentBudget: UInt64 = 128
/// lib.rs:16
public let rhaiMaxAgentBudget: UInt64 = 1_024
/// lib.rs:17 — the most result-bearing host calls one run may make. Also the
/// journal's entry cap, since every such call records exactly one entry.
public let rhaiMaxHostCalls: UInt64 = 10_000
