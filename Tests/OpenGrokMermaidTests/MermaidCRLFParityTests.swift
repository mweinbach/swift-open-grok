import Testing

@testable import OpenGrokMermaid

@Suite("Mermaid logical line and family classification parity")
struct MermaidCRLFParityTests {
    @Test("CRLF, isolated carriage returns, and mixed endings produce logical lines")
    func logicalLineBoundaries() {
        #expect(splitIntoLines("") == [])
        #expect(splitIntoLines("first\r\nsecond\nthird\rfourth\r\n") == [
            "first", "second", "third", "fourth",
        ])
        #expect(splitIntoLines("\r\n\r") == ["", ""])
        #expect(splitIntoLines("one\r\n\r\ntwo") == ["one", "", "two"])
    }

    @Test("flowcharts survive CRLF and mixed line endings through parsing and rendering")
    func flowchartLineEndings() throws {
        let source = "%% hidden\r\ngraph LR\r\n  A[Start] --> B[Finish]\r  B --> C\n"
        let graph = try parseFlowchart(source)
        let edges = graph.statements.compactMap {
            if case let .edge(edge) = $0 { return edge } else { return nil }
        }

        #expect(graph.direction == .leftToRight)
        #expect(edges.map { "\($0.from)->\($0.to)" } == ["A->B", "B->C"])
        #expect(try MermaidRenderer.parse(source).kind == .flowchart)
        #expect(try MermaidRenderer.render(source).contains("<svg"))
    }

    @Test("state diagrams preserve transitions and logical error lines across mixed endings")
    func stateDiagramLineEndings() throws {
        let source = "stateDiagram-v2\r\n  [*] --> Idle\r  Idle --> Running : start\n"
        let graph = try parseStateDiagram(source)
        let edges = graph.statements.compactMap {
            if case let .edge(edge) = $0 { return edge } else { return nil }
        }

        #expect(edges.map(\.from) == ["__start", "Idle"])
        #expect(edges.map(\.to) == ["Idle", "Running"])
        #expect(edges.map(\.label) == [nil, "start"])
        #expect(try MermaidRenderer.parse(source).kind == .stateDiagram)

        #expect(
            throws: MermaidError.parse(
                line: 4,
                message: "Unrecognized stateDiagram line: note right of Idle"
            )
        ) {
            try parseStateDiagram("stateDiagram-v2\r\n%% hidden\r\n\rnote right of Idle")
        }
    }

    @Test("CRLF frontmatter retains nested config and exact body offsets")
    func crlfFrontmatterAndConfig() throws {
        let source = "\r\n  \r\n---\r\ntitle: CRLF Diagram\r\nconfig:\r\n"
            + "  theme: dark\r\n  fontSize: 18px\r\n  flowchart:\r\n"
            + "    nodeSpacing: 75\r\n    rankSpacing: 90\r\n---\r\n"
            + "flowchart LR\r\n  A --> B\r\n"
        let parsed = parseMermaidFrontmatter(source)

        #expect(parsed.body == "flowchart LR\r\n  A --> B\r\n")
        #expect(parsed.frontmatter?.title == "CRLF Diagram")
        #expect(parsed.config.theme == .dark)
        #expect(parsed.config.fontSizePixels() == 18)
        #expect(parsed.config.flowchart.nodeSpacing == 75)
        #expect(parsed.config.flowchart.rankSpacing == 90)

        let diagram = try MermaidRenderer.parse(source)
        #expect(diagram.kind == .flowchart)
        #expect(diagram.title == "CRLF Diagram")
        #expect(diagram.config.flowchart.nodeSpacing == 75)
    }

    @Test("mixed frontmatter delimiters preserve the original state-diagram body")
    func mixedFrontmatterLineEndings() throws {
        let body = "stateDiagram-v2\r\n[*] --> Idle\rIdle --> [*]\n"
        let source = "\r---\rtitle: Mixed Diagram\r\nconfig:\n  theme: forest\r"
            + "  flowchart:\r\n    nodeSpacing: 41\n---\r" + body
        let parsed = parseMermaidFrontmatter(source)

        #expect(parsed.body == body)
        #expect(parsed.frontmatter?.title == "Mixed Diagram")
        #expect(parsed.config.theme == .forest)
        #expect(parsed.config.flowchart.nodeSpacing == 41)
        #expect(try MermaidRenderer.parse(source).kind == .stateDiagram)
    }

    @Test("unterminated CRLF frontmatter remains untouched")
    func unterminatedCRLFFrontmatter() {
        let source = "---\r\ntitle: Missing delimiter\r\nflowchart TD\r\nA --> B\r\n"
        let parsed = parseMermaidFrontmatter(source)

        #expect(parsed.body == source)
        #expect(parsed.frontmatter == nil)
        #expect(parsed.config == RenderConfig())
    }

    @Test("the public family sets describe all five implemented renderers")
    func publicDiagramFamilyClassification() throws {
        let supported: Set<String> = [
            "graph", "flowchart", "stateDiagram", "stateDiagram-v2",
            "classDiagram", "classDiagram-v2", "erDiagram", "sequenceDiagram",
        ]
        #expect(MermaidDiagramFamily.supported == supported)
        #expect(MermaidDiagramFamily.supported.isDisjoint(with: MermaidDiagramFamily.knownButUnsupported))
        #expect(MermaidDiagramFamily.knownButUnsupported.contains("pie"))

        let families: [(source: String, token: String, kind: MermaidDiagram.Kind)] = [
            ("graph TD\r\nA --> B", "graph", .flowchart),
            ("stateDiagram-v2\r\n[*] --> Idle", "stateDiagram-v2", .stateDiagram),
            ("classDiagram\r\nAnimal <|-- Duck", "classDiagram", .classDiagram),
            ("erDiagram\r\nCUSTOMER ||--o{ ORDER : places", "erDiagram", .entityRelationshipDiagram),
            ("sequenceDiagram\r\nAlice->>Bob: hello", "sequenceDiagram", .sequenceDiagram),
        ]
        for family in families {
            #expect(MermaidDiagramFamily.firstToken(of: family.source) == family.token)
            #expect(try MermaidRenderer.parse(family.source).kind == family.kind)
        }
    }

    @Test("inline semicolon headers dispatch newly implemented diagram families")
    func inlineSemicolonFamilyClassification() throws {
        let families: [(source: String, token: String, kind: MermaidDiagram.Kind)] = [
            ("classDiagram; Animal <|-- Duck", "classDiagram", .classDiagram),
            ("classDiagram-v2; Animal <|-- Duck", "classDiagram-v2", .classDiagram),
            ("erDiagram; CUSTOMER ||--o{ ORDER : places", "erDiagram", .entityRelationshipDiagram),
            ("sequenceDiagram; Alice->>Bob: hello", "sequenceDiagram", .sequenceDiagram),
        ]
        for family in families {
            #expect(MermaidDiagramFamily.firstToken(of: family.source) == family.token)
            #expect(try MermaidRenderer.parse(family.source).kind == family.kind)
        }
    }

    @Test("the direct flowchart parser rejects every other recognized diagram family")
    func flowchartParserRejectsNonFlowchartFamilies() {
        let families: [(token: String, source: String)] = [
            ("stateDiagram", "stateDiagram\r\n[*] --> Idle"),
            ("stateDiagram-v2", "stateDiagram-v2\r\n[*] --> Idle"),
            ("classDiagram", "classDiagram; Animal <|-- Duck"),
            ("classDiagram-v2", "classDiagram-v2\r\nAnimal <|-- Duck"),
            ("erDiagram", "erDiagram\r\nCUSTOMER ||--o{ ORDER : places"),
            ("sequenceDiagram", "sequenceDiagram; Alice->>Bob: hello"),
            ("pie", "pie\r\n\"one\" : 1"),
        ]
        for family in families {
            #expect(throws: MermaidError.unsupportedDiagramType(family.token)) {
                try parseFlowchart(family.source)
            }
        }
    }
}
