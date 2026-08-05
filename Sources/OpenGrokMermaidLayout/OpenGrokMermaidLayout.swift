// OpenGrokMermaidLayout.swift
//
// Open Grok — Swift port of the layered graph-drawing stack that Mermaid
// diagrams are laid out with (PORT_PLAN.md W8-S2).
//
// This target is a port of three vendored third-party Rust crates, themselves
// ports of the JavaScript dagre project. See THIRD-PARTY-NOTICES for the full
// attribution chain (dagre_rust / graphlib_rust / ordered_hashmap, plus the
// mermaid.js / dagre.js / graphlib.js ancestry) and CRATE_MAP.md rows 1, 2, 4.
//
//   `OrderedDictionary`  <- third_party/ordered_hashmap
//   `Graph`, traversal   <- third_party/graphlib_rust
//   `DagreLayout` et al. <- third_party/dagre_rust
//
// Usage: build a `DagreGraph`, set each node's `width`/`height` and each edge's
// `weight`/`minlen`, then call `DagreLayout.run(_:)`. Nodes come back with
// centre coordinates, edges with routed polylines, and the graph label with the
// overall canvas size.
//
// Determinism is the contract this target owes its callers: every map that
// influences ordering is insertion-ordered, every sort is stable, and the dummy
// node id counter is scoped to a single graph. The same input therefore yields
// byte-identical geometry on every run and in every process.

/// Provenance of the algorithms this target implements.
public enum OpenGrokMermaidLayoutInfo {
    public static let provenance = """
        Dagre layered graph drawing (Gansner et al., "A Technique for Drawing \
        Directed Graphs"; Brandes and Köpf, "Fast and Simple Horizontal \
        Coordinate Assignment"; Barth et al., "Bilayer Cross Counting"), ported \
        from the vendored dagre_rust / graphlib_rust / ordered_hashmap crates.
        """
}
