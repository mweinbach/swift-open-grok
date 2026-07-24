// PlanMode.swift
//
// Session plan-mode tracker used by the permission prepare pipeline.
// The real plan lifecycle lives in the shell session; this is the
// workspace-owned security seam so plan-edit gate and plan-file
// auto-approval can run before `PermissionHandle.request`.

import Foundation
import OpenGrokPaths

/// Plan mode activity for the edit gate.
public enum PlanModeState: String, Sendable, Equatable, Codable {
    case inactive
    case active
}

/// Lightweight plan tracker. YOLO / always-approve does **not** bypass the
/// plan-mode edit gate when this is active.
public struct PlanModeTracker: Sendable, Equatable {
    public private(set) var state: PlanModeState
    /// Absolute (or workspace-relative) path of the session plan file.
    public private(set) var planFilePath: String
    /// Session directory used to resolve `plan.md` when only a basename is given.
    public var sessionDirectory: String?

    public init(
        state: PlanModeState = .inactive,
        planFilePath: String = "plan.md",
        sessionDirectory: String? = nil
    ) {
        self.state = state
        self.planFilePath = planFilePath
        self.sessionDirectory = sessionDirectory
    }

    public var isActive: Bool { state == .active }

    public mutating func enter(planFilePath: String? = nil, sessionDirectory: String? = nil) {
        state = .active
        if let planFilePath { self.planFilePath = planFilePath }
        if let sessionDirectory { self.sessionDirectory = sessionDirectory }
    }

    public mutating func exit() {
        state = .inactive
    }

    /// Canonical absolute plan-file path when resolvable.
    public func resolvedPlanFilePath() -> String {
        if planFilePath.hasPrefix("/") {
            return normalizeLexically(planFilePath)
        }
        if let sessionDirectory {
            return normalizeLexically(
                (sessionDirectory as NSString).appendingPathComponent(planFilePath)
            )
        }
        return normalizeLexically(planFilePath)
    }

    /// Whether an edit path targets the session plan file (auto-approve candidate).
    public func shouldAutoApproveEdit(_ path: String) -> Bool {
        guard isActive else { return false }
        return pathsReferToSameFile(path, resolvedPlanFilePath())
    }
}

/// Outcome of the plan-mode edit gate.
public enum PlanEditGate: Sendable, Equatable {
    case allow
    /// Active plan mode + non-plan edit (or opaque apply_patch).
    case rejectNonPlanFile
}

/// Hard gate: when plan mode is Active, only edits to the session plan file
/// are allowed. Bash / read / MCP / web are **not** gated here.
///
/// `applyPatchLabel` is always rejected when active because targets are
/// unknown until parse (parity with shell `plan_mode_edit_gate`).
public func planModeEditGate(
    tracker: PlanModeTracker,
    access: AccessKind,
    applyPatchLabel: Bool = false
) -> PlanEditGate {
    guard tracker.isActive else { return .allow }
    if applyPatchLabel {
        // Only allow when caller already proved every hunk is the plan file.
        return .rejectNonPlanFile
    }
    switch access {
    case .edit(let path):
        if tracker.shouldAutoApproveEdit(path) {
            return .allow
        }
        return .rejectNonPlanFile
    default:
        return .allow
    }
}

/// Lexical same-file compare: basename + normalized parent.
func pathsReferToSameFile(_ a: String, _ b: String) -> Bool {
    let na = normalizeLexically(a)
    let nb = normalizeLexically(b)
    if na == nb { return true }
    // Compare last two components (parent + file) for relative vs absolute mixes.
    let aName = (na as NSString).lastPathComponent
    let bName = (nb as NSString).lastPathComponent
    guard aName == bName, !aName.isEmpty else { return false }
    let aParent = normalizeLexically((na as NSString).deletingLastPathComponent)
    let bParent = normalizeLexically((nb as NSString).deletingLastPathComponent)
    if aParent == bParent { return true }
    // Relative plan.md vs absolute …/plan.md: accept basename-only plan paths.
    if !a.hasPrefix("/") || !b.hasPrefix("/") {
        return aName == bName && (aName == "plan.md" || a.hasSuffix("/plan.md") || b.hasSuffix("/plan.md"))
    }
    return false
}
