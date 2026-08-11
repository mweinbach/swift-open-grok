import Foundation

/// Check if text contains at least one markdown header (`#` or `##`).
func hasMarkdownHeaders(_ text: String) -> Bool {
    text.contains("## ") || text.contains("# ")
}

/// Check if the response matches the NO_REPLY convention.
///
/// Strips all non-alphanumeric characters, lowercases, and checks if the
/// remainder is exactly `"noreply"`.
func isNoReply(_ text: String) -> Bool {
    let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber }
    return normalized == "noreply"
}
