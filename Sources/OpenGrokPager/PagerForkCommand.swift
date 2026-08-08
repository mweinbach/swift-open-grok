// PagerForkCommand.swift
//
// The `/fork` argument grammar, ported verbatim from
// `slash/commands/fork.rs:50-96` (`parse_fork_args`). It lives outside the
// controller because the grammar is whitespace-sensitive: the command
// tokenizer's split-and-unquote `arguments` are NOT its input — the
// controller hands it the raw tail after the command token, the same slice
// upstream's `parse_invocation` (slash/mod.rs:1236-1258) produces.

import Foundation

/// A `/fork` grammar rejection. The message is upstream's error copy,
/// byte-identical (`Err(String)`, fork.rs:50).
public struct PagerForkParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Parsed arguments for the `/fork` slash command (`ForkArgs`,
/// fork.rs:21-32).
public struct PagerForkArguments: Sendable, Equatable {
    /// `nil`     -> upstream opens the worktree question modal every time.
    /// `true`    -> force worktree, skipping the modal.
    /// `false`   -> force no-worktree, skipping the modal.
    public var worktreeOverride: Bool?
    /// Optional first prompt for the new session. `nil` when the user
    /// invoked `/fork` (with or without flags) but no directive text.
    public var directive: String?

    public init(worktreeOverride: Bool? = nil, directive: String? = nil) {
        self.worktreeOverride = worktreeOverride
        self.directive = directive
    }

    /// `parse_fork_args` (fork.rs:50-96), byte-for-byte including error copy.
    ///
    /// Recognised flags appear at the start; everything after the last flag
    /// is the directive. Unknown flags are deliberately treated as the start
    /// of the directive (so `/fork --foo bar` becomes a directive `--foo
    /// bar`) — the parser is conservative because the args are user-typed
    /// text and we do not want to reject directives that happen to begin
    /// with `--`.
    public static func parse(_ args: String) -> Result<PagerForkArguments, PagerForkParseError> {
        var worktreeOverride: Bool?
        var rest = Substring(args).drop(while: \.isWhitespace)

        loop: while !rest.isEmpty {
            // Rust's `split_once(char::is_whitespace)`: the flag token, then
            // the remainder after exactly one whitespace character.
            let flag: Substring
            let after: Substring
            if let boundary = rest.firstIndex(where: \.isWhitespace) {
                flag = rest[..<boundary]
                after = rest[rest.index(after: boundary)...]
            } else {
                flag = rest
                after = Substring("")
            }
            switch flag {
            case "--worktree":
                if worktreeOverride == false {
                    return .failure(PagerForkParseError("--worktree and --no-worktree are mutually exclusive"))
                }
                if worktreeOverride == true {
                    return .failure(PagerForkParseError("--worktree specified twice"))
                }
                worktreeOverride = true
                rest = after.drop(while: \.isWhitespace)
            case "--no-worktree":
                if worktreeOverride == true {
                    return .failure(PagerForkParseError("--worktree and --no-worktree are mutually exclusive"))
                }
                if worktreeOverride == false {
                    return .failure(PagerForkParseError("--no-worktree specified twice"))
                }
                worktreeOverride = false
                rest = after.drop(while: \.isWhitespace)
            case "--at":
                return .failure(PagerForkParseError("--at is not supported in this version"))
            default:
                break loop
            }
        }

        return .success(PagerForkArguments(
            worktreeOverride: worktreeOverride,
            directive: rest.isEmpty ? nil : String(rest)
        ))
    }
}
