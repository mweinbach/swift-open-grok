import Testing

@testable import OpenGrokMermaid

@Suite("Flowchart parser")
struct MermaidParserTests {
    private func nodes(_ graph: FlowchartGraph) -> [FlowchartNode] {
        graph.statements.compactMap { if case let .node(node) = $0 { return node } else { return nil } }
    }

    private func edges(_ graph: FlowchartGraph) -> [FlowchartEdge] {
        graph.statements.compactMap { if case let .edge(edge) = $0 { return edge } else { return nil } }
    }

    private func subgraphs(_ graph: FlowchartGraph) -> [FlowchartSubgraph] {
        graph.statements.compactMap {
            if case let .subgraph(subgraph) = $0 { return subgraph } else { return nil }
        }
    }

    @Test("graph and flowchart keywords both parse, with every direction")
    func directions() throws {
        for (token, expected): (String, GraphDirection) in [
            ("TD", .topToBottom), ("TB", .topToBottom), ("td", .topToBottom),
            ("BT", .bottomToTop), ("LR", .leftToRight), ("RL", .rightToLeft),
        ] {
            #expect(try parseFlowchart("graph \(token)\n  A --> B").direction == expected)
            #expect(try parseFlowchart("flowchart \(token)\n  A --> B").direction == expected)
        }
    }

    @Test("a simple chain yields its nodes then its edges")
    func simpleChain() throws {
        let graph = try parseFlowchart("graph TD\n  A --> B --> C")

        #expect(nodes(graph).map(\.id) == ["A", "B", "C"])
        #expect(edges(graph).map { "\($0.from)->\($0.to)" } == ["A->B", "B->C"])
    }

    @Test("every node shape is recognized")
    func nodeShapes() throws {
        let source = """
            graph TD
              A[rect]
              B(round)
              C([stadium])
              D{diamond}
              E{{hex}}
              F>flag]
              G[[sub]]
              H[(cyl)]
              I((circle))
            """
        let parsed = nodes(try parseFlowchart(source))

        #expect(
            parsed.map(\.shape) == [
                .rectangle, .roundedRectangle, .stadium, .diamond, .hexagon,
                .asymmetric, .subroutine, .cylinder, .circle,
            ]
        )
        #expect(parsed.map(\.id) == ["A", "B", "C", "D", "E", "F", "G", "H", "I"])
        #expect(parsed[0].label == "rect")
        #expect(parsed[8].label == "circle")
    }

    @Test("every edge style is recognized")
    func edgeStyles() throws {
        let source = """
            graph TD
              A --> B
              B --- C
              C -.-> D
              D -.- E
              E ==> F
              F === G
            """
        #expect(
            edges(try parseFlowchart(source)).map(\.style)
                == [.arrow, .line, .dottedArrow, .dottedLine, .thickArrow, .thickLine]
        )
    }

    @Test("both edge label syntaxes parse")
    func edgeLabels() throws {
        let source = """
            graph TD
              A -->|piped| B
              B -- open --> C
              C == thick ==> D
              D -. dotted .-> E
            """
        let parsed = edges(try parseFlowchart(source))

        #expect(parsed.map(\.label) == ["piped", "open", "thick", "dotted"])
        #expect(parsed.map(\.style) == [.arrow, .arrow, .thickArrow, .dottedArrow])
    }

    @Test("edge tokens inside a quoted node label are not edges")
    func edgeTokensInsideLabels() throws {
        let graph = try parseFlowchart("graph TD\n  A[\"x --> y\"] --> B")

        #expect(nodes(graph).map(\.id) == ["A", "B"])
        #expect(nodes(graph).first?.label == "x --> y")
        #expect(edges(graph).count == 1)
    }

    @Test("labels decode entities and line breaks")
    func labelNormalization() {
        #expect(normalizeLabel("\"quoted\"") == "quoted")
        #expect(normalizeLabel("a&lt;b") == "a<b")
        #expect(normalizeLabel("a&amp;b") == "a&b")
        #expect(normalizeLabel("one<br/>two") == "one\ntwo")
        #expect(normalizeLabel("one<BR>two") == "one\ntwo")
        #expect(normalizeLabel(#"one\ntwo"#) == "one\ntwo")
    }

    @Test("subgraphs nest and carry titles")
    func subgraphParsing() throws {
        let source = """
            graph TD
              subgraph outer[Outer box]
                A --> B
                subgraph inner
                  C --> D
                end
              end
              B --> C
            """
        let graph = try parseFlowchart(source)
        let outer = try #require(subgraphs(graph).first)

        #expect(outer.id == "outer")
        #expect(outer.title == "Outer box")
        let inner = try #require(
            outer.statements.compactMap {
                if case let .subgraph(subgraph) = $0 { return subgraph } else { return nil }
            }.first
        )
        #expect(inner.id == "inner")
        #expect(inner.title == nil)
    }

    @Test("a multi-word subgraph title without an id gets a synthetic one")
    func syntheticSubgraphID() throws {
        let graph = try parseFlowchart("graph TD\n  subgraph My Group\n    A --> B\n  end")
        let subgraph = try #require(subgraphs(graph).first)

        #expect(subgraph.id == "subGraph0")
        #expect(subgraph.title == "My Group")
    }

    @Test("style statements carry their properties")
    func styleStatements() throws {
        let graph = try parseFlowchart("graph TD\n  A --> B\n  style A fill:#f9f,stroke:#333")
        let style = try #require(
            graph.statements.compactMap {
                if case let .style(style) = $0 { return style } else { return nil }
            }.first
        )

        #expect(style.nodeID == "A")
        #expect(style.properties.count == 2)
        #expect(style.properties[0] == (key: "fill", value: "#f9f"))
        #expect(style.properties[1] == (key: "stroke", value: "#333"))
    }

    @Test("comments and blank lines are skipped")
    func commentsSkipped() throws {
        let source = """
            %% leading comment

            graph TD
            %% another

              A --> B
            """
        #expect(edges(try parseFlowchart(source)).count == 1)
    }
}

