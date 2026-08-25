import Testing

@testable import OpenGrokMermaid

@Suite("Pinned Rust .82 Mermaid visualization family parity")
struct MermaidVisualizationFamilyParityTests {
    @Test("pie slices preserve quantitative values and render actual proportional sectors")
    func pieChart() throws {
        let diagram = try MermaidRenderer.parse(
            """
            pie showData
              title Browser share
              "Safari" : 60
              "Firefox" : 25
              "Other" : 15
            """
        )
        #expect(diagram.kind == .pie)
        #expect(diagram.title == "Browser share")
        guard case let .pie(chart)? = diagram.visualization else {
            Issue.record("pie semantic model missing")
            return
        }
        #expect(chart.showData)
        #expect(chart.slices.map(\.value) == [60, 25, 15])
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("aria-roledescription=\"pie\""))
        #expect(svg.contains(" A "))
        #expect(svg.contains("Safari [60]"))
        #expect(svg.contains("60%"))
    }

    @Test("mindmap indentation creates a genuine hierarchy with distinct node shapes")
    func mindmapHierarchy() throws {
        let diagram = try MermaidRenderer.parse(
            """
            mindmap
              root((Product))
                Research[Research]
                  Interviews(User interviews)
                Build{{Engineering}}
            """
        )
        #expect(diagram.kind == .mindmap)
        guard case let .mindmap(tree)? = diagram.visualization else {
            Issue.record("mindmap semantic model missing")
            return
        }
        #expect(tree.nodes.map(\.label) == ["Product", "Research", "User interviews", "Engineering"])
        #expect(tree.nodes.map(\.depth) == [0, 1, 2, 1])
        #expect(tree.nodes[0].shape == .circle)
        #expect(tree.nodes[3].shape == .hexagon)
        let layout = MermaidRenderer.layout(diagram)
        #expect(layout.nodes.count == 4)
        #expect(layout.edges.count == 3)
        #expect((layout.node(id: tree.nodes[0].id)?.x ?? 0) < (layout.node(id: tree.nodes[2].id)?.x ?? 0))
        let svg = try MermaidRenderer.render(
            "mindmap\n  root((Product))\n    Design[Design]\n    Delivery(Delivery)"
        )
        #expect(svg.contains("Product"))
        #expect(svg.contains("Design"))
        #expect(svg.contains("Delivery"))
    }

    @Test("timeline periods retain ordered events and section membership")
    func timelineChronology() throws {
        let diagram = try MermaidRenderer.parse(
            """
            timeline
              title Product history
              section Discovery
                2024 : Initial research
                  : Customer interviews
              section Launch
                2025 : Public release
            """
        )
        #expect(diagram.kind == .timeline)
        guard case let .timeline(timeline)? = diagram.visualization else {
            Issue.record("timeline semantic model missing")
            return
        }
        #expect(timeline.events.map(\.period) == ["2024", "2025"])
        #expect(timeline.events[0].events == ["Initial research", "Customer interviews"])
        #expect(timeline.events.map(\.section) == ["Discovery", "Launch"])
        let svg = try MermaidRenderer.render(
            "timeline\n title Product history\n 2024 : Research\n 2025 : Release"
        )
        for label in ["Product history", "2024", "Research", "2025", "Release"] {
            #expect(svg.contains(label))
        }
    }

    @Test("journey scores and actors remain visible in ordered task nodes")
    func journeyScoresAndActors() throws {
        let diagram = try MermaidRenderer.parse(
            """
            journey
              title A customer day
              section Sign up
                Visit website: 4: Customer
                Verify email: 3: Customer, Support
              section Success
                Complete onboarding: 5: Customer
            """
        )
        #expect(diagram.kind == .journey)
        guard case let .journey(journey)? = diagram.visualization else {
            Issue.record("journey semantic model missing")
            return
        }
        #expect(journey.tasks.map(\.score) == [4, 3, 5])
        #expect(journey.tasks[1].actors == ["Customer", "Support"])
        #expect(MermaidRenderer.layout(diagram).edges.count == 2)
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("A customer day"))
        #expect(svg.contains("Score: 3/5"))
        #expect(svg.contains("Customer, Support"))
    }

    @Test("gantt tasks preserve dates, sections, durations and dependency bars")
    func ganttSchedule() throws {
        let diagram = try MermaidRenderer.parse(
            """
            gantt
              title Release plan
              dateFormat YYYY-MM-DD
              section Engineering
              Build product : build, 2026-08-20, 5d
              Ship release : ship, after build, 1w
            """
        )
        #expect(diagram.kind == .gantt)
        guard case let .gantt(chart)? = diagram.visualization else {
            Issue.record("gantt semantic model missing")
            return
        }
        #expect(chart.tasks.map(\.durationDays) == [5, 7])
        #expect(chart.tasks[1].dependencyID == "build")
        #expect(chart.tasks[1].startDay == chart.tasks[0].startDay + 5)
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("aria-roledescription=\"gantt\""))
        #expect(svg.contains("Release plan"))
        #expect(svg.contains("Build product"))
        #expect(svg.contains("Ship release"))
        #expect(svg.contains("stroke-dasharray=\"4 4\""))
    }

    @Test("git branches and merge commits retain their actual parent topology")
    func gitGraphTopology() throws {
        let diagram = try MermaidRenderer.parse(
            """
            gitGraph
              commit id: "root"
              branch feature
              checkout feature
              commit id: "work" tag: "v1"
              checkout main
              commit id: "mainline"
              merge feature
            """
        )
        #expect(diagram.kind == .gitGraph)
        guard case let .gitGraph(graph)? = diagram.visualization else {
            Issue.record("git graph semantic model missing")
            return
        }
        #expect(graph.branches == ["main", "feature"])
        #expect(graph.commits.count == 4)
        #expect(graph.commits[1].tag == "v1")
        #expect(graph.commits[3].isMerge)
        #expect(Set(graph.commits[3].parentIDs) == Set(["mainline", "work"]))
        let layout = MermaidRenderer.layout(diagram)
        #expect(layout.edges.count == 4)
        #expect(layout.node(id: graph.commits[3].id)?.shape == .diamond)
    }

    @Test("kanban columns preserve cards, assignment, priority and ticket metadata")
    func kanbanBoard() throws {
        let diagram = try MermaidRenderer.parse(
            """
            kanban
            Backlog
              Research @{ assigned: "Alice", priority: "High", ticket: "DS-1" }
            In progress
              Build renderer @{ assigned: "Bob" }
            Done
              Ship docs
            """
        )
        #expect(diagram.kind == .kanban)
        guard case let .kanban(board)? = diagram.visualization else {
            Issue.record("kanban semantic model missing")
            return
        }
        #expect(board.columns.map(\.title) == ["Backlog", "In progress", "Done"])
        #expect(board.columns[0].tasks[0].assigned == "Alice")
        #expect(board.columns[0].tasks[0].priority == "High")
        #expect(board.columns[0].tasks[0].ticket == "DS-1")
        let layout = MermaidRenderer.layout(diagram)
        #expect(layout.subgraphs.count == 3)
        let svg = MermaidRenderer.svg(layout, diagram: diagram)
        #expect(svg.contains("Backlog"))
        #expect(svg.contains("@Alice"))
        #expect(svg.contains("DS-1"))
    }

    @Test("quadrant axes and normalized point coordinates reach a real chart surface")
    func quadrantCoordinates() throws {
        let diagram = try MermaidRenderer.parse(
            """
            quadrantChart
              title Prioritization
              x-axis Low effort --> High effort
              y-axis Low impact --> High impact
              quadrant-1 Strategic
              quadrant-2 Quick wins
              Search: [0.2, 0.8]
              Migration: [0.8, 0.6]
            """
        )
        #expect(diagram.kind == .quadrantChart)
        guard case let .quadrantChart(chart)? = diagram.visualization else {
            Issue.record("quadrant semantic model missing")
            return
        }
        #expect(chart.points.map(\.x) == [0.2, 0.8])
        #expect(chart.xAxis?.low == "Low effort")
        #expect(chart.quadrantLabels[2] == "Quick wins")
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        for text in ["Prioritization", "Low effort", "High impact", "Strategic", "Search", "Migration"] {
            #expect(svg.contains(text))
        }
        #expect(svg.contains("<circle "))
    }

    @Test("xy charts plot category-aligned line series and ignore unsupported upstream bars")
    func xyChartSeries() throws {
        let diagram = try MermaidRenderer.parse(
            """
            xychart-beta
              title "Revenue"
              x-axis [Jan, Feb, Mar]
              y-axis "Dollars" 0 --> 100
              bar [25, 50, 75]
              line [20, 55, 70]
              line [25, 50, 75]
            """
        )
        #expect(diagram.kind == .xyChart)
        guard case let .xyChart(chart)? = diagram.visualization else {
            Issue.record("xy chart semantic model missing")
            return
        }
        #expect(chart.categories == ["Jan", "Feb", "Mar"])
        #expect(chart.series.map(\.isBar) == [false, false])
        #expect(chart.series.map(\.values) == [[20, 55, 70], [25, 50, 75]])
        #expect(chart.yMinimum == 0)
        #expect(chart.yMaximum == 100)
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("Revenue"))
        #expect(svg.contains("Dollars"))
        #expect(svg.contains("Jan"))
        #expect(svg.contains("<path "))
    }

    @Test("radar axes and curves produce closed weighted polygons")
    func radarCurves() throws {
        let diagram = try MermaidRenderer.parse(
            """
            radar-beta
              axis Speed, Reliability, Cost
              curve Current { 3, 4, 2 }
              curve Target { 5, 5, 4 }
            """
        )
        #expect(diagram.kind == .radar)
        guard case let .radar(chart)? = diagram.visualization else {
            Issue.record("radar semantic model missing")
            return
        }
        #expect(chart.axes == ["Speed", "Reliability", "Cost"])
        #expect(chart.curves[1].values == [5, 5, 4])
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("<polygon "))
        #expect(svg.contains("Speed"))
        #expect(svg.contains("Target"))
    }

    @Test("sankey flows preserve directional endpoints and quantitative widths")
    func sankeyWeightedFlows() throws {
        let diagram = try MermaidRenderer.parse(
            """
            sankey-beta
              Solar,Grid,70
              Wind,Grid,30
              Grid,Homes,80
              Grid,Industry,20
            """
        )
        #expect(diagram.kind == .sankey)
        guard case let .sankey(flow)? = diagram.visualization else {
            Issue.record("sankey semantic model missing")
            return
        }
        #expect(flow.nodes == ["Solar", "Grid", "Wind", "Homes", "Industry"])
        #expect(flow.links.map(\.value) == [70, 30, 80, 20])
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("aria-roledescription=\"sankey\""))
        #expect(svg.contains(" C "))
        #expect(svg.contains("Solar"))
        #expect(svg.contains("Industry"))
    }

    @Test("packet diagrams retain contiguous bit ranges and render real field cells")
    func packetBitRanges() throws {
        let diagram = try MermaidRenderer.parse(
            """
            packet-beta
              title IPv4 header
              0-3: "Version"
              4-7: "IHL"
              8-15: "Type of Service"
              16-31: "Total Length"
              32-47: "Identification"
            """
        )
        #expect(diagram.kind == .packet)
        guard case let .packet(packet)? = diagram.visualization else {
            Issue.record("packet semantic model missing")
            return
        }
        #expect(packet.fields.map(\.firstBit) == [0, 4, 8, 16, 32])
        #expect(packet.fields.last?.lastBit == 47)
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("IPv4 header"))
        #expect(svg.contains("Type of Service"))
        #expect(svg.contains("Identification"))
    }

    @Test("requirements retain typed properties and explicit validation relationships")
    func requirementPropertiesAndEdges() throws {
        let diagram = try MermaidRenderer.parse(
            """
            requirementDiagram
              requirement latency {
                id: REQ-1
                text: Respond within 100ms
                risk: high
                verifyMethod: test
              }
              element api {
                type: service
                docRef: architecture.md
              }
              api - satisfies -> latency
            """
        )
        #expect(diagram.kind == .requirementDiagram)
        guard case let .requirementDiagram(requirements)? = diagram.visualization else {
            Issue.record("requirement semantic model missing")
            return
        }
        #expect(requirements.nodes.map(\.id) == ["latency", "api"])
        #expect(requirements.nodes[0].properties.contains { $0.name == "risk" && $0.value == "high" })
        #expect(requirements.relationships[0].kind == "satisfies")
        let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
        #expect(svg.contains("REQ-1"))
        #expect(svg.contains("Respond within 100ms"))
        #expect(svg.contains("satisfies"))
    }

    @Test("block diagrams preserve column directives, labels and edges")
    func blockNodesAndEdges() throws {
        let diagram = try MermaidRenderer.parse(
            """
            block-beta
              columns 2
              api["Public API"]
              db["Database"]
              api --> db
            """
        )
        #expect(diagram.kind == .blockDiagram)
        guard case let .blockDiagram(block)? = diagram.visualization else {
            Issue.record("block diagram semantic model missing")
            return
        }
        #expect(block.columns == 2)
        #expect(block.nodes.map(\.id) == ["api", "db"])
        #expect(block.nodes.map(\.label) == ["Public API", "Database"])
        #expect(block.edges.count == 1)
        #expect(try MermaidRenderer.render("block-beta\n service[Service]\n service --> cache[Cache]").contains("Cache"))
    }

    @Test("all five C4 families preserve component types, labels and relationships")
    func c4FamilyDispatch() throws {
        for family in ["C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment"] {
            let diagram = try MermaidRenderer.parse(
                """
                \(family)
                title Banking architecture
                Person(customer, "Customer", "A customer")
                System(bank, "Internet Banking", "Shows balances")
                Rel(customer, bank, "Uses")
                """
            )
            #expect(diagram.kind == .c4Diagram)
            guard case let .c4Diagram(architecture)? = diagram.visualization else {
                Issue.record("C4 semantic model missing for \(family)")
                continue
            }
            #expect(architecture.family == family)
            #expect(architecture.nodes.map(\.id) == ["customer", "bank"])
            #expect(architecture.relationships.first?.label == "Uses")
            let svg = MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram)
            #expect(svg.contains("Customer"))
            #expect(svg.contains("Internet Banking"))
            #expect(svg.contains("Uses"))
        }
    }

    @Test("info diagrams surface the exact upstream Mermaid version")
    func infoVersion() throws {
        let diagram = try MermaidRenderer.parse("info")
        #expect(diagram.kind == .information)
        guard case let .information(version)? = diagram.visualization else {
            Issue.record("info semantic model missing")
            return
        }
        #expect(version == "11.12.2")
        #expect(try MermaidRenderer.render("info").contains("Mermaid v11.12.2"))
    }
}

