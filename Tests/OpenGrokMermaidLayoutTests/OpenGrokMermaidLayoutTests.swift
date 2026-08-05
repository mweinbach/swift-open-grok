import Testing

@testable import OpenGrokMermaidLayout

@Suite("Ordered dictionary")
struct OrderedDictionaryTests {
    @Test("iteration follows first-insertion order, not hashing")
    func insertionOrder() {
        var map = OrderedDictionary<String, Int>()
        for (index, key) in ["zeta", "alpha", "mu", "beta"].enumerated() {
            map.insert(index, forKey: key)
        }

        #expect(map.orderedKeys == ["zeta", "alpha", "mu", "beta"])
        #expect(map.values == [0, 1, 2, 3])
    }

    @Test("re-inserting a key updates in place and keeps its position")
    func reinsertKeepsPosition() {
        var map = OrderedDictionary<String, Int>()
        map.insert(1, forKey: "a")
        map.insert(2, forKey: "b")
        let previous = map.insert(99, forKey: "a")

        #expect(previous == 1)
        #expect(map.orderedKeys == ["a", "b"])
        #expect(map["a"] == 99)
    }

    @Test("removal drops the key from the order")
    func removal() {
        var map = OrderedDictionary<String, Int>()
        map.insert(1, forKey: "a")
        map.insert(2, forKey: "b")
        map.insert(3, forKey: "c")

        #expect(map.removeValue(forKey: "b") == 2)
        #expect(map.orderedKeys == ["a", "c"])
        #expect(map.removeValue(forKey: "b") == nil)
        #expect(map.count == 2)
    }

    @Test("extend appends only unseen keys, in the other map's order")
    func extend() {
        var first = OrderedDictionary<String, Int>()
        first.insert(1, forKey: "a")
        var second = OrderedDictionary<String, Int>()
        second.insert(20, forKey: "b")
        second.insert(30, forKey: "a")

        first.extend(second)

        #expect(first.orderedKeys == ["a", "b"])
        #expect(first["a"] == 30)
        #expect(first["b"] == 20)
    }

    @Test("in-place mutation keeps ordering")
    func mutationInPlace() {
        var map = OrderedDictionary<String, Int>()
        map.insert(1, forKey: "a")
        map.insert(2, forKey: "b")
        map.mapValuesInPlace { $0 *= 10 }
        map.withValue(forKey: "a") { $0 += 5 }

        #expect(map.entries.map(\.value) == [15, 20])
    }
}

@Suite("Graph model")
struct GraphModelTests {
    private func makeGraph(
        directed: Bool = true,
        multigraph: Bool = false,
        compound: Bool = false
    ) -> DagreGraph {
        DagreGraph.makeDagreGraph(directed: directed, multigraph: multigraph, compound: compound)
    }

    @Test("nodes and edges report in declaration order")
    func declarationOrder() throws {
        let g = makeGraph()
        for id in ["c", "a", "b"] {
            g.setNode(id, DagreNode())
        }
        try g.setEdge("c", "a")
        try g.setEdge("a", "b")

        #expect(g.nodes() == ["c", "a", "b"])
        #expect(g.edges().map { "\($0.v)->\($0.w)" } == ["c->a", "a->b"])
        #expect(g.nodeCount == 3)
        #expect(g.edgeCount == 2)
    }

    @Test("setEdge creates missing endpoints")
    func edgeCreatesEndpoints() throws {
        let g = makeGraph()
        try g.setEdge("x", "y")

        #expect(g.hasNode("x"))
        #expect(g.hasNode("y"))
        #expect(g.successors("x") == ["y"])
        #expect(g.predecessors("y") == ["x"])
    }

    @Test("removing a node removes its incident edges")
    func removeNodeCascades() throws {
        let g = makeGraph()
        try g.setEdge("a", "b")
        try g.setEdge("b", "c")

        g.removeNode("b")

        #expect(g.nodes() == ["a", "c"])
        #expect(g.edgeCount == 0)
        #expect(g.predecessors("c") == [])
    }