@Suite("Flowchart parser errors")
struct MermaidParserErrorTests {
    @Test("an empty source reports a missing declaration")
    func emptySource() {
        #expect(throws: MermaidError.parse(line: 1, message: "Expected graph declaration")) {
            try parseFlowchart("")
        }
    }

    @Test("a missing graph keyword is a parse error, not a crash")
    func missingKeyword() {
        #expect(
            throws: MermaidError.parse(
                line: 1,
                message: "Expected 'graph' or 'flowchart' declaration"
            )
        ) {
            try parseFlowchart("A --> B")
        }
    }

    @Test("a bad direction names itself")
    func invalidDirection() {
        #expect(throws: MermaidError.invalidDirection("SIDEWAYS")) {
            try parseFlowchart("graph SIDEWAYS\n  A --> B")
        }
    }

    @Test("a direction-less declaration is a parse error")
    func missingDirection() {
        #expect(throws: MermaidError.self) {
            try parseFlowchart("graph\n  A --> B")
        }
    }

    @Test("another diagram family is reported as unsupported")
    func unsupportedFamily() {
        #expect(throws: MermaidError.unsupportedDiagramType("sequenceDiagram")) {
            try parseFlowchart("sequenceDiagram\n  Alice->>Bob: hi")
        }
        #expect(throws: MermaidError.unsupportedDiagramType("pie")) {
            try parseFlowchart("pie\n  \"a\" : 1")
        }
    }

    @Test("truncated and unbalanced shapes do not crash")
    func malformedShapes() throws {
        for source in [
            "graph TD\n  A[unclosed --> B",
            "graph TD\n  A]] --> B",
            "graph TD\n  A[] --> B[]",
            "graph TD\n  ((())) --> B",
            "graph TD\n  A -->",
            "graph TD\n  --> B",
            "graph TD\n  A --> --> B",
            "graph TD\n  subgraph\n  end",
            "graph TD\n  subgraph x",
            "graph TD\n  style",
            "graph TD\n  style A",
        ] {
            // Either a value or a thrown error is fine; a trap is not.
            _ = try? parseFlowchart(source)
        }
    }

    @Test("a deeply nested label does not blow the parser up")
    func deeplyNestedBrackets() throws {
        let source = "graph TD\n  A[\(String(repeating: "[", count: 200))] --> B"
        _ = try? parseFlowchart(source)
    }
}

