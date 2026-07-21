// Branding.swift
//
// Canonical Open Grok identity constants. These are the single source of truth
// for the executable name, state directory, and the `OPENGROK_HOME` environment
// variable name. The behavior preserved from the Rust reference is:
//
//   * The public executable is always `open-grok`.
//   * Runtime/configuration state is isolated to `$OPENGROK_HOME` or, when that
//     is unset/empty, `~/.opengrok`. The legacy `~/.grok` path is NEVER read or
//     written by any Open Grok component.
//   * Project-local state lives under `.opengrok`.

import Foundation

/// Canonical Open Grok branding and path-policy constants.
public enum OpenGrokBranding {
    /// The public executable product name.
    public static let executableName = "open-grok"

    /// The human-facing product name.
    public static let productName = "Open Grok"

    /// The environment variable that overrides the state directory.
    public static let homeEnvironmentVariable = "OPENGROK_HOME"

    /// The fallback state directory name (relative to the user home directory).
    public static let fallbackStateDirectoryName = ".opengrok"

    /// The project-local state directory name.
    public static let projectStateDirectoryName = ".opengrok"

    /// The managed binary install location relative to `OPENGROK_HOME`.
    public static let managedBinarySubpath = "bin/open-grok"

    /// The legacy state directory name that must never be read or written.
    /// This constant exists so that path-resolution tests can assert rejection.
    public static let legacyForbiddenStateDirectoryName = ".grok"
}
