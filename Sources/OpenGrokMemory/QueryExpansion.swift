import Foundation

/// Code query token extractor and query expander.
///
/// Expands conversational and code search queries into constituent sub-tokens by:
/// - Splitting identifiers on camelCase transitions (`userProfileStore` -> `user`, `profile`, `store`)
/// - Splitting identifiers on snake_case / kebab-case transitions (`max_timeout_ms` -> `max`, `timeout`, `ms`)
/// - Identifying and preserving file extensions (`.swift`, `.rs`, `.json`, `.toml`)
/// - Stripping punctuation, numeric noise, and stop words
public struct QueryExpander: Sendable {

    /// Common programming and conversational stop words filtered during token extraction.
    public static let stopWords: Set<String> = [
        // Articles & determiners
        "a", "an", "the", "this", "that", "these", "those",
        // Pronouns
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "they", "him", "her", "its", "them", "us",
        // Common verbs
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did",
        "will", "would", "could", "should", "can", "may", "might",
        // Prepositions
        "in", "on", "at", "to", "for", "of", "with", "by", "from", "about", "into", "through",
        "during", "before", "after", "above", "below",
        // Conjunctions
        "and", "or", "but", "if", "then", "because", "as", "while", "when", "where", "what", "which", "who", "how", "why",
        // Vague references
        "thing", "things", "stuff", "something", "anything", "everything", "one", "some", "any", "all", "each", "every", "both", "few", "more",
        // Time references
        "yesterday", "today", "tomorrow", "earlier", "later", "recently", "now", "just", "already", "still", "yet",
        // Request words
        "please", "help", "find", "show", "get", "tell", "give", "make",
        // Common filler
        "not", "no", "yes", "also", "too", "very", "really", "here", "there", "so", "up", "out", "like", "than", "other", "only"
    ]

    /// Recognized file extensions in source code and configuration files.
    public static let knownFileExtensions: Set<String> = [
        "swift", "rs", "json", "toml", "yaml", "yml", "md", "ts", "js", "jsx", "tsx",
        "py", "go", "c", "cpp", "cc", "cxx", "h", "hpp", "hxx", "java", "kt", "kts",
        "sh", "bash", "zsh", "sql", "html", "htm", "css", "scss", "sass", "less",
        "proto", "protobuf", "xml", "graphql", "gql", "lock", "env", "txt", "csv",
        "rb", "php", "cs", "m", "mm", "scala", "r", "dart", "lua", "zig", "nim",
        "vue", "svelte", "rst", "ini", "cfg", "conf", "gradle", "properties"
    ]

    public init() {}

    /// Expands a search query by returning the original query along with deduplicated expanded terms and tokens.
    ///
    /// - Parameter query: The input query string.
    /// - Returns: An array containing the original query followed by extracted sub-tokens and terms.
    public func expand(query: String) -> [String] {
        Self.expand(query: query)
    }

    /// Expands a search query by returning the original query along with deduplicated expanded terms and tokens.
    ///
    /// - Parameter query: The input query string.
    /// - Returns: An array containing the original query followed by extracted sub-tokens and terms.
    public func expand(_ query: String) -> [String] {
        Self.expand(query: query)
    }

    /// Expands a search query by returning the original query along with deduplicated expanded terms and tokens.
    ///
    /// - Parameter query: The input query string.
    /// - Returns: An array containing the original query followed by extracted sub-tokens and terms.
    public static func expand(_ query: String) -> [String] {
        expand(query: query)
    }

    /// Expands a search query by returning the original query along with deduplicated expanded terms and tokens.
    ///
    /// - Parameter query: The input query string.
    /// - Returns: An array containing the original query followed by extracted sub-tokens and terms.
    public static func expand(query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [String] = [trimmed]
        var seen = Set<String>()
        seen.insert(trimmed.lowercased())

        let tokens = extractTokens(query)
        for token in tokens {
            let lower = token.lowercased()
            if seen.insert(lower).inserted {
                results.append(token)
            }
        }

        return results
    }

    /// Splits camelCase, PascalCase, or ACRONYMCase text into lowercased components.
    ///
    /// Examples:
    /// - `userProfileStore` -> `["user", "profile", "store"]`
    /// - `XMLParser` -> `["xml", "parser"]`
    /// - `JSONDecoder` -> `["json", "decoder"]`
    /// - `maxTimeoutMs` -> `["max", "timeout", "ms"]`
    public static func splitCamelCase(_ text: String) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        var words: [String] = []
        var currentWord = ""

        for i in 0..<characters.count {
            let char = characters[i]
            let isUpper = char.isUppercase

            if i > 0 {
                let prev = characters[i - 1]
                let prevIsUpper = prev.isUppercase
                let prevIsLower = prev.isLowercase
                let prevIsDigit = prev.isNumber

                // Transition 1: lowercase/digit to uppercase (e.g. userProfile -> user | Profile)
                if (prevIsLower || prevIsDigit) && isUpper {
                    if !currentWord.isEmpty {
                        words.append(currentWord)
                        currentWord = ""
                    }
                }
                // Transition 2: acronym to word (e.g. XMLParser -> XML | Parser, JSONDecoder -> JSON | Decoder)
                else if prevIsUpper && isUpper && i + 1 < characters.count && characters[i + 1].isLowercase {
                    if !currentWord.isEmpty {
                        words.append(currentWord)
                        currentWord = ""
                    }
                }
            }

            currentWord.append(char)
        }