    @Test("undirected edges normalize their endpoint order")
    func undirectedNormalization() throws {
        let g = makeGraph(directed: false)
        try g.setEdge("z", "a")

        #expect(g.hasEdge("a", "z"))
        #expect(g.hasEdge("z", "a"))
        #expect(g.edges().count == 1)
        #expect(g.edges()[0].v == "a")
    }

    @Test("a named edge on a simple graph is rejected")
    func namedEdgeRejected() {
        let g = makeGraph()
        #expect(throws: GraphError.namedEdgeOnSimpleGraph) {
            try g.setEdge("a", "b", nil, name: "n")
        }
    }

    @Test("compound graphs track parents and children")
    func compoundHierarchy() throws {
        let g = makeGraph(compound: true)
        g.setNode("cluster", DagreNode())
        g.setNode("a", DagreNode())
        g.setNode("b", DagreNode())
        try g.setParent("a", "cluster")
        try g.setParent("b", "cluster")

        #expect(g.parent("a") == "cluster")
        #expect(g.children("cluster") == ["a", "b"])
        #expect(g.children(graphRootNodeID) == ["cluster"])
        #expect(g.parent("cluster") == nil)
    }

    @Test("a parent cycle is refused")
    func parentCycleRefused() throws {
        let g = makeGraph(compound: true)
        g.setNode("a", DagreNode())
        g.setNode("b", DagreNode())
        try g.setParent("b", "a")

        #expect(throws: GraphError.cycleInParentChain(child: "a", parent: "b")) {
            try g.setParent("a", "b")
        }
    }

    @Test("setting a parent on a non-compound graph is refused")
    func parentOnSimpleGraphRefused() {
        let g = makeGraph()
        g.setNode("a", DagreNode())
        #expect(throws: GraphError.notCompound) {
            try g.setParent("a", nil)
        }
    }

    @Test("multigraph keeps parallel named edges apart")
    func multigraphNamedEdges() throws {
        let g = makeGraph(multigraph: true)
        try g.setEdge("a", "b", nil, name: "first")
        try g.setEdge("a", "b", nil, name: "second")

        #expect(g.edgeCount == 2)
        #expect(g.outEdges("a")?.count == 2)
    }

    @Test("neighbors deduplicate and keep predecessor-then-successor order")
    func neighborOrder() throws {
        let g = makeGraph()
        try g.setEdge("p", "v")
        try g.setEdge("v", "s")
        try g.setEdge("shared", "v")
        try g.setEdge("v", "shared")

        #expect(g.neighbors("v") == ["p", "shared", "s"])
    }

    @Test("sources and sinks")
    func sourcesAndSinks() throws {
        let g = makeGraph()
        try g.setEdge("a", "b")
        try g.setEdge("b", "c")

        #expect(g.sources() == ["a"])
        #expect(g.sinks() == ["c"])
    }
}

@Suite("Graph traversal")
struct GraphTraversalTests {
    @Test("postorder visits children before parents")
    func postorder() throws {
        let g = DagreGraph.makeDagreGraph()
        try g.setEdge("a", "b")
        try g.setEdge("a", "c")
        try g.setEdge("b", "d")

        #expect(g.postorder(from: ["a"]) == ["d", "b", "c", "a"])
    }

    @Test("preorder visits parents before children")
    func preorder() throws {
        let g = DagreGraph.makeDagreGraph()
        try g.setEdge("a", "b")
        try g.setEdge("a", "c")
        try g.setEdge("b", "d")

        #expect(g.preorder(from: ["a"]) == ["a", "b", "d", "c"])
    }

    @Test("a cycle terminates the walk instead of hanging")
    func cycleTerminates() throws {
        let g = DagreGraph.makeDagreGraph()
        try g.setEdge("a", "b")
        try g.setEdge("b", "a")

        #expect(g.postorder(from: ["a"]).count == 2)
    }

