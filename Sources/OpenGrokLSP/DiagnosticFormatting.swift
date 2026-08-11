import Foundation

public enum DiagnosticFormatting {
    public static func format(path: String, diagnostics: [LSPDiagnostic]) -> String {
        if diagnostics.isEmpty {
            return "No diagnostics for \(path)."
        }
        var lines: [String] = ["Diagnostics for \(path):"]
        for diagnostic in diagnostics {
            let severity = severityLabel(diagnostic.severity)
            let source = diagnostic.source.map { " [\($0)]" } ?? ""
            lines.append(
                "  \(diagnostic.line + 1):\(diagnostic.character + 1) \(severity)\(source): \(diagnostic.message)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// One drain line: `path:line:col: severity: message` (1-based positions).
    public static func drainLine(path: String, diagnostic: LSPDiagnostic) -> String {
        let severity = severityLabel(diagnostic.severity)
        let message = diagnostic.message
            .replacingOccurrences(of: "</lsp-diagnostics>", with: "&lt;/lsp-diagnostics&gt;")
            .replacingOccurrences(of: "</system-reminder>", with: "&lt;/system-reminder&gt;")
        return "\(path):\(diagnostic.line + 1):\(diagnostic.character + 1): \(severity): \(message)"
    }

    /// Wrap drain lines in the `<lsp-diagnostics>` envelope.
    public static func wrapDrainSummary(_ lines: [String]) -> String {
        "<lsp-diagnostics>\n\(lines.joined(separator: "\n"))\n</lsp-diagnostics>"
    }

    /// Errors and warnings only — hints/info are not drain-reportable.
    ///
    /// Rust reference: `manager.rs` `CollectedDiagnostics::append_file`.
    public static func reportable(_ diagnostics: [LSPDiagnostic]) -> [LSPDiagnostic] {
        diagnostics.filter { diagnostic in
            switch diagnostic.severity {
            case 1, 2: return true
            default: return false
            }
        }
        .sorted { lhs, rhs in
            let lhsError = lhs.severity == 1
            let rhsError = rhs.severity == 1
            if lhsError != rhsError { return lhsError && !rhsError }
            return lhs.line < rhs.line
        }
    }

    public static func severityLabel(_ severity: Int?) -> String {
        switch severity {
        case 1: return "error"
        case 2: return "warning"
        case 3: return "info"
        case 4: return "hint"
        default: return "diagnostic"
        }
    }
}
