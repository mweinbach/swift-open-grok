// GraphTraversal.swift
//
// Open Grok — Swift port of `graphlib_rust::algo`
// (third_party/graphlib_rust/src/algo/{dfs,preorder,postorder}.rs, W8-S2).

/// Visit order for `depthFirstSearch(_:from:order:)`.
public enum DFSOrder: Sendable {
    case preorder
    case postorder
}

extension Graph {
    /// Depth-first traversal from each id in `roots`, returning nodes in visit
    /// order. Directed graphs navigate by successors, undirected by neighbors.
    ///
    /// Returns nil if any root is absent, matching the Rust `dfs`, which errors
    /// in that case.
    public func depthFirstSearch(from roots: [String], order: DFSOrder) -> [String]? {
        var accumulator: [String] = []
        var visited = Set<String>()
        for root in roots {
            guard hasNode(root) else { return nil }
            switch order {
            case .preorder:
                preorderDFS(root, visited: &visited, into: &accumulator)
            case .postorder:
                postorderDFS(root, visited: &visited, into: &accumulator)
            }
        }
        return accumulator
    }

    /// Postorder traversal, empty when a root is missing.
    /// Matches `graphlib_rust::algo::postorder::postorder`.
    public func postorder(from roots: [String]) -> [String] {
        depthFirstSearch(from: roots, order: .postorder) ?? []
    }

    /// Preorder traversal, empty when a root is missing.
    ///
    /// Deviation: upstream `pre_order_dfs` indexes one past the end of the
    /// navigation list and panics on any node with successors. The corrected
    /// form below pushes children in reverse so they pop in declaration order,
    /// mirroring the postorder walk. Nothing in the Dagre pipeline calls
    /// preorder, so this cannot change layout output.
    public func preorder(from roots: [String]) -> [String] {
        depthFirstSearch(from: roots, order: .preorder) ?? []
    }

    private func navigation(_ v: String) -> [String] {
        isDirected ? (successors(v) ?? []) : (neighbors(v) ?? [])
    }

    private func preorderDFS(_ root: String, visited: inout Set<String>, into accumulator: inout [String]) {
        var stack = [root]
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            accumulator.append(current)
            for next in navigation(current).reversed() {
                stack.append(next)
            }
        }
    }

    private func postorderDFS(_ root: String, visited: inout Set<String>, into accumulator: inout [String]) {
        var stack: [(node: String, expanded: Bool)] = [(root, false)]
        while let current = stack.popLast() {
            if current.expanded {
                accumulator.append(current.node)
                continue
            }
            guard visited.insert(current.node).inserted else { continue }
            stack.append((current.node, true))
            for next in navigation(current.node).reversed() {
                stack.append((next, false))
            }
        }
    }
}