    @Test("a missing root yields no nodes")
    func missingRoot() {
        let g = DagreGraph.makeDagreGraph()
        #expect(g.postorder(from: ["nope"]).isEmpty)
        #expect(g.depthFirstSearch(from: ["nope"], order: .preorder) == nil)
    }
}

@Suite("Ranking")
struct RankingTests {
    private func chain(_ ids: [String], minlen: Float = 1) throws -> DagreGraph {
        let g = DagreGraph.makeDagreGraph()
        for id in ids {
            var node = DagreNode()
            node.width = 40
            node.height = 20
            g.setNode(id, node)
        }
        for (from, to) in zip(ids, ids.dropFirst()) {
            var edge = DagreEdge()
            edge.minlen = minlen
            edge.weight = 1
            try g.setEdge(from, to, edge)
        }
        return g
    }

    @Test("longest path ranks a chain into consecutive layers")
    func longestPathChain() throws {
        let g = try chain(["a", "b", "c", "d"])
        DagreRank.longestPath(g)
        DagreUtil.normalizeRanks(g)

        #expect(g.nodes().map { g.node($0)?.rank } == [0, 1, 2, 3])
    }

    @Test("minlen widens the gap between ranks")
    func minlenRespected() throws {
        let g = try chain(["a", "b"], minlen: 3)
        DagreRank.longestPath(g)
        DagreUtil.normalizeRanks(g)

        #expect(g.node("a")?.rank == 0)
        #expect(g.node("b")?.rank == 3)
    }

    @Test("network simplex tightens a diamond")
    func networkSimplexDiamond() throws {
        let g = DagreGraph.makeDagreGraph()
        for id in ["a", "b", "c", "d"] {
            var node = DagreNode()
            node.width = 40
            node.height = 20
            g.setNode(id, node)
        }
        for (from, to) in [("a", "b"), ("b", "d"), ("a", "c"), ("c", "d")] {
            try g.setEdge(from, to, DagreEdge())
        }

        DagreRank.networkSimplex(g)
        DagreUtil.normalizeRanks(g)

        #expect(g.node("a")?.rank == 0)
        #expect(g.node("b")?.rank == 1)
        #expect(g.node("c")?.rank == 1)
        #expect(g.node("d")?.rank == 2)
    }

    @Test("slack is edge length minus its minimum")
    func slackMeasurement() throws {
        let g = try chain(["a", "b"])
        g.withNode("a") { $0.rank = 0 }
        g.withNode("b") { $0.rank = 4 }

        #expect(DagreRank.slack(g, g.edges()[0]) == 3)
    }

    @Test("equal-rank siblings keep declaration order")
    func equalRankStability() throws {
        let g = DagreGraph.makeDagreGraph()
        for id in ["root", "x", "y", "z"] {
            g.setNode(id, DagreNode())
        }
        for leaf in ["x", "y", "z"] {
            try g.setEdge("root", leaf, DagreEdge())
        }

        DagreRank.networkSimplex(g)
        DagreUtil.normalizeRanks(g)

        #expect(["x", "y", "z"].allSatisfy { g.node($0)?.rank == 1 })
        let layers = DagreOrder.initOrder(g)
        #expect(layers[1] == ["x", "y", "z"])
    }
}

@Suite("Ordering")
struct OrderingTests {
    @Test("crossing count is zero for a parallel layering")
    func noCrossings() throws {
        let g = DagreGraph.makeDagreGraph()
        try g.setEdge("a1", "b1", DagreEdge())
        try g.setEdge("a2", "b2", DagreEdge())

        #expect(DagreOrder.crossCount(g, [["a1", "a2"], ["b1", "b2"]]) == 0)
    }

    @Test("crossing count sees a swapped layering")
    func oneCrossing() throws {
        let g = DagreGraph.makeDagreGraph()
        try g.setEdge("a1", "b2", DagreEdge())
        try g.setEdge("a2", "b1", DagreEdge())

        #expect(DagreOrder.crossCount(g, [["a1", "a2"], ["b1", "b2"]]) == 1)
    }

