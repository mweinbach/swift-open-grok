import Testing

@testable import OpenGrokMermaid

/// Diagrams exercised by the layout, determinism, and golden suites.
enum MermaidSamples {
    static let minimalFlowchart = """
        graph TD
          A --> B
        """

    static let branchingFlowchart = """
        graph TD
          Start([Begin]) --> Check{Ready?}
          Check -->|yes| Work[Do the work]
          Check -->|no| Wait[(Queue)]
          Work --> Done((End))
          Wait --> Check
        """

    static let leftToRightFlowchart = """
        flowchart LR
          A[Input] -- parse --> B{{Validate}}
          B == ok ==> C[[Process]]
          B -.-> D>Reject]
        """

    static let clusteredFlowchart = """
        graph TD
          subgraph frontend[Front end]
            UI[Browser] --> API[Client API]
          end
          subgraph backend[Back end]
            Service[Service] --> DB[(Database)]
          end
          API --> Service
        """

    static let cyclicFlowchart = """
        graph TD
          A --> B
          B --> C
          C --> A
        """

    static let minimalStateDiagram = """
        stateDiagram-v2
          [*] --> Idle
          Idle --> Running : start
          Running --> Idle : stop
          Running --> [*]
        """

    static let styledFlowchart = """
        graph TD
          A[Alpha] --> B[Beta]
          style A fill:#f9f,stroke:#333
        """

    static let all: [(name: String, source: String)] = [
        ("minimalFlowchart", minimalFlowchart),
        ("branchingFlowchart", branchingFlowchart),
        ("leftToRightFlowchart", leftToRightFlowchart),
        ("clusteredFlowchart", clusteredFlowchart),
        ("cyclicFlowchart", cyclicFlowchart),
        ("minimalStateDiagram", minimalStateDiagram),
        ("styledFlowchart", styledFlowchart),
    ]
}

@Suite("Flowchart layout")
struct MermaidLayoutTests {
    private func layout(_ source: String) throws -> MermaidLayoutResult {
        MermaidRenderer.layout(try MermaidRenderer.parse(source))
    }

    @Test("a top-down chain stacks its nodes downward")
    func chainStacksDownward() throws {
        let result = try layout(MermaidSamples.minimalFlowchart)
        let a = try #require(result.node(id: "A"))
        let b = try #require(result.node(id: "B"))

        #expect(a.y < b.y)
        #expect(result.width > 0)
        #expect(result.height > 0)
    }

    @Test("a left-to-right chain advances along x")
    func leftToRightAdvancesAlongX() throws {
        let result = try layout(MermaidSamples.leftToRightFlowchart)
        let a = try #require(result.node(id: "A"))
        let b = try #require(result.node(id: "B"))

        #expect(a.x < b.x)
    }

    @Test("every node sits inside the reported canvas")
    func nodesFitTheCanvas() throws {
        for sample in MermaidSamples.all {
            let result = try layout(sample.source)
            for node in result.nodes {
                #expect(node.x - node.width / 2 >= 0, "\(sample.name): \(node.id) overflows left")
                #expect(node.y - node.height / 2 >= 0, "\(sample.name): \(node.id) overflows top")
                #expect(node.x + node.width / 2 <= result.width, "\(sample.name): \(node.id)")
                #expect(node.y + node.height / 2 <= result.height, "\(sample.name): \(node.id)")
            }
        }
    }

    @Test("every edge is routed with at least two points")
    func edgesAreRouted() throws {
        for sample in MermaidSamples.all {
            let result = try layout(sample.source)
            for edge in result.edges {
                #expect(edge.points.count >= 2, "\(sample.name): \(edge.from)->\(edge.to)")
            }
        }
    }

    @Test("labelled edges get a label position")
    func labelledEdgesGetPositions() throws {
        let result = try layout(MermaidSamples.branchingFlowchart)
        let labelled = result.edges.filter { $0.label != nil }

        #expect(labelled.count == 2)
        #expect(labelled.allSatisfy { $0.labelPosition != nil })
    }

