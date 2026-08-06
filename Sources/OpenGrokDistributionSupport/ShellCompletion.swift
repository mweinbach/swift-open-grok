// ShellCompletion.swift
//
// Completions packaging.
//
// IMPORTANT — scope. The Rust reference at `9ed09e2a` does NOT generate or
// publish shell completions: neither `scripts/build-macos-release.sh` nor
// `scripts/build-windows-release.ps1` stages a completion file, `dist/` holds
// none, and no crate contains a clap completion generator. Completions are a
// PORT_PLAN.md W11-S1 acceptance requirement ("Bash, zsh, fish, and PowerShell
// completions are generated from the same CLI definition") with no upstream
// implementation to port.
//
// So this file deliberately stops at packaging: the shell vocabulary, the
// conventional per-shell filename, and the conventional install location. It
// does not invent a generator, and the completion assets are NOT part of
// `ReleaseArtifactLayout.referenceAssetNames` — a release-parity check against
// upstream must not expect them.

import Foundation
import OpenGrokBuildSupport

/// A shell the port packages completions for.
public enum ShellCompletion: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case bash
    case zsh
    case fish
    case powershell

    public var description: String { rawValue }

    /// The conventional completion filename for `open-grok` in this shell.
    ///
    /// These are the shells' own conventions, not a reference artifact:
    /// bash and fish use the command name plus the shell's extension, zsh uses
    /// the `_command` autoload convention, PowerShell ships a `.ps1` module.
    public var fileName: String {
        let command = OpenGrokBranding.executableName
        switch self {
        case .bash: return "\(command).bash"
        case .zsh: return "_\(command)"
        case .fish: return "\(command).fish"
        case .powershell: return "\(command).ps1"
        }
    }

    /// The directory, relative to a completions root, this file belongs in.
    public var directoryName: String { rawValue }

    /// The path of this completion inside a packaged completions tree.
    public var packagedPath: String { "completions/\(directoryName)/\(fileName)" }
}

/// A completions bundle staged alongside the release artifacts.
public struct CompletionsPackage: Sendable, Hashable {
    /// Generated completion text, keyed by shell.
    public let scripts: [ShellCompletion: String]

    public init(scripts: [ShellCompletion: String]) {
        self.scripts = scripts
    }

    /// Every shell PORT_PLAN's W11-S1 acceptance requires.
    public static let requiredShells: [ShellCompletion] = ShellCompletion.allCases

    /// Shells that are required but missing from ``scripts``.
    public var missingShells: [ShellCompletion] {
        CompletionsPackage.requiredShells.filter { scripts[$0] == nil }
    }

    /// Shells present but with empty content — a generator that silently
    /// produced nothing is a packaging failure, not a valid completion.
    public var emptyShells: [ShellCompletion] {
        CompletionsPackage.requiredShells.filter { shell in
            guard let script = scripts[shell] else { return false }
            return script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether every required shell has non-empty completion text.
    public var isComplete: Bool { missingShells.isEmpty && emptyShells.isEmpty }

    /// The packaged paths this bundle would write, sorted for determinism.
    public var packagedPaths: [String] {
        scripts.keys.map(\.packagedPath).sorted()
    }
}