    @Test("crossing count weights edges")
    func weightedCrossing() throws {
        let g = DagreGraph.makeDagreGraph()
        var heavy = DagreEdge()
        heavy.weight = 3
        try g.setEdge("a1", "b2", heavy)
        try g.setEdge("a2", "b1", DagreEdge())

        #expect(DagreOrder.crossCount(g, [["a1", "a2"], ["b1", "b2"]]) == 3)
    }

    @Test("ordering untangles a crossed bipartite graph")
    func untangleCrossing() throws {
        let g = DagreGraph.makeDagreGraph()
        for id in ["a1", "a2", "b1", "b2"] {
            var node = DagreNode()
            node.width = 30
            node.height = 20
            node.rank = id.hasPrefix("a") ? 0 : 1
            g.setNode(id, node)
        }
        try g.setEdge("a1", "b2", DagreEdge())
        try g.setEdge("a2", "b1", DagreEdge())

        DagreOrder.run(g)
        let layering = DagreUtil.buildLayerMatrix(g)

        #expect(DagreOrder.crossCount(g, layering) == 0)
    }

    @Test("barycenter is the weighted mean of in-neighbor positions")
    func barycenterMean() throws {
        let g = DagreGraph.makeDagreGraph()
        for (id, order) in [("u1", 0), ("u2", 4)] {
            var node = DagreNode()
            node.order = order
            g.setNode(id, node)
        }
        g.setNode("v", DagreNode())
        try g.setEdge("u1", "v", DagreEdge())
        try g.setEdge("u2", "v", DagreEdge())

        let entries = DagreOrder.barycenters(g, movable: ["v"])
        #expect(entries.count == 1)
        #expect(entries[0].barycenter == 2)
        #expect(entries[0].weight == 2)
    }

    @Test("a node with no in-edges has no barycenter")
    func barycenterAbsent() {
        let g = DagreGraph.makeDagreGraph()
        g.setNode("v", DagreNode())

        #expect(DagreOrder.barycenters(g, movable: ["v"])[0].barycenter == nil)
    }

    @Test("sorting keeps unmovable entries at their original index")
    func sortPinsUnmovable() {
        let entries = [
            DagreOrder.ResolvedEntry(vs: ["pinned"], index: 0, barycenter: nil, weight: nil),
            DagreOrder.ResolvedEntry(vs: ["late"], index: 1, barycenter: 9, weight: 1),
            DagreOrder.ResolvedEntry(vs: ["early"], index: 2, barycenter: 1, weight: 1),
        ]

        #expect(DagreOrder.sort(entries, biasRight: false).vs == ["pinned", "early", "late"])
    }

    @Test("ties break by index, and the bias flips which way")
    func tieBreaking() {
        let entries = [
            DagreOrder.ResolvedEntry(vs: ["first"], index: 0, barycenter: 5, weight: 1),
            DagreOrder.ResolvedEntry(vs: ["second"], index: 1, barycenter: 5, weight: 1),
        ]

        #expect(DagreOrder.sort(entries, biasRight: false).vs == ["first", "second"])
        #expect(DagreOrder.sort(entries, biasRight: true).vs == ["second", "first"])
    }
}

@Suite("Layout pipeline")
struct LayoutPipelineTests {
    /// A graph of uniformly sized nodes wired up by `edges`.
    private func makeGraph(
        nodes: [String],
        edges: [(String, String)],
        rankDirection: DagreRankDirection = .topToBottom
    ) throws -> DagreGraph {
        let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)
        var config = DagreGraphConfig()
        config.rankDirection = rankDirection
        g.graphLabel = config