    @Test("shapes get their distinct measured sizes")
    func shapeSizes() throws {
        let result = try layout(MermaidSamples.branchingFlowchart)
        let diamond = try #require(result.node(id: "Check"))
        let stadium = try #require(result.node(id: "Start"))
        let circle = try #require(result.node(id: "Done"))

        // A diamond is square; a circle's box is square too.
        #expect(diamond.width == diamond.height)
        #expect(circle.width == circle.height)
        #expect(stadium.width > stadium.height)
        #expect(diamond.shape == .diamond)
        #expect(stadium.shape == .stadium)
    }

    @Test("clusters enclose their members and carry their titles")
    func clustersEncloseMembers() throws {
        let result = try layout(MermaidSamples.clusteredFlowchart)

        #expect(result.subgraphs.count == 2)
        for subgraph in result.subgraphs {
            let memberIDs = subgraph.id == "frontend" ? ["UI", "API"] : ["Service", "DB"]
            for id in memberIDs {
                let node = try #require(result.node(id: id))
                #expect(node.x - node.width / 2 >= subgraph.x)
                #expect(node.x + node.width / 2 <= subgraph.x + subgraph.width)
                #expect(node.y - node.height / 2 >= subgraph.y)
                #expect(node.y + node.height / 2 <= subgraph.y + subgraph.height)
            }
        }
        #expect(result.subgraphs.map(\.title) == ["Front end", "Back end"])
    }

    @Test("a cycle lays out without hanging and keeps every edge")
    func cycleTerminates() throws {
        let result = try layout(MermaidSamples.cyclicFlowchart)

        #expect(result.nodes.count == 3)
        #expect(result.edges.count == 3)
    }

    @Test("state diagram markers are small and its states are ranked")
    func stateDiagramShape() throws {
        let result = try layout(MermaidSamples.minimalStateDiagram)
        let start = try #require(result.node(id: "__start"))
        let idle = try #require(result.node(id: "Idle"))
        let running = try #require(result.node(id: "Running"))

        #expect(start.width == 14)
        #expect(start.height == 14)
        #expect(start.y < idle.y)
        #expect(idle.y < running.y)
    }

    @Test("style statements reach the layout as colours")
    func styleColors() throws {
        let result = try layout(MermaidSamples.styledFlowchart)
        let a = try #require(result.node(id: "A"))
        let b = try #require(result.node(id: "B"))

        #expect(a.fillColor == "#f9f")
        #expect(a.strokeColor == "#333")
        #expect(b.fillColor == nil)
    }

    @Test("frontmatter spacing widens the layout")
    func frontmatterSpacing() throws {
        func height(rankSpacing: Int) throws -> Double {
            try layout(
                """
                ---
                config:
                  flowchart:
                    rankSpacing: \(rankSpacing)
                ---
                graph TD
                  A --> B
                """
            ).height
        }

        #expect(try height(rankSpacing: 200) > (try height(rankSpacing: 20)))
    }

    @Test("a single node still produces a usable canvas")
    func singleNode() throws {
        let result = try layout("graph TD\n  Only[Just one]")

        #expect(result.nodes.count == 1)
        #expect(result.width > 0)
        #expect(result.height > 0)
    }
}

@Suite("SVG rendering")
struct MermaidSVGTests {
    private func render(_ source: String, theme: MermaidTheme? = nil) throws -> String {
        try MermaidRenderer.render(source, theme: theme)
    }

    @Test("the document is well formed and self contained")
    func documentStructure() throws {
        for sample in MermaidSamples.all {
            let svg = try render(sample.source)

            #expect(svg.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg "), "\(sample.name)")
            #expect(svg.hasSuffix("</svg>\n"), "\(sample.name)")
            #expect(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""), "\(sample.name)")
            #expect(svg.contains("<defs>"), "\(sample.name)")
            // Nothing may reference an external resource.
            #expect(!svg.contains("http://") || svg.contains("http://www.w3.org/2000/svg"), "\(sample.name)")
            #expect(!svg.contains("<script"), "\(sample.name)")
            #expect(!svg.contains("xlink:href"), "\(sample.name)")
        }
    }