@Suite("State diagram parser")
struct MermaidStateParserTests {
    @Test("start and end markers become distinct nodes")
    func startAndEndMarkers() throws {
        let graph = try parseStateDiagram(
            """
            stateDiagram-v2
              [*] --> Idle
              Idle --> [*]
            """
        )
        let nodes = graph.statements.compactMap {
            if case let .node(node) = $0 { return node } else { return nil }
        }

        #expect(nodes.map(\.id) == ["__start", "Idle", "__end"])
        #expect(nodes.map(\.shape) == [.startState, .roundedRectangle, .endState])
        // Marker shapes carry no text.
        #expect(nodes[0].label == nil)
        #expect(nodes[1].label == "Idle")
    }

    @Test("transition labels parse")
    func transitionLabels() throws {
        let graph = try parseStateDiagram(
            """
            stateDiagram-v2
              Idle --> Running : start
              Running --> Idle
            """
        )
        let edges = graph.statements.compactMap {
            if case let .edge(edge) = $0 { return edge } else { return nil }
        }

        #expect(edges.map(\.label) == ["start", nil])
    }

    @Test("choice, fork, and join stereotypes pick their shapes")
    func stereotypes() throws {
        let graph = try parseStateDiagram(
            """
            stateDiagram-v2
              state Pick <<choice>>
              state Split <<fork>>
              state Merge <<join>>
              state Plain
            """
        )
        let nodes = graph.statements.compactMap {
            if case let .node(node) = $0 { return node } else { return nil }
        }

        #expect(nodes.map(\.shape) == [.diamond, .forkJoin, .forkJoin, .roundedRectangle])
    }

    @Test("a missing declaration is a parse error")
    func missingDeclaration() {
        #expect(throws: MermaidError.self) {
            try parseStateDiagram("Idle --> Running")
        }
        #expect(throws: MermaidError.self) {
            try parseStateDiagram("")
        }
    }

    @Test("an unrecognized line reports its number")
    func unrecognizedLine() {
        #expect(
            throws: MermaidError.parse(
                line: 2,
                message: "Unrecognized stateDiagram line: note right of Idle"
            )
        ) {
            try parseStateDiagram("stateDiagram-v2\nnote right of Idle")
        }
    }
}

@Suite("Frontmatter")
struct MermaidFrontmatterTests {
    @Test("a source without frontmatter is returned unchanged")
    func noFrontmatter() {
        let source = "graph TD\n  A --> B"
        let parsed = parseMermaidFrontmatter(source)

        #expect(parsed.body == source)
        #expect(parsed.frontmatter == nil)
        #expect(parsed.config == RenderConfig())
    }

    @Test("title and theme are read, and the body excludes the block")
    func titleAndTheme() {
        let parsed = parseMermaidFrontmatter(
            """
            ---
            title: My Diagram
            config:
              theme: dark
            ---
            graph TD
              A --> B
            """
        )

        #expect(parsed.frontmatter?.title == "My Diagram")
        #expect(parsed.config.theme == .dark)
        #expect(parsed.body == "graph TD\n  A --> B")
    }

    @Test("theme variables map onto the palette")
    func themeVariables() {
        let parsed = parseMermaidFrontmatter(
            """
            ---
            config:
              themeVariables:
                primaryColor: "#ff0000"
                lineColor: "#00ff00"
                textColor: "#0000ff"
            ---
            graph TD
              A --> B
            """
        )
        let theme = parsed.config.mermaidTheme()

        #expect(theme?.nodeFill == "#ff0000")
        #expect(theme?.edgeColor == "#00ff00")
        #expect(theme?.textColor == "#0000ff")
    }

