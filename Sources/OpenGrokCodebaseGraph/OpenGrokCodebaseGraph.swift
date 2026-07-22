// OpenGrokCodebaseGraph.swift
//
// High-performance code graph: definitions, references, initial indexing,
// and incremental reindexing. Port of xai-codebase-graph.
//
// Extraction uses deterministic language heuristics (tree-sitter in Rust);
// the public index / navigator / manager contracts match the Rust surface.

import Foundation
