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

    private static func severityLabel(_ severity: Int?) -> String {
        switch severity {
        case 1: return "error"
        case 2: return "warning"
        case 3: return "info"
        case 4: return "hint"
        default: return "diagnostic"
        }
    }
}
