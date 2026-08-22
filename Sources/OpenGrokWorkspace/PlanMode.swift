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
        if isAbsolutePath(planFilePath) {
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
        guard isActive, !path.isEmpty, !path.contains("\0") else { return false }
        let authorized = resolvedPlanFilePath()
        let candidate: String

        if isAbsolutePath(path) {
            candidate = path
        } else if isAbsolutePath(authorized) {
            guard let sessionDirectory, isAbsolutePath(sessionDirectory) else { return false }
            candidate = (sessionDirectory as NSString).appendingPathComponent(path)
        } else {
            candidate = path
        }

        guard pathsReferToSameFile(candidate, authorized) else { return false }
        if let sessionDirectory, isAbsolutePath(sessionDirectory), isAbsolutePath(authorized) {
            guard let rootIdentity = canonicalPlanFileIdentity(sessionDirectory),
                  let planIdentity = canonicalPlanFileIdentity(authorized),
                  containsPath(root: rootIdentity, candidate: planIdentity)
            else { return false }
        }
        return true
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

/// Exact canonical plan identity; relative and absolute spellings never mix.
func pathsReferToSameFile(_ a: String, _ b: String) -> Bool {
    guard !a.isEmpty, !b.isEmpty, !a.contains("\0"), !b.contains("\0") else {
        return false
    }
    guard isAbsolutePath(a) == isAbsolutePath(b) else { return false }
    if !isAbsolutePath(a) {
        return planPathComparisonKey(normalizeLexically(a))
            == planPathComparisonKey(normalizeLexically(b))
    }
    guard let first = canonicalPlanFileIdentity(a),
          let second = canonicalPlanFileIdentity(b)
    else { return false }
    return first == second
}

private func canonicalPlanFileIdentity(_ path: String) -> String? {
    guard isAbsolutePath(path), !path.contains("\0") else { return nil }
    var ancestor = path
    var missingComponents: [String] = []
    var remainingSymlinkResolutions = 64

    while !FileManager.default.fileExists(atPath: ancestor) {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor) {
            guard remainingSymlinkResolutions > 0 else { return nil }
            remainingSymlinkResolutions -= 1
            if isAbsolutePath(destination) {
                ancestor = destination
            } else {
                let parent = (ancestor as NSString).deletingLastPathComponent
                ancestor = (parent as NSString).appendingPathComponent(destination)
            }
            continue
        }
        let component = (ancestor as NSString).lastPathComponent
        let parent = (ancestor as NSString).deletingLastPathComponent
        guard !component.isEmpty, component != "..", parent != ancestor, !parent.isEmpty else {
            return nil
        }
        if component != "." {
            missingComponents.append(component)
        }
        ancestor = parent
    }

    #if os(Windows)
    var canonical = canonicalizePath(ancestor)
    #else
    guard let resolved = try? resolveCanonicalPath(URL(fileURLWithPath: ancestor)) else {
        return nil
    }
    var canonical = resolved.path
    #endif

    for component in missingComponents.reversed() {
        canonical = (canonical as NSString).appendingPathComponent(component)
    }
    return planPathComparisonKey(normalizeLexically(canonical))
}

private func planPathComparisonKey(_ path: String) -> String {
    #if os(Windows)
    return path.replacingOccurrences(of: "\\", with: "/").lowercased()
    #else
    return path
    #endif
}
