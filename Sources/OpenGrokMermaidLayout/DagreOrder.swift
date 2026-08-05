// DagreOrder.swift
//
// Open Grok — Swift port of `dagre_rust::layout::order`
// (third_party/dagre_rust/src/layout/order/*.rs, W8-S2).
//
// Ordering decides the left-to-right sequence of nodes within each rank so that
// edge crossings are minimized. The heuristic is the classic median/barycenter
// sweep: repeatedly reorder one rank by the average position of its neighbors in
// the adjacent rank, keeping whichever sweep produced the fewest crossings.

enum DagreOrder {
    /// Which side of a layer the sweep pulls positions from.
    enum Relationship {
        case inEdges
        case outEdges
    }

    /// Assigns `order` to every node, minimizing crossings.
    static func run(_ g: DagreGraph) {
        let maxRank = DagreUtil.maxRank(g)
        let downLayerRanks = maxRank >= 1 ? Array(1...maxRank) : []
        let upLayerRanks = maxRank >= 1 ? Array((0..<maxRank).reversed()) : []

        var layering = initOrder(g)
        assignOrder(g, layering)

        // Upstream dagre.js starts at infinity, so the first sweep always wins.
        // Seeding with the initial ordering instead keeps a sweep from swapping
        // in a mirrored layout that ties on crossings but reads worse.
        var bestCrossings = crossCount(g, layering)
        var best = layering

        var i = 0
        var sweepsSinceImprovement = 0
        while sweepsSinceImprovement < 4 {
            if i % 2 != 0 {
                sweep(g, ranks: downLayerRanks, relationship: .inEdges, biasRight: i % 4 >= 2)
            } else {
                sweep(g, ranks: upLayerRanks, relationship: .outEdges, biasRight: i % 4 >= 2)
            }

            layering = DagreUtil.buildLayerMatrix(g)
            let crossings = crossCount(g, layering)
            if crossings < bestCrossings {
                sweepsSinceImprovement = 0
                best = layering
                bestCrossings = crossings
            }

            sweepsSinceImprovement += 1
            i += 1
        }

        assignOrder(g, best)
    }

    private static func sweep(
        _ g: DagreGraph,
        ranks: [Int],
        relationship: Relationship,
        biasRight: Bool
    ) {
        let constraintGraph = DagreGraph.makeDagreGraph()

        for rank in ranks {
            let layerGraph = buildLayerGraph(g, rank: rank, relationship: relationship)
            let root = layerGraph.graphLabel.root ?? graphRootNodeID
            let sorted = sortSubgraph(layerGraph, root, constraintGraph, biasRight: biasRight)
            for (index, v) in sorted.vs.enumerated() {
                g.withNode(v) { $0.order = index }
            }
            addSubgraphConstraints(layerGraph, constraintGraph, sorted.vs)
        }
    }

    private static func assignOrder(_ g: DagreGraph, _ layering: [[String]]) {
        for layer in layering {
            for (index, v) in layer.enumerated() {
                g.withNode(v) { $0.order = index }
            }
        }
    }

    // MARK: - Initial order

    /// Seeds `order` with a depth-first walk from the topmost rank, which tends
    /// to keep connected components together.
    static func initOrder(_ g: DagreGraph) -> [[String]] {
        var visited = Set<String>()
        var simpleNodes = g.nodes().filter { g.children($0).isEmpty }
        let maxRank = simpleNodes.map { g.node($0)?.rank ?? 0 }.max() ?? 0
        var layers: [[String]] = Array(repeating: [], count: max(maxRank + 1, 0))

        func visit(_ v: String) {
            guard visited.insert(v).inserted else { return }
            guard let node = g.node(v) else { return }
            let rank = node.rank ?? 0
            if rank >= 0 {
                while layers.count <= rank {
                    layers.append([])
                }
                layers[rank].append(v)
            }
            for successor in g.successors(v) ?? [] {
                visit(successor)
            }
        }

        // A stable sort keeps declaration order within a rank.
        simpleNodes = simpleNodes.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = g.node(lhs.element)?.rank ?? 0
                let rhsRank = g.node(rhs.element)?.rank ?? 0
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        for v in simpleNodes {
            visit(v)
        }

        return layers
    }