    @Test("flowchart tunables are read as numbers")
    func flowchartConfig() {
        let parsed = parseMermaidFrontmatter(
            """
            ---
            config:
              fontSize: 20px
              flowchart:
                nodeSpacing: 75
                rankSpacing: 90
                curve: linear
                htmlLabels: false
            ---
            graph TD
              A --> B
            """
        )

        #expect(parsed.config.fontSizePixels() == 20)
        #expect(parsed.config.flowchart.nodeSpacing == 75)
        #expect(parsed.config.flowchart.rankSpacing == 90)
        #expect(parsed.config.flowchart.curve == "linear")
        #expect(parsed.config.flowchart.htmlLabels == false)
    }

    @Test("an unterminated or unparsable block degrades to defaults")
    func malformedFrontmatter() {
        let unterminated = parseMermaidFrontmatter("---\ntitle: x\ngraph TD\n  A --> B")
        #expect(unterminated.frontmatter == nil)

        let junk = parseMermaidFrontmatter("---\n\t\t- [not: a: mapping\n---\ngraph TD\n  A --> B")
        #expect(junk.body == "graph TD\n  A --> B")
        #expect(junk.config.theme == nil)
    }
}

@Suite("Text wrapping")
struct MermaidTextWrapTests {
    private let wrapWidth = MermaidTextWrap.defaultWrapWidth
    private let charWidth = MermaidTextWrap.defaultCharWidth

    @Test("a long unbreakable token stays whole and widens its box")
    func longTokenStaysWhole() {
        let label = "mark_filter_restore_context"
        let lines = MermaidTextWrap.wrapTextLines(label, maxWidth: wrapWidth, charWidth: charWidth)

        #expect(lines == [[label]])
        let measured = MermaidTextWrap.measure(
            lines: lines,
            charWidth: charWidth,
            fontSize: MermaidTextWrap.defaultFontSize
        )
        #expect(measured.width > wrapWidth)
    }

    @Test("a multi-word label wraps at spaces without losing words")
    func multiWordWrapping() {
        let phrase = "the quick brown fox jumps over the lazy dog"
        let lines = MermaidTextWrap.wrapTextLines(phrase, maxWidth: wrapWidth, charWidth: charWidth)

        #expect(lines.count >= 2)
        #expect(lines.flatMap { $0 } == phrase.split(separator: " ").map(String.init))
    }

    @Test("an over-cap token breaks on an identifier boundary")
    func overCapTokenBreaks() {
        let token = String(repeating: "segment_", count: 25)
        let lines = MermaidTextWrap.wrapTextLines(token, maxWidth: wrapWidth, charWidth: charWidth)

        #expect(lines.count >= 2)
        #expect(lines[0].count == 1)
        #expect(lines[0][0].hasSuffix("_"))
        #expect(lines.flatMap { $0 }.joined() == token)
    }

    @Test("an over-cap token with no boundary falls back to a grapheme break")
    func overCapTokenWithoutBoundary() {
        let token = String(repeating: "a", count: 200)
        let lines = MermaidTextWrap.wrapTextLines(token, maxWidth: wrapWidth, charWidth: charWidth)

        #expect(lines.count >= 2)
        #expect(
            MermaidTextWrap.lineWidth(lines[0].joined(), charWidth: charWidth) <= wrapWidth * 5
        )
        #expect(lines.flatMap { $0 }.joined() == token)
    }

    @Test("East Asian characters count as two narrow units")
    func wideCharacters() {
        #expect(MermaidTextWrap.displayWidthUnits("中") == 2)
        #expect(MermaidTextWrap.displayWidthUnits("ab") == 2)
    }

    @Test("explicit newlines always break")
    func explicitNewlines() {
        let lines = MermaidTextWrap.wrapTextLines(
            "one\ntwo",
            maxWidth: wrapWidth,
            charWidth: charWidth
        )
        #expect(lines == [["one"], ["two"]])
    }

    @Test("an empty label measures as nothing")
    func emptyLabel() {
        #expect(MermaidTextWrap.wrapTextLines("", maxWidth: wrapWidth, charWidth: charWidth).isEmpty)
        #expect(MermaidTextWrap.wrappedTextHeight(lineCount: 0, fontSize: 16) == 0)
    }
}