    @Test("themes reach the output")
    func themeColors() throws {
        let light = try render(MermaidSamples.minimalFlowchart, theme: .light)
        let dark = try render(MermaidSamples.minimalFlowchart, theme: .dark)

        #expect(light.contains(MermaidTheme.light.nodeFill))
        #expect(light.contains("background-color: \(MermaidTheme.light.background);"))
        #expect(dark.contains(MermaidTheme.dark.nodeFill))
        #expect(dark.contains("background-color: \(MermaidTheme.dark.background);"))
        #expect(light != dark)
    }

    @Test("frontmatter picks the theme when the caller does not")
    func frontmatterTheme() throws {
        let svg = try render(
            """
            ---
            config:
              theme: forest
            ---
            graph TD
              A --> B
            """
        )
        #expect(svg.contains(MermaidTheme.forest.nodeFill))
    }

    @Test("each shape draws its own element")
    func shapeElements() throws {
        let svg = try render(
            """
            graph TD
              A[rect] --> B(round)
              B --> C([stadium])
              C --> D{diamond}
              D --> E{{hex}}
              E --> F[(cyl)]
              F --> G[[sub]]
              G --> H((circle))
              H --> I>flag]
            """
        )

        #expect(svg.contains("<rect "))
        #expect(svg.contains("<polygon "))
        #expect(svg.contains("<circle "))
        #expect(svg.contains("<ellipse "))
        #expect(svg.contains("<line "))
        #expect(svg.contains("<path "))
    }

    @Test("edge styles produce their markers and dashes")
    func edgeStyleAttributes() throws {
        let svg = try render(
            """
            graph TD
              A --> B
              B -.-> C
              C ==> D
              D --- E
            """
        )

        #expect(svg.contains("url(#arrowhead)"))
        #expect(svg.contains("url(#arrowhead-thick)"))
        #expect(svg.contains("stroke-dasharray=\"3 3\""))
        #expect(svg.contains("stroke-width=\"3.5\""))
    }

    @Test("labels are XML-escaped rather than injected")
    func labelEscaping() throws {
        let svg = try render("graph TD\n  A[\"<b>bold</b> & 'quotes'\"] --> B")

        #expect(svg.contains("&lt;b&gt;bold&lt;/b&gt; &amp; &#39;quotes&#39;"))
        #expect(!svg.contains("<b>bold</b>"))
    }

    @Test("a label that looks like markup cannot close the text element")
    func labelCannotBreakOut() throws {
        let svg = try render("graph TD\n  A[\"</text><script>x</script>\"] --> B")

        #expect(!svg.contains("<script>"))
        #expect(svg.contains("&lt;/text&gt;&lt;script&gt;"))
    }

    @Test("a linear curve setting changes the path commands")
    func linearCurve() throws {
        let basis = try render(MermaidSamples.branchingFlowchart)
        let linear = try render(
            """
            ---
            config:
              flowchart:
                curve: linear
            ---
            \(MermaidSamples.branchingFlowchart)
            """
        )

        #expect(basis.contains("C"))
        #expect(linear != basis)
    }

    @Test("subgraph titles are drawn")
    func subgraphTitles() throws {
        let svg = try render(MermaidSamples.clusteredFlowchart)

        #expect(svg.contains(">Front end<"))
        #expect(svg.contains(">Back end<"))
    }

    @Test("coordinates never come out as NaN, infinite, or a negative zero")
    func numericFormatting() throws {
        // Substring checks would trip over ordinary markup ("dominant-baseline"
        // contains "nan"), so every numeric attribute value is parsed instead.
        let numericAttributes = ["x", "y", "cx", "cy", "r", "rx", "ry", "width", "height"]

        for sample in MermaidSamples.all {
            let svg = try render(sample.source)
            #expect(!svg.contains("\"-0.0\""), "\(sample.name)")

            for attribute in numericAttributes {
                for value in Self.attributeValues(named: attribute, in: svg) {
                    let parsed = Double(value)
                    #expect(parsed != nil, "\(sample.name): \(attribute)=\"\(value)\"")
                    #expect(parsed?.isFinite == true, "\(sample.name): \(attribute)=\"\(value)\"")
                }
            }
        }
    }

