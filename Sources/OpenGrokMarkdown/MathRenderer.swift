import Foundation

enum MarkdownMathRenderer {
    static let maximumSourceBytes = 4096

    static func inline(_ source: String) -> String? {
        guard source.utf8.count <= maximumSourceBytes else { return nil }
        var converter = MathConverter(source: source)
        let rendered = converter.render()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        return rendered.isEmpty ? nil : rendered
    }

    static func display(_ source: String) -> [String]? {
        guard source.utf8.count <= maximumSourceBytes else { return nil }
        var converter = MathConverter(source: source)
        let rendered = converter.render()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                String(line.reversed().drop(while: { $0.isWhitespace }).reversed())
            }
            .filter { !$0.isEmpty }
        return rendered.isEmpty ? nil : rendered
    }
}

private struct MathConverter {
    private static let maximumDepth = 32

    private let characters: [Character]
    private let depth: Int
    private let textMode: Bool
    private var index = 0

    init(source: String, depth: Int = 0, textMode: Bool = false) {
        characters = Array(source)
        self.depth = depth
        self.textMode = textMode
    }

    mutating func render() -> String {
        guard depth < Self.maximumDepth else { return String(characters) }

        var output = ""
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 1
                renderCommand(into: &output)
            case "{":
                if let group = readGroup() {
                    output.append(renderFragment(group, textMode: textMode))
                }
            case "}", "&", "$":
                index += 1
            case "^", "_":
                index += 1
                renderScript(character, into: &output)
            case "~":
                index += 1
                appendSpace(to: &output)
            case "-" where !textMode:
                index += 1
                output.append("−")
            case "'" where !textMode:
                index += 1
                output.append("′")
            case _ where character.isWhitespace:
                skipWhitespace()
                appendSpace(to: &output)
            default:
                index += 1
                output.append(character)
            }
        }
        return output
    }

    private mutating func renderCommand(into output: inout String) {
        guard index < characters.count else {
            output.append("\\")
            return
        }

        let name = readCommandName()
        switch name {
        case "\\":
            while output.last?.isWhitespace == true && output.last != "\n" {
                output.removeLast()
            }
            output.append("\n")
            skipWhitespace()

        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = takeGroup().map { renderFragment($0, textMode: false) }
            let denominator = takeGroup().map { renderFragment($0, textMode: false) }
            if let numerator, let denominator {
                output.append(Self.formatFraction(numerator, denominator))
            } else if let numerator {
                output.append(numerator)
            }

        case "binom", "dbinom", "tbinom":
            let first = takeGroup().map { renderFragment($0, textMode: false) }
            let second = takeGroup().map { renderFragment($0, textMode: false) }
            if let first, let second { output.append("C(\(first), \(second))") }

        case "sqrt":
            renderRoot(into: &output)

        case "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal",
             "mbox", "hbox", "mathrm", "operatorname", "mathit", "mathsf", "mathtt",
             "mathnormal", "fbox", "framebox":
            if let group = takeGroup() {
                output.append(renderFragment(group, textMode: true))
            }

        case "boxed":
            if let group = takeGroup() {
                output.append(renderFragment(group, textMode: false))
            }

        case "mathbb", "mathcal", "mathscr", "mathfrak", "mathbf", "boldsymbol", "bm", "bold":
            if let atom = readAtom() {
                let rendered = renderFragment(atom, textMode: false)
                for character in rendered {
                    output.append(Self.mapAlphabet(character, family: name))
                }
            }

        case "hat", "widehat", "bar", "overline", "tilde", "widetilde", "vec", "dot", "ddot",
             "check", "breve", "acute", "grave", "mathring", "underline":
            if let atom = readAtom(), let accent = Self.accents[name] {
                let rendered = renderFragment(atom, textMode: false)
                for character in rendered {
                    output.append(character)
                    if !character.isWhitespace { output.append(accent) }
                }
            }

        case "left", "right":
            skipWhitespace()
            if index < characters.count && characters[index] == "." {
                index += 1
            }

        case "begin":
            if let name = takeGroup(), let body = takeEnvironment(named: name) {
                appendEnvironment(name: name, body: body, to: &output)
            }

        case "end":
            _ = takeGroup()

        case "not":
            if let atom = readAtom() {
                let value = renderFragment(atom, textMode: false)
                output.append(Self.negations[value] ?? (value + "\u{0338}"))
            }

        case "overset", "stackrel":
            let annotation = takeGroup().map { renderFragment($0, textMode: false) }
            let base = takeGroup().map { renderFragment($0, textMode: false) }
            if let base {
                output.append(base)
                if let annotation, let script = Self.mapScript(annotation, using: Self.superscripts) {
                    output.append(script)
                }
            }

        case "underset":
            let annotation = takeGroup().map { renderFragment($0, textMode: false) }
            let base = takeGroup().map { renderFragment($0, textMode: false) }
            if let base {
                output.append(base)
                if let annotation, let script = Self.mapScript(annotation, using: Self.subscripts) {
                    output.append(script)
                }
            }

        case "pmod":
            if let group = takeGroup() {
                appendSpace(to: &output)
                output.append("(mod \(renderFragment(group, textMode: false)))")
            }

        case "bmod":
            appendSpace(to: &output)
            output.append("mod ")

        case ",", ";", ":", ">", " ", "space", "thinspace", "medspace", "thickspace", "enspace":
            appendSpace(to: &output)

        case "quad":
            output.append("  ")

        case "qquad":
            output.append("    ")

        case "!", "negthinspace", "negmedspace", "negthickspace", "limits", "nolimits",
             "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "big", "Big",
             "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl", "bigr", "Bigr", "biggr",
             "Biggr", "bigm", "Bigm", "biggm", "Biggm", "mathstrut", "strut", "allowbreak",
             "nonumber", "notag", "mathopen", "mathclose", "mathbin", "mathrel", "mathord",
             "mathpunct", "mathinner", "mathop", "ensuremath":
            break

        case "label", "tag":
            _ = takeGroup()

        default:
            output.append(Self.symbols[name] ?? name)
        }
    }

    private mutating func renderRoot(into output: inout String) {
        skipWhitespace()
        var rootIndex: String?
        if index < characters.count && characters[index] == "[" {
            index += 1
            let start = index
            while index < characters.count && characters[index] != "]" { index += 1 }
            rootIndex = renderFragment(String(characters[start..<index]), textMode: false)
            if index < characters.count { index += 1 }
        }

        switch rootIndex {
        case .none, .some("2"): output.append("√")
        case .some("3"): output.append("∛")
        case .some("4"): output.append("∜")
        case let .some(value):
            output.append(Self.mapScript(value, using: Self.superscripts) ?? "(\(value))")
            output.append("√")
        }

        if let atom = readAtom() {
            let value = renderFragment(atom, textMode: false)
            output.append(value.count > 1 ? "(\(value))" : value)
        }
    }

    private mutating func renderScript(_ marker: Character, into output: inout String) {
        guard let atom = readAtom() else {
            output.append(marker)
            return
        }
        let rendered = renderFragment(atom, textMode: textMode)
        let mapping = marker == "^" ? Self.superscripts : Self.subscripts
        if !Self.isWordlikeScript(atom: atom, rendered: rendered),
           let script = Self.mapScript(rendered, using: mapping),
           !script.isEmpty {
            output.append(script)
        } else {
            output.append(marker)
            output.append(rendered.count > 1 ? "(\(rendered))" : rendered)
        }
    }

    private mutating func readCommandName() -> String {
        let start = index
        if characters[index].isASCII && characters[index].isLetter {
            while index < characters.count && characters[index].isASCII && characters[index].isLetter {
                index += 1
            }
        } else {
            index += 1
        }
        return String(characters[start..<index])
    }

    private mutating func readAtom() -> String? {
        skipWhitespace()
        guard index < characters.count else { return nil }
        if characters[index] == "{" { return readGroup() }

        if characters[index] == "\\" {
            let start = index
            index += 1
            guard index < characters.count else { return "\\" }
            _ = readCommandName()
            if index < characters.count && characters[index] == "{" {
                _ = readGroup()
            }
            return String(characters[start..<index])
        }

        defer { index += 1 }
        return String(characters[index])
    }

    private mutating func takeGroup() -> String? {
        skipWhitespace()
        return readGroup()
    }

    private mutating func readGroup() -> String? {
        guard index < characters.count && characters[index] == "{" else { return nil }
        index += 1
        let start = index
        var nesting = 1
        while index < characters.count {
            if characters[index] == "{" {
                nesting += 1
            } else if characters[index] == "}" {
                nesting -= 1
                if nesting == 0 {
                    let body = String(characters[start..<index])
                    index += 1
                    return body
                }
            }
            index += 1
        }
        return String(characters[start..<index])
    }

    private mutating func takeEnvironment(named name: String) -> String? {
        let opening = Array("\\begin{\(name)}")
        let closing = Array("\\end{\(name)}")
        let start = index
        var cursor = index
        var nesting = 1
        while cursor < characters.count {
            if Self.matches(opening, characters, at: cursor) {
                nesting += 1
                cursor += opening.count
            } else if Self.matches(closing, characters, at: cursor) {
                nesting -= 1
                if nesting == 0 {
                    let body = String(characters[start..<cursor])
                    index = cursor + closing.count
                    return body
                }
                cursor += closing.count
            } else {
                cursor += 1
            }
        }
        index = cursor
        return String(characters[start..<cursor])
    }

    private mutating func appendEnvironment(name: String, body: String, to output: inout String) {
        let rawRows = Self.splitRows(body)
        let renderedRows = rawRows.map { row in
            row.split(separator: "&", omittingEmptySubsequences: false)
                .map { renderFragment(String($0), textMode: false).trimmingCharacters(in: .whitespaces) }
        }
        guard !renderedRows.isEmpty else { return }

        let isMatrix = ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix"].contains(name)
        let isCases = name == "cases" || name == "dcases"
        var rows: [String]

        if isMatrix || isCases {
            let columnCount = renderedRows.map(\.count).max() ?? 0
            let widths = (0..<columnCount).map { column in
                renderedRows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
            }
            rows = renderedRows.map { cells in
                cells.enumerated().map { column, cell in
                    cell + String(repeating: " ", count: max(0, widths[column] - cell.count))
                }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
            }
            if isCases {
                rows = rows.enumerated().map { offset, row in
                    let brace = rows.count == 1 ? "{" : offset == 0 ? "⎧" : offset == rows.count - 1 ? "⎩" : "⎨"
                    return "\(brace) \(row)"
                }
            } else {
                rows = Self.decorateMatrix(rows, name: name)
            }
        } else {
            rows = renderedRows.map { $0.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        }

        let prefix = output.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        for (offset, row) in rows.enumerated() {
            if offset > 0 {
                output.append("\n")
                output.append(String(repeating: " ", count: prefix.count))
            }
            output.append(row)
        }
    }

    private func renderFragment(_ source: String, textMode: Bool) -> String {
        var nested = MathConverter(source: source, depth: depth + 1, textMode: textMode)
        return nested.render()
    }

    private mutating func skipWhitespace() {
        while index < characters.count && characters[index].isWhitespace { index += 1 }
    }

    private func appendSpace(to output: inout String) {
        if !output.isEmpty && output.last != " " && output.last != "\n" {
            output.append(" ")
        }
    }

    private static func matches(_ target: [Character], _ characters: [Character], at index: Int) -> Bool {
        guard index + target.count <= characters.count else { return false }
        return zip(target, characters[index..<(index + target.count)]).allSatisfy { $0 == $1 }
    }

    private static func splitRows(_ source: String) -> [String] {
        let characters = Array(source)
        var rows: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count,
               characters[index + 1] == "\\" {
                rows.append(current)
                current = ""
                index += 2
            } else {
                current.append(characters[index])
                index += 1
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(current)
        }
        return rows
    }

    private static func decorateMatrix(_ rows: [String], name: String) -> [String] {
        guard name != "matrix" else { return rows }
        if rows.count == 1 {
            let delimiters: (String, String) = switch name {
            case "pmatrix": ("(", ")")
            case "bmatrix": ("[", "]")
            case "Bmatrix": ("{", "}")
            case "vmatrix": ("|", "|")
            default: ("‖", "‖")
            }
            return [delimiters.0 + rows[0] + delimiters.1]
        }

        return rows.enumerated().map { index, row in
            let delimiters: (String, String)
            switch name {
            case "pmatrix":
                delimiters = index == 0 ? ("⎛", "⎞") : index == rows.count - 1 ? ("⎝", "⎠") : ("⎜", "⎟")
            case "bmatrix":
                delimiters = index == 0 ? ("⎡", "⎤") : index == rows.count - 1 ? ("⎣", "⎦") : ("⎢", "⎥")
            case "Bmatrix":
                delimiters = index == 0 ? ("⎧", "⎫") : index == rows.count - 1 ? ("⎩", "⎭") : ("⎨", "⎬")
            case "vmatrix":
                delimiters = ("│", "│")
            default:
                delimiters = ("‖", "‖")
            }
            return delimiters.0 + row + delimiters.1
        }
    }

    private static func formatFraction(_ numerator: String, _ denominator: String) -> String {
        if let fraction = vulgarFractions["\(numerator)/\(denominator)"] { return fraction }
        let needsParentheses: (String) -> Bool = { value in
            value.count > 1 && value.contains(where: { " +-−=/".contains($0) })
        }
        let first = needsParentheses(numerator) ? "(\(numerator))" : numerator
        let second = needsParentheses(denominator) ? "(\(denominator))" : denominator
        return "\(first)/\(second)"
    }

    private static func isWordlikeScript(atom: String, rendered: String) -> Bool {
        let markers = ["\\text", "\\mathrm", "\\mathsf", "\\mathtt", "\\mathit", "\\operatorname", "\\mbox", "\\hbox"]
        if markers.contains(where: atom.contains) { return true }
        var run = 0
        for character in rendered {
            if character.isASCII && character.isLetter {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func mapScript(_ value: String, using mapping: [Character: Character]) -> String? {
        var result = ""
        for character in value {
            guard let mapped = mapping[character] else { return nil }
            result.append(mapped)
        }
        return result
    }

    private static func mapAlphabet(_ character: Character, family: String) -> Character {
        let overrides: [Character: Character]
        let upperBase: UInt32
        let lowerBase: UInt32
        let digitBase: UInt32?
        switch family {
        case "mathbb":
            overrides = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
            upperBase = 0x1D538
            lowerBase = 0x1D552
            digitBase = 0x1D7D8
        case "mathcal", "mathscr":
            overrides = ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ", "e": "ℯ", "g": "ℊ", "o": "ℴ"]
            upperBase = 0x1D49C
            lowerBase = 0x1D4B6
            digitBase = nil
        case "mathfrak":
            overrides = ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"]
            upperBase = 0x1D504
            lowerBase = 0x1D51E
            digitBase = nil
        default:
            overrides = [:]
            upperBase = 0x1D400
            lowerBase = 0x1D41A
            digitBase = 0x1D7CE
        }
        if let override = overrides[character] { return override }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return character
        }

        let value: UInt32
        switch scalar.value {
        case 65...90: value = upperBase + scalar.value - 65
        case 97...122: value = lowerBase + scalar.value - 97
        case 48...57:
            guard let digitBase else { return character }
            value = digitBase + scalar.value - 48
        default: return character
        }
        guard let mapped = UnicodeScalar(value) else { return character }
        return Character(mapped)
    }

    private static let vulgarFractions: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕",
        "2/5": "⅖", "3/5": "⅗", "4/5": "⅘", "1/6": "⅙", "5/6": "⅚", "1/7": "⅐",
        "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞", "1/9": "⅑", "1/10": "⅒"
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
        "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
        "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ",
        "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
        "z": "ᶻ", "T": "ᵀ", "*": "*", "′": "′", "'": "′", " ": " "
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
        "8": "₈", "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
        "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ",
        "x": "ₓ", " ": " "
    ]

    private static let accents: [String: Character] = [
        "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0304}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}", "vec": "\u{20D7}", "dot": "\u{0307}",
        "ddot": "\u{0308}", "check": "\u{030C}", "breve": "\u{0306}", "acute": "\u{0301}",
        "grave": "\u{0300}", "mathring": "\u{030A}", "underline": "\u{0332}"
    ]

    private static let negations: [String: String] = [
        "∈": "∉", "=": "≠", "<": "≮", ">": "≯", "≡": "≢", "⊂": "⊄", "⊆": "⊈", "∃": "∄"
    ]

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ",
        "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "sum": "∑", "prod": "∏",
        "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "bigcup": "⋃",
        "bigcap": "⋂", "bigvee": "⋁", "bigwedge": "⋀", "bigoplus": "⨁", "bigotimes": "⨂",
        "bigodot": "⨀", "biguplus": "⨄", "lim": "lim", "limsup": "lim sup", "liminf": "lim inf",
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
        "arcsin": "arcsin", "arccos": "arccos", "arctan": "arctan", "sinh": "sinh", "cosh": "cosh",
        "tanh": "tanh", "coth": "coth", "log": "log", "ln": "ln", "lg": "lg", "exp": "exp",
        "max": "max", "min": "min", "sup": "sup", "inf": "inf", "det": "det", "dim": "dim",
        "ker": "ker", "deg": "deg", "arg": "arg", "gcd": "gcd", "hom": "hom", "Pr": "Pr",
        "times": "×", "cdot": "⋅", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "circ": "∘", "bullet": "•", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘",
        "odot": "⊙", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨", "cap": "∩", "cup": "∪",
        "setminus": "∖", "smallsetminus": "∖", "uplus": "⊎", "sqcap": "⊓", "sqcup": "⊔",
        "triangleleft": "◁", "triangleright": "▷", "wr": "≀", "diamond": "⋄", "dagger": "†",
        "ddagger": "‡", "amalg": "⨿", "le": "≤", "leq": "≤", "leqslant": "≤", "ge": "≥",
        "geq": "≥", "geqslant": "≥", "ne": "≠", "neq": "≠", "ll": "≪", "gg": "≫", "approx": "≈",
        "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡", "doteq": "≐", "propto": "∝",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰", "asymp": "≍", "in": "∈",
        "ni": "∋", "owns": "∋", "notin": "∉", "subset": "⊂", "supset": "⊃", "subseteq": "⊆",
        "supseteq": "⊇", "subsetneq": "⊊", "supsetneq": "⊋", "sqsubseteq": "⊑", "sqsupseteq": "⊒",
        "vdash": "⊢", "dashv": "⊣", "models": "⊨", "vDash": "⊨", "perp": "⊥", "parallel": "∥",
        "nparallel": "∦", "mid": "∣", "nmid": "∤", "smile": "⌣", "frown": "⌢", "bowtie": "⋈",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⟹",
        "impliedby": "⟸", "iff": "⟺", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "longmapsto": "⟼", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "updownarrow": "↕",
        "Uparrow": "⇑", "Downarrow": "⇓", "nearrow": "↗", "searrow": "↘", "swarrow": "↙",
        "nwarrow": "↖", "hookrightarrow": "↪", "hookleftarrow": "↩", "rightharpoonup": "⇀",
        "leftharpoonup": "↼", "rightleftharpoons": "⇌", "forall": "∀", "exists": "∃",
        "nexists": "∄", "neg": "¬", "lnot": "¬", "emptyset": "∅", "varnothing": "∅", "infty": "∞",
        "nabla": "∇", "partial": "∂", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
        "aleph": "ℵ", "beth": "ℶ", "wp": "℘", "imath": "ı", "jmath": "ȷ", "top": "⊤",
        "bot": "⊥", "angle": "∠", "measuredangle": "∡", "triangle": "△", "square": "□",
        "Box": "□", "blacksquare": "■", "diamondsuit": "♦", "heartsuit": "♥", "clubsuit": "♣",
        "spadesuit": "♠", "flat": "♭", "natural": "♮", "sharp": "♯", "checkmark": "✓",
        "degree": "°", "prime": "′", "dprime": "″", "therefore": "∴", "because": "∵",
        "dots": "…", "ldots": "…", "dotsc": "…", "dotso": "…", "dotsb": "…", "dotsm": "…",
        "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "surd": "√", "AA": "Å", "langle": "⟨",
        "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "lbrace": "{",
        "rbrace": "}", "lbrack": "[", "rbrack": "]", "vert": "|", "Vert": "‖", "|": "‖",
        "backslash": "\\", "setbslash": "∖", "{": "{", "}": "}", "%": "%", "$": "$", "&": "&",
        "#": "#", "_": "_"
    ]
}
