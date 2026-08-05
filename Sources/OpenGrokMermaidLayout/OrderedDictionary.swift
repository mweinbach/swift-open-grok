// OrderedDictionary.swift
//
// Open Grok — Swift port of the `ordered_hashmap` crate
// (third_party/ordered_hashmap/src/lib.rs, W8-S2 / CRATE_MAP.md row 4).
//
// The Dagre and Graphlib ports below depend on insertion-ordered iteration for
// their determinism guarantee: the layout algorithms iterate nodes, edges, and
// intermediate maps in the order they were first inserted, so a given diagram
// source always produces byte-identical geometry. Swift's `Dictionary` seeds its
// hash per process, so iterating one directly would make layout vary run to run.
//
// Deviation from the Rust original: `values_mut`/`iter_mut` upstream escape
// through raw pointers (the crate's only `unsafe`). Swift expresses the same
// thing safely with `subscript` mutation and `withValue(forKey:)`.

/// An insertion-ordered map: iteration always yields entries in the order their
/// keys were first inserted, independent of hashing.
public struct OrderedDictionary<Key: Hashable, Value> {
    /// Keys in first-insertion order. Re-inserting an existing key keeps its
    /// original position.
    public private(set) var orderedKeys: [Key]
    private var storage: [Key: Value]

    public init() {
        self.orderedKeys = []
        self.storage = [:]
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public func containsKey(_ key: Key) -> Bool { storage[key] != nil }

    public subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            insert(newValue, forKey: key)
        }
    }

    /// Inserts or updates `key`, returning the previous value if there was one.
    @discardableResult
    public mutating func insert(_ value: Value, forKey key: Key) -> Value? {
        let previous = storage.updateValue(value, forKey: key)
        if previous == nil {
            orderedKeys.append(key)
        }
        return previous
    }

    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        guard let previous = storage.removeValue(forKey: key) else { return nil }
        if let index = orderedKeys.firstIndex(of: key) {
            orderedKeys.remove(at: index)
        }
        return previous
    }

    /// Mutates the value stored for `key` in place, if present.
    @discardableResult
    public mutating func withValue<R>(forKey key: Key, _ body: (inout Value) -> R) -> R? {
        guard var value = storage[key] else { return nil }
        let result = body(&value)
        storage[key] = value
        return result
    }

    /// Inserts `defaultValue` when `key` is absent, then mutates the stored value.
    @discardableResult
    public mutating func withValue<R>(
        forKey key: Key,
        default defaultValue: @autoclosure () -> Value,
        _ body: (inout Value) -> R
    ) -> R {
        if storage[key] == nil {
            insert(defaultValue(), forKey: key)
        }
        var value = storage[key]!
        let result = body(&value)
        storage[key] = value
        return result
    }

    /// Values in key-insertion order.
    public var values: [Value] {
        orderedKeys.compactMap { storage[$0] }
    }

    /// Key/value pairs in key-insertion order.
    public var entries: [(key: Key, value: Value)] {
        orderedKeys.compactMap { key in storage[key].map { (key: key, value: $0) } }
    }

    /// Adds every pair from `other` that this map does not already have a key
    /// for, appending new keys in `other`'s order.
    public mutating func extend(_ other: OrderedDictionary<Key, Value>) {
        for key in other.orderedKeys {
            guard let value = other.storage[key] else { continue }
            insert(value, forKey: key)
        }
    }

    /// Applies `transform` to every stored value, preserving key order.
    public mutating func mapValuesInPlace(_ transform: (inout Value) -> Void) {
        for key in orderedKeys {
            guard var value = storage[key] else { continue }
            transform(&value)
            storage[key] = value
        }
    }
}

extension OrderedDictionary: Sequence {
    public func makeIterator() -> AnyIterator<(key: Key, value: Value)> {
        var index = 0
        return AnyIterator {
            while index < orderedKeys.count {
                let key = orderedKeys[index]
                index += 1
                if let value = storage[key] {
                    return (key: key, value: value)
                }
            }
            return nil
        }
    }
}

extension OrderedDictionary: Equatable where Value: Equatable {
    public static func == (lhs: OrderedDictionary, rhs: OrderedDictionary) -> Bool {
        lhs.orderedKeys == rhs.orderedKeys && lhs.storage == rhs.storage
    }
}

extension OrderedDictionary: Sendable where Key: Sendable, Value: Sendable {}