    /// Every value of `name="…"` in `svg`, matching whole attribute names only.
    private static func attributeValues(named name: String, in svg: String) -> [String] {
        var values: [String] = []
        var remainder = Substring(svg)
        while let start = remainder.range(of: " \(name)=\"") {
            remainder = remainder[start.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { break }
            values.append(String(remainder[..<end]))
            remainder = remainder[end...]
        }
        return values
    }
}

@Suite("Determinism")
struct MermaidDeterminismTests {
    @Test("rendering the same source twice is byte-identical")
    func renderTwice() throws {
        for sample in MermaidSamples.all {
            let first = try MermaidRenderer.render(sample.source)
            let second = try MermaidRenderer.render(sample.source)
            #expect(first == second, "\(sample.name) is not reproducible")
        }
    }

    @Test("rendering stays identical across interleaved renders")
    func renderInterleaved() throws {
        let reference = try MermaidRenderer.render(MermaidSamples.branchingFlowchart)

        for sample in MermaidSamples.all {
            _ = try MermaidRenderer.render(sample.source)
        }

        #expect(try MermaidRenderer.render(MermaidSamples.branchingFlowchart) == reference)
    }

    @Test("layout geometry is identical across runs")
    func layoutTwice() throws {
        for sample in MermaidSamples.all {
            let first = MermaidRenderer.layout(try MermaidRenderer.parse(sample.source))
            let second = MermaidRenderer.layout(try MermaidRenderer.parse(sample.source))
            #expect(first == second, "\(sample.name) layout is not reproducible")
        }
    }

    @Test("ten consecutive renders all agree")
    func manyRenders() throws {
        let reference = try MermaidRenderer.render(MermaidSamples.clusteredFlowchart)
        for _ in 0..<10 {
            #expect(try MermaidRenderer.render(MermaidSamples.clusteredFlowchart) == reference)
        }
    }
}

@Suite("Renderer API")
struct MermaidRendererAPITests {
    @Test("parse reports the family it recognized")
    func recognizedFamilies() throws {
        #expect(try MermaidRenderer.parse(MermaidSamples.minimalFlowchart).kind == .flowchart)
        #expect(try MermaidRenderer.parse(MermaidSamples.minimalStateDiagram).kind == .stateDiagram)
        #expect(try MermaidRenderer.parse("flowchart LR\n  A --> B").kind == .flowchart)
    }

    @Test("frontmatter title is carried on the diagram")
    func diagramTitle() throws {
        let diagram = try MermaidRenderer.parse(
            """
            ---
            title: Flow of things
            ---
            graph TD
              A --> B
            """
        )
        #expect(diagram.title == "Flow of things")
    }

    @Test("unsupported families are reported by name")
    func unsupportedFamilies() {
        for family in ["sequenceDiagram", "classDiagram", "erDiagram", "pie", "gantt", "mindmap"] {
            #expect(throws: MermaidError.unsupportedDiagramType(family)) {
                try MermaidRenderer.parse("\(family)\n  something")
            }
        }
    }

    @Test("an empty source is a parse error, not a crash")
    func emptySource() {
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse("")
        }
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse("   \n\n  ")
        }
    }

    @Test("aspect ratio describes the canvas for a terminal fit")
    func aspectRatio() throws {
        let layout = MermaidRenderer.layout(try MermaidRenderer.parse(MermaidSamples.minimalFlowchart))
        let ratio = MermaidTerminalRendering.aspectRatio(layout)

        #expect(ratio > 0)
        #expect(abs(ratio - layout.width / layout.height) < 1e-9)
    }
}
