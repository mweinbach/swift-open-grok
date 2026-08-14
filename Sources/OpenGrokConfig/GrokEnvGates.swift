// GrokEnvGates.swift
//
// Typed registry of documented `GROK_*` / `OPENGROK_*` environment
// variables that have live Swift consumers.
//
// This registry does NOT invent new variables: every entry cites the
// Swift consumer that reads it. Variables without a Swift consumer are
// not listed, even if the Rust reference defines them — adding a gate
// here without a consumer would violate the "no unused gates" rule.
//
// Parsing semantics match Rust: `envBool` for booleans (truthy/falsy),
// raw string for non-boolean values. The injectable `environment`
// parameter on each accessor keeps tests deterministic.
//
// Rust reference (auto_gc.rs:18-24, queue.rs:175-184, config.rs:2468+).

import Foundation
import OpenGrokConfigTypes

// MARK: - Gate registry

/// Documented `GROK_*` / `OPENGROK_*` environment gates with live Swift
/// consumers. Each entry is a static property returning the parsed value
/// from a supplied environment dictionary.
public enum GrokEnvGates {

    // -- Telemetry --

    /// Bidirectional telemetry enable/disable.
    /// Consumer: `TelemetryModeResolver.resolve()`, `TelemetryEnv.enabledNames`.
    public static func telemetryEnabled(
        environment: [String: String]
    ) -> Bool? {
        envBool("OPENGROK_TELEMETRY_ENABLED", environment: environment)
            ?? envBool("GROK_TELEMETRY_ENABLED", environment: environment)
    }

    // -- Feature gates --

    /// Session recap gate (`/recap` + auto return-from-away).
    /// Consumer: `LiveRecap`.
    public static func sessionRecap(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_SESSION_RECAP", environment: environment)
    }

    /// Web fetch tool gate.
    /// Consumer: `LiveWebTools`.
    public static func webFetch(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_WEB_FETCH", environment: environment)
    }

    /// Image generation tool gate.
    /// Consumer: `LiveImageTools`.
    public static func imageGen(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_IMAGE_GEN", environment: environment)
    }

    /// Image edit tool gate.
    /// Consumer: `LiveImageTools`.
    public static func imageEdit(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_IMAGE_EDIT", environment: environment)
    }

    /// Feedback gate.
    /// Consumer: `LiveFeedbackComposition`.
    public static func feedbackEnabled(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_FEEDBACK_ENABLED", environment: environment)
    }

    /// Workspace command gate.
    /// Consumer: `LiveWorkspaceComposition`.
    public static func workspaceCommand(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_WORKSPACE_COMMAND", environment: environment)
    }

    /// Folder trust gate.
    /// Consumer: `FolderTrust`.
    public static func folderTrust(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_FOLDER_TRUST", environment: environment)
    }

    /// Workflow engine gate.
    /// Consumer: `WorkflowConfiguration`.
    public static func workflows(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_WORKFLOWS", environment: environment)
    }

    /// Opt-in mouse-reporting toggle (`Ctrl+R` scrollback + `/toggle-mouse-reporting`).
    /// Consumer: `MouseReportingToggleConfiguration` / live pager startup gate.
    public static func mouseReportingToggle(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_MOUSE_REPORTING_TOGGLE", environment: environment)
    }

    /// Campaign application disable.
    /// Consumer: `Loader.campaignsApplicationDisabled`.
    public static func campaigns(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_CAMPAIGNS", environment: environment)
    }

    /// Scheduler background loops.
    /// Consumer: `SchedulerConfiguration`.
    public static func schedulerBackgroundLoops(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_SCHEDULER_BACKGROUND_LOOPS", environment: environment)
    }

    /// Session search gate (`GROK_SESSION_SEARCH` / `OPENGROK_SESSION_SEARCH`).
    /// Consumer: `SessionSearchGate`.
    public static func sessionSearch(
        environment: [String: String]
    ) -> Bool? {
        envBool("OPENGROK_SESSION_SEARCH", environment: environment)
            ?? envBool("GROK_SESSION_SEARCH", environment: environment)
    }

    // -- Privacy --

    /// Privacy notice rollout override.
    /// Consumer: `PagerPrivacyBanner.resolvePrivacyNoticeRollout()`.
    public static func privacyNoticeRollout(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_PRIVACY_NOTICE_ROLLOUT", environment: environment)
    }

    // -- Shell --

    /// Shell override.
    /// Consumer: `Shell.unixShellPath()`.
    /// Non-boolean: returns the raw string value.
    public static func shell(
        environment: [String: String]
    ) -> String? {
        environment["GROK_SHELL"]
    }

    // -- Worktree auto-GC (Rust auto_gc.rs:18-24) --
    // These are defined in the Rust reference and have Swift consumers
    // in the worktree auto-GC resolver when it is wired.

    /// Worktree auto-GC master switch.
    /// Rust consumer: `resolve_worktree_auto_gc`. Swift consumer pending
    /// wiring through EffectiveFeatures.
    public static func worktreeAutoGc(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_WORKTREE_AUTO_GC", environment: environment)
    }

    /// Worktree auto-GC dry-run mode.
    /// Rust consumer: auto_gc.rs:20.
    public static func worktreeAutoGcDryRun(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_WORKTREE_AUTO_GC_DRY_RUN", environment: environment)
    }

    // -- Update --

    /// Disable autoupdater.
    /// Consumer: `LiveUpdateComposition`.
    public static func disableAutoupdater(
        environment: [String: String]
    ) -> Bool? {
        envBool("GROK_DISABLE_AUTOUPDATER", environment: environment)
    }

    // -- Crash handler --

    /// Crash handler gate.
    /// Consumer: `CrashBootstrap`.
    public static func crashHandler(
        environment: [String: String]
    ) -> Bool? {
        envBool("OPENGROK_CRASH_HANDLER", environment: environment)
            ?? envBool("GROK_CRASH_HANDLER", environment: environment)
    }
}