        for id in nodes {
            var node = DagreNode()
            node.width = 60
            node.height = 30
            g.setNode(id, node)
        }
        for (from, to) in edges {
            try g.setEdge(from, to, DagreEdge())
        }
        return g
    }

    /// A stable textual dump of everything layout is allowed to decide.
    private func geometry(_ g: DagreGraph) -> String {
        var lines: [String] = []
        for v in g.nodes() {
            guard let node = g.node(v) else { continue }
            lines.append("node \(v) \(node.x) \(node.y) \(node.width) \(node.height)")
        }
        for e in g.edges() {
            guard let edge = g.edge(e) else { continue }
            let points = (edge.points ?? []).map { "(\($0.x),\($0.y))" }.joined(separator: " ")
            lines.append("edge \(e.v)->\(e.w) \(points)")
        }
        lines.append("canvas \(g.graphLabel.width)x\(g.graphLabel.height)")
        return lines.joined(separator: "\n")
    }

    @Test("a chain stacks downward with the first node on top")
    func chainStacksDownward() throws {
        let g = try makeGraph(nodes: ["a", "b", "c"], edges: [("a", "b"), ("b", "c")])
        DagreLayout.run(g)

        let a = try #require(g.node("a"))
        let b = try #require(g.node("b"))
        let c = try #require(g.node("c"))
        #expect(a.y < b.y)
        #expect(b.y < c.y)
        #expect(a.x == b.x)
        #expect(b.x == c.x)
        #expect(g.graphLabel.height > 0)
        #expect(g.graphLabel.width > 0)
    }

    @Test("left-to-right rank direction advances along x instead of y")
    func leftToRight() throws {
        let g = try makeGraph(
            nodes: ["a", "b", "c"],
            edges: [("a", "b"), ("b", "c")],
            rankDirection: .leftToRight
        )
        DagreLayout.run(g)

        let a = try #require(g.node("a"))
        let b = try #require(g.node("b"))
        let c = try #require(g.node("c"))
        #expect(a.x < b.x)
        #expect(b.x < c.x)
        #expect(a.y == c.y)
        #expect(a.width == 60)
        #expect(a.height == 30)
    }

    @Test("bottom-to-top rank direction inverts the stack")
    func bottomToTop() throws {
        let g = try makeGraph(
            nodes: ["a", "b"],
            edges: [("a", "b")],
            rankDirection: .bottomToTop
        )
        DagreLayout.run(g)

        let a = try #require(g.node("a"))
        let b = try #require(g.node("b"))
        #expect(a.y > b.y)
    }

    @Test("every edge gets a polyline ending on the node outlines")
    func edgesAreRouted() throws {
        let g = try makeGraph(nodes: ["a", "b"], edges: [("a", "b")])
        DagreLayout.run(g)

        let edge = try #require(g.edge(g.edges()[0]))
        let points = try #require(edge.points)
        #expect(points.count >= 2)

        let a = try #require(g.node("a"))
        let first = try #require(points.first)
        // The first point sits on a's boundary, half a height below its centre.
        #expect(abs(first.y - (a.y + a.height / 2)) < 0.001)
    }

    @Test("a cycle is laid out without hanging and keeps every edge")
    func cycleIsLaidOut() throws {
        let g = try makeGraph(
            nodes: ["a", "b", "c"],
            edges: [("a", "b"), ("b", "c"), ("c", "a")]
        )
        DagreLayout.run(g)

        #expect(g.edges().count >= 3)
        for e in g.edges() {
            #expect((g.edge(e)?.points?.count ?? 0) >= 2)
        }
    }

    @Test("a self loop becomes a stub beside its node")
    func selfLoop() throws {
        let g = try makeGraph(nodes: ["a", "b"], edges: [("a", "b"), ("a", "a")])
        DagreLayout.run(g)

        let selfEdge = try #require(g.edges().first { $0.v == "a" && $0.w == "a" })
        let points = try #require(g.edge(selfEdge)?.points)
        #expect(points.count >= 2)

        let a = try #require(g.node("a"))
        // The stub bulges out past a's right edge.
        #expect(points.contains { $0.x > a.x + a.width / 2 })
    }

    @Test("a long edge spanning several ranks is routed through waypoints")
    func longEdgeGetsWaypoints() throws {
        let g = try makeGraph(
            nodes: ["a", "b", "c", "d"],
            edges: [("a", "b"), ("b", "c"), ("c", "d"), ("a", "d")]
        )
        DagreLayout.run(g)

        let longEdge = try #require(g.edges().first { $0.v == "a" && $0.w == "d" })
        let points = try #require(g.edge(longEdge)?.points)
        #expect(points.count > 2)
    }

    @Test("edge labels reserve space and land between their endpoints")
    func edgeLabelPlacement() throws {
        let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)
        for id in ["a", "b"] {
            var node = DagreNode()
            node.width = 60
            node.height = 30
            g.setNode(id, node)
        }
        var edge = DagreEdge()
        edge.width = 40
        edge.height = 16
        try g.setEdge("a", "b", edge)

        DagreLayout.run(g)

        let laidOut = try #require(g.edge("a", "b"))
        let a = try #require(g.node("a"))
        let b = try #require(g.node("b"))
        #expect(laidOut.y > a.y)
        #expect(laidOut.y < b.y)
    }

    @Test("a cluster is sized around its members")
    func clusterEnclosesMembers() throws {
        let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)
        g.setNode("cluster", DagreNode())
        for id in ["a", "b", "outside"] {
            var node = DagreNode()
            node.width = 60
            node.height = 30
            g.setNode(id, node)
        }
        try g.setParent("a", "cluster")
        try g.setParent("b", "cluster")
        try g.setEdge("a", "b", DagreEdge())
        try g.setEdge("b", "outside", DagreEdge())

        DagreLayout.run(g)

        let cluster = try #require(g.node("cluster"))
        let a = try #require(g.node("a"))
        let b = try #require(g.node("b"))
        #expect(cluster.width > 0)
        #expect(cluster.height > 0)
        #expect(a.y >= cluster.y - cluster.height / 2)
        #expect(b.y <= cluster.y + cluster.height / 2)
    }

    @Test("an empty graph produces an empty canvas without crashing")
    func emptyGraph() {
        let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)
        DagreLayout.run(g)

        #expect(g.nodes().isEmpty)
    }

    @Test("a single node lands at the centre of its own box")
    func singleNode() throws {
        let g = try makeGraph(nodes: ["only"], edges: [])
        DagreLayout.run(g)

        let node = try #require(g.node("only"))
        #expect(node.x == 30)
        #expect(node.y == 15)
        #expect(g.graphLabel.width == 60)
        #expect(g.graphLabel.height == 30)
    }

    @Test("disconnected components are all placed")
    func disconnectedComponents() throws {
        let g = try makeGraph(
            nodes: ["a", "b", "c", "d"],
            edges: [("a", "b"), ("c", "d")]
        )
        DagreLayout.run(g)

        for id in ["a", "b", "c", "d"] {
            let node = try #require(g.node(id))
            #expect(node.x >= 0)
            #expect(node.y >= 0)
        }
    }

    @Test("laying out the same graph twice gives identical geometry")
    func determinismAcrossRuns() throws {
        func build() throws -> DagreGraph {
            try makeGraph(
                nodes: ["a", "b", "c", "d", "e", "f"],
                edges: [
                    ("a", "b"), ("a", "c"), ("b", "d"), ("c", "d"),
                    ("d", "e"), ("e", "f"), ("f", "a"), ("b", "f"),
                ]
            )
        }

        let first = try build()
        let second = try build()
        DagreLayout.run(first)
        DagreLayout.run(second)

        #expect(geometry(first) == geometry(second))
    }

    @Test("determinism holds for clustered graphs too")
    func determinismWithClusters() throws {
        func build() throws -> DagreGraph {
            let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)
            for id in ["top", "inner1", "inner2", "bottom"] {
                var node = DagreNode()
                node.width = 50
                node.height = 25
                g.setNode(id, node)
            }
            g.setNode("cluster", DagreNode())
            try g.setParent("inner1", "cluster")
            try g.setParent("inner2", "cluster")
            for (from, to) in [
                ("top", "inner1"), ("inner1", "inner2"), ("inner2", "bottom"), ("top", "bottom"),
            ] {
                try g.setEdge(from, to, DagreEdge())
            }
            return g
        }

        let first = try build()
        let second = try build()
        DagreLayout.run(first)
        DagreLayout.run(second)

        #expect(geometry(first) == geometry(second))
    }

    @Test("layout is independent of how many graphs ran before it")
    func determinismAcrossPriorRuns() throws {
        let warmup = try makeGraph(nodes: ["x", "y", "z"], edges: [("x", "y"), ("y", "z")])
        DagreLayout.run(warmup)

        let first = try makeGraph(nodes: ["a", "b", "c"], edges: [("a", "b"), ("a", "c")])
        DagreLayout.run(first)

        // Several more layouts in between. A process-wide dummy-id counter would
        // shift the ids used here; a graph-scoped one does not.
        for _ in 0..<3 {
            let noise = try makeGraph(nodes: ["p", "q"], edges: [("p", "q")])
            DagreLayout.run(noise)
        }

        let second = try makeGraph(nodes: ["a", "b", "c"], edges: [("a", "b"), ("a", "c")])
        DagreLayout.run(second)

        #expect(geometry(first) == geometry(second))
    }

    @Test("node separation widens the gap between siblings")
    func nodeSeparationApplied() throws {
        func layoutWithSeparation(_ separation: Float) throws -> Float {
            let g = try makeGraph(nodes: ["root", "l", "r"], edges: [("root", "l"), ("root", "r")])
            g.withGraphLabel { $0.nodeSeparation = separation }
            DagreLayout.run(g)
            let left = try #require(g.node("l"))
            let right = try #require(g.node("r"))
            return abs(right.x - left.x)
        }

        let narrow = try layoutWithSeparation(20)
        let wide = try layoutWithSeparation(200)
        #expect(wide > narrow)
    }

    @Test("rank separation widens the gap between layers")
    func rankSeparationApplied() throws {
        func layoutWithSeparation(_ separation: Float) throws -> Float {
            let g = try makeGraph(nodes: ["a", "b"], edges: [("a", "b")])
            g.withGraphLabel { $0.rankSeparation = separation }
            DagreLayout.run(g)
            let a = try #require(g.node("a"))
            let b = try #require(g.node("b"))
            return b.y - a.y
        }

        let wide = try layoutWithSeparation(200)
        let narrow = try layoutWithSeparation(20)
        #expect(wide > narrow)
    }

    @Test("intersectRect clips toward the rectangle centre")
    func intersectRectGeometry() {
        let rect = DagreRect(x: 10, y: 20, width: 8, height: 4)

        // A point at the centre falls back to the right edge.
        #expect(DagreUtil.intersectRect(rect, DagrePoint(x: 10, y: 20)) == DagrePoint(x: 14, y: 20))
        // Straight above clips to the top edge.
        #expect(DagreUtil.intersectRect(rect, DagrePoint(x: 10, y: 0)) == DagrePoint(x: 10, y: 18))
        // Straight right clips to the right edge.
        #expect(DagreUtil.intersectRect(rect, DagrePoint(x: 100, y: 20)) == DagrePoint(x: 14, y: 20))
    }

    @Test("build layer matrix groups nodes by rank and sorts by order")
    func layerMatrix() {
        let g = DagreGraph.makeDagreGraph()
        for (id, rank, order) in [("b", 1, 1), ("a", 0, 0), ("c", 1, 0)] {
            var node = DagreNode()
            node.rank = rank
            node.order = order
            g.setNode(id, node)
        }

        #expect(DagreUtil.buildLayerMatrix(g) == [["a"], ["c", "b"]])
    }
}