    // MARK: - Layer graph

    /// Builds the small graph used to sort one rank: the rank's nodes with
    /// their cluster hierarchy, plus the neighbors they are pulled toward.
    static func buildLayerGraph(
        _ g: DagreGraph,
        rank: Int,
        relationship: Relationship
    ) -> DagreGraph {
        let root = createRootNode(g)
        let result = DagreGraph.makeDagreGraph(directed: true, multigraph: false, compound: true)
        result.withGraphLabel { $0.root = root }

        for v in g.nodes() {
            guard let node = g.node(v) else { continue }
            let parent = g.parent(v)

            let inRank = node.rank == rank
            let inSubgraphRank: Bool
            if let minRank = node.minRank, let maxRank = node.maxRank {
                inSubgraphRank = minRank <= rank && rank <= maxRank
            } else {
                inSubgraphRank = false
            }
            guard inRank || inSubgraphRank else { continue }

            let incident: [GraphEdgeRef]
            switch relationship {
            case .inEdges: incident = g.inEdges(v) ?? []
            case .outEdges: incident = g.outEdges(v) ?? []
            }

            result.setNode(v, node)
            try? result.setParent(v, parent ?? root)

            // Assumes normalization has left only single-rank edges.
            for e in incident {
                let u = (e.v == v) ? e.w : e.v
                let existingWeight = result.edge(u, v)?.weight ?? 0
                var edgeLabel = DagreEdge()
                edgeLabel.weight = (g.edge(e)?.weight ?? 0) + existingWeight
                try? result.setEdge(u, v, edgeLabel)
            }

            if node.minRank != nil {
                // Clusters are represented in the layer graph only by the border
                // pair for this rank; their other attributes would confuse the
                // barycenter pass.
                var clusterNode = DagreNode()
                clusterNode.borderLeftForRank = node.borderLeft?[rank]
                clusterNode.borderRightForRank = node.borderRight?[rank]
                result.setNode(v, clusterNode)
            }
        }

        return result
    }

    private static func createRootNode(_ g: DagreGraph) -> String {
        var v = "_root\(g.nextUniqueID())"
        while g.hasNode(v) {
            v = "_root\(g.nextUniqueID())"
        }
        return v
    }

    // MARK: - Barycenters

    /// A node's pull toward the adjacent rank: the weighted mean of its
    /// in-neighbors' positions.
    struct BarycenterEntry {
        var v: String
        var barycenter: Float?
        var weight: Float?
    }

    static func barycenters(_ g: DagreGraph, movable: [String]) -> [BarycenterEntry] {
        movable.map { v in
            let incoming = g.inEdges(v) ?? []
            guard !incoming.isEmpty else {
                return BarycenterEntry(v: v, barycenter: nil, weight: nil)
            }

            var sum = 0.0
            var weight = 0.0
            for e in incoming {
                let edgeWeight = Double(g.edge(e)?.weight ?? 0)
                let order = Double(g.node(e.v)?.order ?? 0)
                sum += edgeWeight * order
                weight += edgeWeight
            }

            return BarycenterEntry(v: v, barycenter: Float(sum / weight), weight: Float(weight))
        }
    }

    // MARK: - Conflict resolution

    /// A barycenter entry after constraint resolution: `vs` may be several
    /// nodes coalesced into one movable unit.
    struct ResolvedEntry {
        var vs: [String]
        var index: Int
        var barycenter: Float?
        var weight: Float?
    }

