import Testing
@testable import OpenGrokCodebaseGraph

@Suite("Codebase graph newline parity")
struct CodebaseGraphCRLFParityTests {
    @Test("definitions and references preserve Unicode positions", arguments: ["\n", "\r\n", "\r"])
    func symbolPositionsAcrossLineEndings(_ newline: String) {
        let content = [
            "fn α() {}",
            "  use café::β;",
            "    fn γδ() {}",
        ].joined(separator: newline)

        let symbols = SymbolExtractor.extract(path: "unicode.rs", content: content)

        #expect(symbols.definitions == [
            SymbolOccurrence(name: "α", line: 1, column: 4),
            SymbolOccurrence(name: "γδ", line: 3, column: 8),
        ])
        #expect(symbols.references == [
            SymbolOccurrence(name: "β", line: 2, column: 13),
        ])
    }

    @Test("Rust line comments stop at every supported newline", arguments: ["\n", "\r\n", "\r"])
    func rustLineCommentsDoNotConsumeFollowingSymbols(_ newline: String) {
        let content = [
            "// fn hidden() {}",
            "use café::β;",
            "fn visible() {}",
        ].joined(separator: newline)

        let symbols = SymbolExtractor.extract(path: "comments.rs", content: content)

        #expect(symbols.definitions == [
            SymbolOccurrence(name: "visible", line: 3, column: 4),
        ])
        #expect(symbols.references == [
            SymbolOccurrence(name: "β", line: 2, column: 11),
        ])
    }

    @Test("Python line comments preserve later definitions and references", arguments: ["\n", "\r\n", "\r"])
    func pythonLineCommentsDoNotConsumeFollowingSymbols(_ newline: String) {
        let content = [
            "# def hidden():",
            "from café import β",
            "def entrée():",
            "    return β()",
        ].joined(separator: newline)

        let symbols = SymbolExtractor.extract(path: "comments.py", content: content)

        #expect(symbols.definitions == [
            SymbolOccurrence(name: "entrée", line: 3, column: 5),
        ])
        #expect(symbols.references == [
            SymbolOccurrence(name: "café", line: 2, column: 6),
            SymbolOccurrence(name: "β", line: 2, column: 18),
            SymbolOccurrence(name: "β", line: 4, column: 12),
        ])
    }

    @Test("block comments and multiline strings advance by logical lines", arguments: ["\n", "\r\n", "\r"])
    func embeddedNewlinesPreserveFollowingSymbolPositions(_ newline: String) {
        let rust = [
            "/* résumé",
            "   ignored */",
            "fn visible() {}",
        ].joined(separator: newline)
        let rustSymbols = SymbolExtractor.extract(path: "block.rs", content: rust)

        #expect(rustSymbols.definitions == [
            SymbolOccurrence(name: "visible", line: 3, column: 4),
        ])

        let python = [
            "\"\"\"résumé",
            "ignored\"\"\"",
            "def entrée():",
            "    return β()",
        ].joined(separator: newline)
        let pythonSymbols = SymbolExtractor.extract(path: "multiline.py", content: python)

        #expect(pythonSymbols.definitions == [
            SymbolOccurrence(name: "entrée", line: 3, column: 5),
        ])
        #expect(pythonSymbols.references == [
            SymbolOccurrence(name: "β", line: 4, column: 12),
        ])
    }

    @Test("mixed CRLF, CR, LF, and Unicode separators reset columns once")
    func tokenizerPreservesMixedNewlinePositions() {
        let tokens = tokenize("α\r\n  β\r\tγ\nδ\u{2028}  ε", language: .swift)

        #expect(tokens == [
            Tok(kind: .ident, text: "α", line: 1, column: 1),
            Tok(kind: .newline, text: "\n", line: 1, column: 2),
            Tok(kind: .ident, text: "β", line: 2, column: 3),
            Tok(kind: .newline, text: "\n", line: 2, column: 4),
            Tok(kind: .ident, text: "γ", line: 3, column: 2),
            Tok(kind: .newline, text: "\n", line: 3, column: 3),
            Tok(kind: .ident, text: "δ", line: 4, column: 1),
            Tok(kind: .newline, text: "\n", line: 4, column: 2),
            Tok(kind: .ident, text: "ε", line: 5, column: 3),
        ])
    }
}