        if !currentWord.isEmpty {
            words.append(currentWord)
        }

        return words.map { $0.lowercased() }
    }

    /// Splits snake_case and kebab-case text into sub-tokens, further expanding any camelCase parts.
    ///
    /// Examples:
    /// - `max_timeout_ms` -> `["max", "timeout", "ms"]`
    /// - `user_profile_store` -> `["user", "profile", "store"]`
    public static func splitSnakeCase(_ text: String) -> [String] {
        let parts = text.split { $0 == "_" || $0 == "-" }
        var results: [String] = []
        for part in parts {
            let subWords = splitCamelCase(String(part))
            results.append(contentsOf: subWords)
        }
        return results
    }

    /// Extracts file extensions from a query string.
    ///
    /// Examples:
    /// - `.swift` -> `["swift"]`
    /// - `config.toml` -> `["toml"]`
    /// - `main.rs and test.swift` -> `["rs", "swift"]`
    public static func extractFileExtensions(_ text: String) -> [String] {
        var extensions: [String] = []
        var seen = Set<String>()

        // Split on whitespace or common delimiters
        let rawTokens = text.split { character in
            character.isWhitespace || character == "," || character == ";" || character == "(" ||
            character == ")" || character == "[" || character == "]" || character == "{" ||
            character == "}" || character == "\"" || character == "'" || character == "`"
        }

        for rawToken in rawTokens {
            let str = String(rawToken)
            if str.hasPrefix(".") {
                let ext = String(str.dropFirst()).lowercased()
                if isExtensionCandidate(ext) && seen.insert(ext).inserted {
                    extensions.append(ext)
                }
            } else if let dotIndex = str.lastIndex(of: ".") {
                let ext = String(str[str.index(after: dotIndex)...]).lowercased()
                if isExtensionCandidate(ext) && seen.insert(ext).inserted {
                    extensions.append(ext)
                }
            }
        }

        return extensions
    }

    /// Extracts filtered and expanded keyword tokens from a query string.
    public static func extractTokens(_ query: String) -> [String] {
        var extracted: [String] = []
        var seen = Set<String>()

        func addToken(_ token: String) {
            let lower = token.lowercased()
            guard isValidToken(lower) else { return }
            if seen.insert(lower).inserted {
                extracted.append(lower)
            }
        }

        // Split on characters that are not letters, numbers, underscores, dots, or hyphens
        let rawWords = query.split { char in
            !(char.isLetter || char.isNumber || char == "_" || char == "." || char == "-")
        }.map(String.init)

        for rawWord in rawWords {
            // Check for file extensions (e.g. config.toml or .swift)
            if rawWord.hasPrefix(".") {
                let ext = String(rawWord.dropFirst())
                addToken(ext)
                continue
            } else if rawWord.contains(".") {
                let dotParts = rawWord.split(separator: ".").map(String.init)
                for part in dotParts {
                    let snakeParts = splitSnakeCase(part)
                    for sub in snakeParts {
                        addToken(sub)
                    }
                }
                continue
            }

            // Check for snake_case / kebab-case
            if rawWord.contains("_") || rawWord.contains("-") {
                // Also add the full compound identifier if valid
                let cleanedIdentifier = rawWord.replacingOccurrences(of: "-", with: "_")
                addToken(cleanedIdentifier)

                let snakeParts = splitSnakeCase(rawWord)
                for sub in snakeParts {
                    addToken(sub)
                }
                continue
            }

            // CamelCase splitting
            let camelParts = splitCamelCase(rawWord)
            if camelParts.count > 1 {
                addToken(rawWord) // Add the full camelCase word
                for sub in camelParts {
                    addToken(sub)
                }
            } else {
                addToken(rawWord)
            }
        }

        // Also ensure any file extensions detected in query are extracted
        for ext in extractFileExtensions(query) {
            addToken(ext)
        }

        return extracted
    }

    private static func isExtensionCandidate(_ ext: String) -> Bool {
        guard !ext.isEmpty else { return false }
        if knownFileExtensions.contains(ext) { return true }
        // General extension heuristic: 1 to 8 alphanumeric characters
        return ext.count <= 8 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        guard !stopWords.contains(token) else { return false }
        // Filter out pure numbers (e.g. 8080, 123)
        guard !token.allSatisfy(\.isNumber) else { return false }
        // Preserve 1-char language/extension names like 'c', 'h', 'm', 'r'; otherwise require >= 2 chars
        if token.count == 1 {
            return ["c", "h", "m", "r"].contains(token)
        }
        return true
    }
}