    private struct ConflictEntry {
        var indegree: Int = 0
        var ins: [Int] = []
        var outs: [Int] = []
        var vs: [String]
        var index: Int
        var barycenter: Float?
        var weight: Float?
        var merged = false
    }

    /// Coalesces entries whose barycenters would violate a constraint-graph
    /// edge, following Forster, "A Fast and Simple Heuristic for Constrained
    /// Two-Level Crossing Reduction."
    static func resolveConflicts(
        _ entries: [BarycenterEntry],
        _ constraintGraph: DagreGraph
    ) -> [ResolvedEntry] {
        var indexByID: [String: Int] = [:]
        var mapped: [ConflictEntry] = []
        mapped.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            indexByID[entry.v] = index
            mapped.append(
                ConflictEntry(
                    vs: [entry.v],
                    index: index,
                    barycenter: entry.barycenter,
                    weight: entry.weight
                )
            )
        }

        for e in constraintGraph.edges() {
            guard let vIndex = indexByID[e.v], let wIndex = indexByID[e.w] else { continue }
            mapped[wIndex].indegree += 1
            mapped[vIndex].outs.append(wIndex)
        }

        var sourceSet = mapped.enumerated().compactMap { $0.element.indegree == 0 ? $0.offset : nil }
        var order: [Int] = []

        while let vIndex = sourceSet.popLast() {
            order.append(vIndex)

            for uIndex in mapped[vIndex].ins.reversed() {
                handleIn(&mapped, vIndex, uIndex)
            }
            for wIndex in mapped[vIndex].outs {
                mapped[wIndex].ins.append(vIndex)
                mapped[wIndex].indegree -= 1
                if mapped[wIndex].indegree == 0 {
                    sourceSet.append(wIndex)
                }
            }
        }