@Suite("Additional Mermaid visualization rejection and source safety")
struct MermaidVisualizationFamilyErrorParityTests {
    @Test("each newly supported family rejects empty or structurally invalid diagrams")
    func malformedFamiliesFailVisibly() {
        let invalid = [
            "pie\n\"A\": 0",
            "pie\n\"A\": 1\n\"A\": 2",
            "pie\n\"A\": nan",
            "mindmap",
            "mindmap\n root\n second",
            "timeline\n : orphan",
            "journey\n Bad score: 8: Alice",
            "gantt\n Task: id, 2026-02-30, 2d",
            "gantt\n Task: id, after missing, 2d",
            "gitGraph\n checkout missing",
            "kanban\n  task without a column",
            "quadrantChart\n Point: [1.5, 0.3]",
            "xychart-beta\n x-axis [Jan, Feb]\n line [2]",
            "xychart-beta\n bar [1, 2, 3]",
            "radar-beta\n axis Speed, Reliability\n curve A {1,2}",
            "sankey-beta\n A,B,-2",
            "packet-beta\n 0-3: One\n 8-9: Gap",
            "requirementDiagram\n requirement open {\n id: REQ-1",
            "block-beta\n columns 0",
            "C4Context\n Rel(a, b, \"Uses\")",
            "info\n extra",
        ]
        for source in invalid {
            #expect(throws: MermaidError.self) {
                try MermaidRenderer.render(source)
            }
        }
    }

    @Test("CRLF, frontmatter, inline semicolons, comments and titles survive chart dispatch")
    func lineAndFrontmatterParity() throws {
        let source = "---\r\ntitle: Frontmatter title\r\nconfig:\r\n  theme: dark\r\n---\r\n"
            + "%%{init: {'theme': 'dark'}}%%\r\npie showData; title Inline title; \"Safe; value\" : 2; \"Other\" : 1"
        let diagram = try MermaidRenderer.parse(source)
        #expect(diagram.kind == .pie)
        #expect(diagram.title == "Frontmatter title")
        #expect(diagram.config.theme == .dark)
        guard case let .pie(chart)? = diagram.visualization else {
            Issue.record("pie metadata missing")
            return
        }
        #expect(chart.title == "Inline title")
        #expect(chart.slices.first?.label == "Safe; value")
        #expect(MermaidRenderer.svg(MermaidRenderer.layout(diagram), diagram: diagram).contains(MermaidTheme.dark.background))
    }

    @Test("terminal controls fail closed and XML-shaped labels remain escaped")
    func terminalAndXMLSafety() throws {
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.render("pie\n\"bad\u{001B}[31m\": 1")
        }
        let svg = try MermaidRenderer.render("pie\n\"</text><script>alert(1)</script>\": 1")
        #expect(!svg.contains("<script>"))
        #expect(svg.contains("&lt;/text&gt;&lt;script&gt;"))
    }

    @Test("supported-family inventory matches genuine dispatch and unsupported flowchart variants stay loud")
    func publicFamilyInventory() {
        let newFamilies: Set<String> = [
            "pie", "mindmap", "timeline", "journey", "gantt", "gitGraph", "kanban",
            "quadrantChart", "xychart-beta", "radar-beta", "sankey-beta", "packet-beta",
            "requirementDiagram", "block-beta", "C4Context", "C4Container", "C4Component",
            "C4Dynamic", "C4Deployment", "info",
        ]
        #expect(newFamilies.isSubset(of: MermaidDiagramFamily.supported))
        #expect(MermaidDiagramFamily.supported.isDisjoint(with: MermaidDiagramFamily.knownButUnsupported))
        #expect(MermaidDiagramFamily.knownButUnsupported.contains("flowchart-elk"))
        #expect(throws: MermaidError.unsupportedDiagramType("flowchart-elk")) {
            try MermaidRenderer.parse("flowchart-elk\n A --> B")
        }
        #expect(throws: MermaidError.unsupportedDiagramType("pie")) {
            try parseFlowchart("pie\n\"one\": 1")
        }
    }

    @Test("visualization rendering is deterministic across every specialized SVG surface")
    func deterministicVisualizations() throws {
        let sources = [
            "pie\n\"A\": 2\n\"B\": 1",
            "gantt\nTask: work, 2026-08-20, 3d",
            "quadrantChart\nPoint: [0.4, 0.8]",
            "xychart-beta\nline [1, 2, 3]",
            "radar-beta\naxis A, B, C\ncurve One {1,2,3}",
            "sankey-beta\nA,B,2",
            "packet-beta\n0-3: Head\n4-7: Tail",
            "info",
        ]
        for source in sources {
            #expect(try MermaidRenderer.render(source) == (try MermaidRenderer.render(source)))
        }
    }

    @Test("node caps and pathological source sizes stop before runaway layout")
    func boundedVisualizationInput() {
        let slices = (0...128).map { "\"slice\($0)\": 1" }.joined(separator: "\n")
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse("pie\n\(slices)")
        }

        let source = "pie\n\"\(String(repeating: "x", count: 1_048_577))\": 1"
        #expect(throws: MermaidError.self) {
            try MermaidRenderer.parse(source)
        }
    }
}
