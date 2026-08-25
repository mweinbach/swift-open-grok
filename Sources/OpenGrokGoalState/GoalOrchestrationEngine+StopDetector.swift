import Foundation

/// Pinned Rust `goal_stop_detector.rs:39-224`: only the final paragraph can
/// signal a handoff, and every expression is anchored to a trimmed line.
public enum GoalPrematureStopDetector {
    private struct Pattern: @unchecked Sendable {
        let label: String
        let expression: NSRegularExpression

        init(_ label: String, _ source: String) {
            self.label = label
            do {
                expression = try NSRegularExpression(pattern: source)
            } catch {
                preconditionFailure("invalid pinned goal stop expression \(label): \(error)")
            }
        }

        func firstMatch(in line: String) -> NSTextCheckingResult? {
            expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            )
        }
    }

    private static let patterns: [Pattern] = [
        Pattern(
            "unable_to_proceed",
            #"^I (?:can(?:'?t|not)|am unable to) (?:proceed|continue|make (?:any )?progress|complete|fix this)\b"#
        ),
        Pattern("giving_up", #"^(?:Giving up|I(?:'m| am) giving up|The task is not actionable)\b"#),
        Pattern(
            "stopping_here",
            #"^(?:Stopping here|I've stopped here|Parked (?:the|this) branch|Paused here)(?:\.|,|;|$| for | —| -| until| pending| since| because)"#
        ),
        Pattern(
            "agents_in_flight",
            #"^(?:(?:\*\*)?[1-9]\d* (?:agent|cron|task|fork|job|worker|PR|check)s? (?:in flight|remaining|active|still (?:running|working)|pending|running|launched)\b|(?:Continuous )?(?:[Ll]oop|[Cc]rons?|[Bb]abysit) (?:active|healthy|continuing|running|will keep|continues)\b|Waiting for (?:the )?(?:agent|cron|task|fork|worker|job|remaining|them)s?\b|Agents? will report back\b|Waiting\.?$)"#
        ),
        Pattern(
            "check_back_later",
            #"^(?:I will|I'll|Will) (?:check back|re-?check|poll|look again|retry|re-?run|try again) (?:in\b|again\b|(?:when|once|after|until)\s+(\S+))"#
        ),
        Pattern("verdict_line", #"^VERDICT: (?:PASS|FAIL)\b"#),
        Pattern(
            "commit_push_pr",
            #"^(?:Pushed (?:to `|`[0-9a-f]{7,})|Committed as `?[0-9a-f]{7,}\b|Commit: `?[0-9a-f]{7,}\b|(?:Opened|Created) PR #?\d)"#
        ),
        Pattern("ready_for_review", #"^Ready (?:for review|to (?:upload|merge|ship|land))\b"#),
        Pattern(
            "please_deflection",
            #"^Please (?:start|run|provide|grant|export|add|install|configure|give me|paste|point me|set (?:the |up |`?[A-Z][A-Z0-9_]+\b))"#
        ),
    ]

    public static func matchedPattern(in text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
        guard let paragraph = paragraphs.reversed().first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }

        for rawLine in paragraph.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for pattern in patterns {
                guard let match = pattern.firstMatch(in: line) else { continue }
                if pattern.label == "check_back_later",
                   defersToUser(match: match, in: line) {
                    continue
                }
                return pattern.label
            }
        }
        return nil
    }

    private static func defersToUser(match: NSTextCheckingResult, in line: String) -> Bool {
        guard match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: line)
        else {
            return false
        }
        let token = line[range].lowercased()
        for pronoun in ["your", "you"] where token.hasPrefix(pronoun) {
            let remainder = token.dropFirst(pronoun.count)
            guard let scalar = remainder.unicodeScalars.first else { return true }
            let word = CharacterSet.alphanumerics.contains(scalar) || scalar.value == 95
            if !word { return true }
        }
        return false
    }
}