        return order.filter { !mapped[$0].merged }.map { index in
            let entry = mapped[index]
            return ResolvedEntry(
                vs: entry.vs,
                index: entry.index,
                barycenter: entry.barycenter,
                weight: entry.weight
            )
        }
    }

    private static func handleIn(_ entries: inout [ConflictEntry], _ vIndex: Int, _ uIndex: Int) {
        guard !entries[uIndex].merged else { return }
        let u = entries[uIndex].barycenter
        let v = entries[vIndex].barycenter
        if u == nil || v == nil || u! >= v! {
            mergeEntries(&entries, target: vIndex, source: uIndex)
        }
    }

    private static func mergeEntries(_ entries: inout [ConflictEntry], target: Int, source: Int) {
        var sum: Float = 0
        var weight: Float = 0

        if let barycenter = entries[target].barycenter, let entryWeight = entries[target].weight {
            sum += barycenter * entryWeight
            weight += entryWeight
        }
        if let barycenter = entries[source].barycenter, let entryWeight = entries[source].weight {
            sum += barycenter * entryWeight
            weight += entryWeight
        }

        entries[target].vs = entries[source].vs + entries[target].vs
        entries[target].barycenter = sum / weight
        entries[target].weight = weight
        entries[target].index = min(entries[source].index, entries[target].index)
        entries[source].merged = true
    }

    // MARK: - Sorting

    /// The ordering of one subgraph plus its aggregate barycenter.
    struct SubgraphResult {
        var vs: [String] = []
        var barycenter: Float?
        var weight: Float?
    }

    static func sort(_ entries: [ResolvedEntry], biasRight: Bool) -> SubgraphResult {
        let parts = DagreUtil.partition(entries) { $0.barycenter != nil }
        // Stable sorts: entries that tie on barycenter keep the order their
        // `index` field encodes, which is what `compareWithBias` falls back to.
        var sortable = parts.matching
        var unsortable = parts.rest

        sortable = stableSorted(sortable) { compareWithBias($0, $1, biasRight) }
        // Descending by index, so the lowest index is popped from the back first.
        unsortable = stableSorted(unsortable) { $0.index > $1.index }

        var vs: [[String]] = []
        var sum: Float = 0
        var weight: Float = 0
        var index = 0

        index = consumeUnsortable(&vs, &unsortable, index)
        for entry in sortable {
            index += entry.vs.count
            vs.append(entry.vs)
            let entryWeight = entry.weight ?? 0
            sum += (entry.barycenter ?? 0) * entryWeight
            weight += entryWeight
            index = consumeUnsortable(&vs, &unsortable, index)
        }

        var result = SubgraphResult()
        result.vs = vs.flatMap { $0 }
        if weight != 0 {
            result.barycenter = sum / weight
            result.weight = weight
        }
        return result
    }

    /// Emits every barycenter-less entry whose original index has been reached,
    /// so unmovable nodes stay where they were declared.
    private static func consumeUnsortable(
        _ vs: inout [[String]],
        _ unsortable: inout [ResolvedEntry],
        _ index: Int
    ) -> Int {
        var index = index
        while let last = unsortable.last, last.index <= index {
            unsortable.removeLast()
            vs.append(last.vs)
            index += 1
        }
        return index
    }

    private static func compareWithBias(
        _ lhs: ResolvedEntry,
        _ rhs: ResolvedEntry,
        _ biasRight: Bool
    ) -> Bool {
        let lhsBarycenter = lhs.barycenter ?? 0
        let rhsBarycenter = rhs.barycenter ?? 0
        if lhsBarycenter != rhsBarycenter { return lhsBarycenter < rhsBarycenter }
        return biasRight ? lhs.index > rhs.index : lhs.index < rhs.index
    }

    /// Swift's `sort` is not guaranteed stable; the sweep depends on ties
    /// keeping their relative order, so sort on `(element, position)` pairs.
    private static func stableSorted<Element>(
        _ elements: [Element],
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) -> [Element] {
        elements.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Orders one cluster's children, recursing into nested clusters and
    /// pinning the cluster's own border nodes to the ends.
    static func sortSubgraph(
        _ g: DagreGraph,
        _ v: String,
        _ constraintGraph: DagreGraph,
        biasRight: Bool
    ) -> SubgraphResult {
        var movable = g.children(v)
        let node = g.node(v)
        let borderLeft = node?.borderLeftForRank
        let borderRight = node?.borderRightForRank
        var subgraphs = OrderedDictionary<String, SubgraphResult>()

        if let borderLeft, let borderRight {
            movable = movable.filter { $0 != borderLeft && $0 != borderRight }
        }

        var entries = barycenters(g, movable: movable)
        for index in entries.indices where !g.children(entries[index].v).isEmpty {
            let subgraphResult = sortSubgraph(g, entries[index].v, constraintGraph, biasRight: biasRight)
            subgraphs.insert(subgraphResult, forKey: entries[index].v)
            if subgraphResult.barycenter != nil {
                mergeBarycenters(&entries[index], subgraphResult)
            }
        }

        var resolved = resolveConflicts(entries, constraintGraph)
        expandSubgraphs(&resolved, subgraphs)

        var result = sort(resolved, biasRight: biasRight)
        if let borderLeft, let borderRight {
            result.vs = [borderLeft] + result.vs + [borderRight]

            // Pull the cluster toward its borders' predecessors so it does not
            // drift away from the rank above.
            let leftPredecessors = g.predecessors(borderLeft) ?? []
            let rightPredecessors = g.predecessors(borderRight) ?? []
            if let leftFirst = leftPredecessors.first,
               let rightFirst = rightPredecessors.first,
               let leftNode = g.node(leftFirst),
               let rightNode = g.node(rightFirst) {
                let leftOrder = Float(leftNode.order ?? 0)
                let rightOrder = Float(rightNode.order ?? 0)
                let barycenter = result.barycenter ?? 0
                let weight = result.weight ?? 0
                result.barycenter = (barycenter * weight + leftOrder + rightOrder) / (weight + 2)
                result.weight = weight + 2
            }
        }

        return result
    }

    private static func expandSubgraphs(
        _ entries: inout [ResolvedEntry],
        _ subgraphs: OrderedDictionary<String, SubgraphResult>
    ) {
        for index in entries.indices {
            var vs: [String] = []
            for v in entries[index].vs {
                if let subgraph = subgraphs[v] {
                    vs.append(contentsOf: subgraph.vs)
                } else {
                    vs.append(v)
                }
            }
            entries[index].vs = vs
        }
    }

    private static func mergeBarycenters(_ target: inout BarycenterEntry, _ other: SubgraphResult) {
        guard let otherBarycenter = other.barycenter, let otherWeight = other.weight else { return }

        if let targetBarycenter = target.barycenter, let targetWeight = target.weight {
            target.barycenter =
                (targetBarycenter * targetWeight + otherBarycenter * otherWeight)
                / (targetWeight + otherWeight)
            target.weight = targetWeight + otherWeight
        } else {
            target.barycenter = otherBarycenter
            target.weight = otherWeight
        }
    }

    // MARK: - Subgraph constraints

    /// Records, in `constraintGraph`, that clusters already placed must not be
    /// interleaved by a later sweep.
    static func addSubgraphConstraints(
        _ g: DagreGraph,
        _ constraintGraph: DagreGraph,
        _ vs: [String]
    ) {
        var previous = OrderedDictionary<String, String>()
        var rootPrevious: String?

        for v in vs {
            var child = g.parent(v)
            while let currentChild = child {
                let parent = g.parent(currentChild)
                let previousChild: String?
                if let parent {
                    previousChild = previous[parent]
                    previous.insert(currentChild, forKey: parent)
                } else {
                    previousChild = rootPrevious
                    rootPrevious = currentChild
                }

                if let previousChild, previousChild != currentChild {
                    try? constraintGraph.setEdge(previousChild, currentChild)
                    break
                }
                child = parent
            }
        }
    }

    // MARK: - Crossing count

    /// Total weighted edge crossings across the whole layering.
    static func crossCount(_ g: DagreGraph, _ layering: [[String]]) -> Float {
        var total: Float = 0
        for i in 1..<max(layering.count, 1) {
            total += twoLayerCrossCount(g, layering[i - 1], layering[i])
        }
        return total
    }

    /// Weighted crossings between two adjacent ranks, counted with the
    /// accumulator tree from Barth et al., "Bilayer Cross Counting."
    static func twoLayerCrossCount(
        _ g: DagreGraph,
        _ northLayer: [String],
        _ southLayer: [String]
    ) -> Float {
        var southPosition: [String: Int] = [:]
        for (index, v) in southLayer.enumerated() {
            southPosition[v] = index
        }

        var southEntries: [(position: Int, weight: Float)] = []
        for v in northLayer {
            var outgoing: [(position: Int, weight: Float)] = (g.outEdges(v) ?? []).compactMap { e in
                guard let position = southPosition[e.w] else { return nil }
                return (position, g.edge(e)?.weight ?? 0)
            }
            outgoing = stableSorted(outgoing) { $0.position < $1.position }
            southEntries.append(contentsOf: outgoing)
        }

        var firstIndex = 1
        while firstIndex < southLayer.count {
            firstIndex <<= 1
        }
        let treeSize = 2 * firstIndex - 1
        firstIndex -= 1

        var tree = [Float](repeating: 0, count: treeSize)
        var crossings: Float = 0

        for entry in southEntries {
            var index = entry.position + firstIndex
            guard index < tree.count else { continue }
            tree[index] += entry.weight

            var weightSum: Float = 0
            while index > 0 {
                if index % 2 != 0 {
                    weightSum += tree[index + 1]
                }
                index = (index - 1) >> 1
                tree[index] += entry.weight
            }
            crossings += entry.weight * weightSum
        }

        return crossings
    }
}
