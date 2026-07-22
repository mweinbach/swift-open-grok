// OrderedModelMap.swift
//
// Insertion-ordered map keyed by catalog id, matching Rust `IndexMap`.
// Catalog iteration order is load-bearing for first-visible fallbacks and
// last-slug-match resume semantics.

import Foundation

/// Ordered map of catalog key → `ModelEntry`.
public struct OrderedModelMap: Sendable, Equatable {
    public private(set) var keys: [String]
    private var storage: [String: ModelEntry]

    public init() {
        self.keys = []
        self.storage = [:]
    }

    public init(_ pairs: [(String, ModelEntry)]) {
        self.keys = []
        self.storage = [:]
        for (k, v) in pairs {
            self[k] = v
        }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public subscript(key: String) -> ModelEntry? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil {
                    keys.append(key)
                }
                storage[key] = newValue
            } else {
                removeValue(forKey: key)
            }
        }
    }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> ModelEntry? {
        guard let value = storage.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return value
    }

    /// Remove and return the value if present, preserving IndexMap shift_remove semantics.
    @discardableResult
    public mutating func shiftRemove(_ key: String) -> ModelEntry? {
        removeValue(forKey: key)
    }

    public mutating func reserveCapacity(_ n: Int) {
        keys.reserveCapacity(n)
        storage.reserveCapacity(n)
    }

    public mutating func retain(_ shouldKeep: (String, ModelEntry) -> Bool) {
        var nextKeys: [String] = []
        var nextStorage: [String: ModelEntry] = [:]
        for key in keys {
            if let entry = storage[key], shouldKeep(key, entry) {
                nextKeys.append(key)
                nextStorage[key] = entry
            }
        }
        keys = nextKeys
        storage = nextStorage
    }

    public var first: (key: String, value: ModelEntry)? {
        guard let key = keys.first, let value = storage[key] else { return nil }
        return (key, value)
    }

    public func getKeyValue(_ key: String) -> (key: String, value: ModelEntry)? {
        guard let value = storage[key] else { return nil }
        return (key, value)
    }

    public func values() -> [ModelEntry] {
        keys.compactMap { storage[$0] }
    }

    public func pairs() -> [(String, ModelEntry)] {
        keys.compactMap { key in
            guard let value = storage[key] else { return nil }
            return (key, value)
        }
    }

    public mutating func mergePreservingOrder(_ other: OrderedModelMap, uniquingKeysWith combine: (ModelEntry, ModelEntry) -> ModelEntry = { _, new in new }) {
        for (key, entry) in other.pairs() {
            if let existing = storage[key] {
                storage[key] = combine(existing, entry)
            } else {
                self[key] = entry
            }
        }
    }
}

extension OrderedModelMap: Sequence {
    public func makeIterator() -> Array<(String, ModelEntry)>.Iterator {
        pairs().makeIterator()
    }
}
