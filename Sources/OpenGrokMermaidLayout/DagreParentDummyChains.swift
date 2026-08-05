// DagreParentDummyChains.swift
//
// Open Grok — Swift port of `dagre_rust::layout::parent_dummy_chains`
// (third_party/dagre_rust/src/layout/parent_dummy_chains.rs, W8-S2).
//
// When `normalize` splits a long edge into a chain of dummy nodes, each dummy
// must be adopted by the right cluster, or the edge will be drawn cutting
// through cluster walls. Each chain walks up from its source to the lowest
// common ancestor of the edge's endpoints and back down to its target.

enum DagreParentDummyChains {
    static func run(_ g: DagreGraph) {
        let postOrderNumbers = postorderIntervals(g)
        let dummyChains = g.graphLabel.dummyChains ?? []

        for chainStart in dummyChains {
            guard let startNode = g.node(chainStart), let edgeObj = startNode.edgeObj else { continue }
            let (path, lowestCommonAncestor) = findPath(
                g,
                postOrderNumbers: postOrderNumbers,
                from: edgeObj.v,
                to: edgeObj.w
            )

            var v = chainStart
            var pathIndex = 0
            var pathV: String? = pathIndex < path.count ? path[pathIndex] : lowestCommonAncestor
            var ascending = true

            while v != edgeObj.w {
                guard let node = g.node(v) else { break }
                let nodeRank = node.rank ?? 0

                if ascending {
                    // Climb out of the source's clusters until one is deep
                    // enough to still contain this rank.
                    while true {
                        pathV = pathIndex < path.count ? path[pathIndex] : lowestCommonAncestor
                        if pathV == lowestCommonAncestor {
                            ascending = false
                            break
                        }
                        guard let pathVID = pathV, let candidate = g.node(pathVID) else { break }
                        if (candidate.maxRank ?? 0) < nodeRank {
                            pathIndex += 1
                            continue
                        }
                        break
                    }
                }

                if !ascending {
                    // Descend into the target's clusters as soon as this rank
                    // reaches them.
                    while pathIndex < path.count - 1 {
                        guard let nextID = path[pathIndex + 1], let next = g.node(nextID) else { break }
                        if (next.minRank ?? 0) <= nodeRank {
                            pathIndex += 1
                        } else {
                            break
                        }
                    }
                    pathV = pathIndex < path.count ? path[pathIndex] : lowestCommonAncestor
                }

                try? g.setParent(v, pathV)

                guard let next = g.successors(v)?.first else { break }
                v = next
            }
        }
    }

    /// The cluster path from `v` up to the lowest common ancestor of `v` and
    /// `w`, then down to `w`. Entries are cluster ids; a nil entry is the
    /// top level.
    private static func findPath(
        _ g: DagreGraph,
        postOrderNumbers: OrderedDictionary<String, (low: Int, lim: Int)>,
        from v: String,
        to w: String
    ) -> (path: [String?], lowestCommonAncestor: String?) {
        var upward: [String?] = []
        var downward: [String?] = []

        let vNumbers = postOrderNumbers[v] ?? (low: 0, lim: 0)
        let wNumbers = postOrderNumbers[w] ?? (low: 0, lim: 0)
        let low = min(vNumbers.low, wNumbers.low)
        let lim = max(vNumbers.lim, wNumbers.lim)

        var parent: String? = v
        while true {
            parent = parent.flatMap { g.parent($0) }
            upward.append(parent)

            guard let parentID = parent, let numbers = postOrderNumbers[parentID] else { break }
            if numbers.low <= low && lim <= numbers.lim {
                break
            }
        }

        let lowestCommonAncestor = parent

        parent = w
        while true {
            parent = parent.flatMap { g.parent($0) }
            if parent == lowestCommonAncestor { break }
            downward.append(parent)
            if parent == nil { break }
        }

        return (upward + downward.reversed(), lowestCommonAncestor)
    }

    /// Postorder `(low, lim)` interval for every cluster, so ancestry can be
    /// tested with two comparisons.
    private static func postorderIntervals(
        _ g: DagreGraph
    ) -> OrderedDictionary<String, (low: Int, lim: Int)> {
        var result = OrderedDictionary<String, (low: Int, lim: Int)>()
        var lim = 0

        func visit(_ v: String) {
            let low = lim
            for child in g.children(v) {
                visit(child)
            }
            result.insert((low: low, lim: lim), forKey: v)
            lim += 1
        }

        for v in g.children(graphRootNodeID) {
            visit(v)
        }
        return result
    }
}
