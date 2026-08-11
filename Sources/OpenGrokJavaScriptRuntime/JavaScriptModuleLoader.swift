// JavaScriptModuleLoader.swift
//
// Module loading abstraction for the per-cell JavaScript runtime. Mirrors
// the V8 module resolver pipeline from runtime/module_loader.rs:
//
//   * specifier resolution with relative-path normalization (the referrer-
//     aware plumbing that V8 provides natively through
//     `resolve_module_callback`, module_loader.rs:164)
//   * a module cache keyed by canonical specifier (the dedup invariant V8
//     maintains through its internal module identity map)
//   * rejection semantics matching `resolve_module` (module_loader.rs:223)
//
// JavaScriptCore's public API does not expose ES module compilation, so
// the cell source is still evaluated as an async IIFE (see
// `JavaScriptCellEngine.evaluateSource`). This abstraction handles the
// resolution and caching pipeline that V8's callbacks provide natively;
// the scanner in `JavaScriptCellRuntime.swift` detects module syntax and
// feeds specifiers into this loader for resolution and rejection.
//
// Divergence: dynamic `import()` expressions are syntax-level in JSC and
// cannot be intercepted through a public callback the way V8's
// `dynamic_import_callback` (module_loader.rs:175) can. Static `import`
// declarations are caught by `JavaScriptSourceScanner` before evaluation;
// a dynamic `import()` inside the IIFE will fall through to JSC's own
// module resolver, which produces an error because no module source
// provider is configured. The error text will differ from Rust's
// `"Unsupported import in exec: {specifier}"`.

import Foundation

// MARK: - Module specifier

/// A resolved module specifier carrying its raw form and canonical path.
///
/// V8 resolves specifiers through `resolve_module_callback`
/// (module_loader.rs:164), receiving the referrer module and the raw
/// specifier string. This type carries the same resolution output.
struct JavaScriptModuleSpecifier: Hashable, Sendable, CustomStringConvertible {
    /// The specifier as written in the source (`"./utils"`, `"lodash"`).
    let raw: String
    /// Canonical form after relative-path resolution, used as cache key.
    /// Bare specifiers (`lodash`, `node:fs`) equal their raw form; relative
    /// specifiers (`./foo`) are resolved against the referrer's directory.
    let resolved: String

    var description: String { resolved }
}

// MARK: - Module loader

/// Per-cell module loader mirroring V8's resolve / instantiate / evaluate
/// pipeline. Owns the module cache and specifier-resolution logic.
///
/// V8 resolves modules through two callbacks set on the isolate:
///   * `resolve_module_callback` for static `import` declarations
///   * `dynamic_import_callback` for `import()` expressions
///
/// Both call `resolve_module` (module_loader.rs:223), which rejects every
/// specifier with `"Unsupported import in exec: {specifier}"`. This type
/// provides the same resolution and rejection with a cache so repeated
/// imports of the same canonical specifier return a consistent result
/// (matching V8's module identity dedup).
final class JavaScriptModuleLoader {

    /// The filename V8 assigns to the main cell script via `script_origin`
    /// (module_loader.rs:17). Used as the referrer when resolving
    /// specifiers that appear in the cell body.
    static let mainModuleReferrer = "exec_main.mjs"

    private var cache: [String: ModuleResolution] = [:]

    /// A cached resolution outcome. V8's module map stores compiled modules
    /// keyed by identity hash; this stores the outcome (currently always
    /// rejection) keyed by canonical specifier.
    enum ModuleResolution: Equatable {
        case rejected(error: String)
    }

    /// The result of attempting to load a resolved module specifier.
    enum LoadOutcome: Equatable {
        case rejected(error: String)
    }

    // MARK: Resolution

    /// Resolve a raw specifier relative to a referrer path.
    ///
    /// Mirrors the referrer-aware resolution that V8's
    /// `resolve_module_callback` (module_loader.rs:164) performs when it
    /// receives the specifier and the referrer module. Relative specifiers
    /// (`./`, `../`) are normalized against the referrer's directory; bare
    /// specifiers pass through unchanged.
    func resolve(
        specifier: String,
        referrer: String = JavaScriptModuleLoader.mainModuleReferrer
    ) -> JavaScriptModuleSpecifier {
        let resolved = Self.resolveSpecifier(specifier, relativeTo: referrer)
        return JavaScriptModuleSpecifier(raw: specifier, resolved: resolved)
    }

    /// Attempt to load a resolved module.
    ///
    /// Mirrors `resolve_module` (module_loader.rs:223), which throws
    /// `"Unsupported import in exec: {specifier}"` and returns `None`. The
    /// cache ensures that a repeated import of the same canonical specifier
    /// returns the same result — the invariant V8 maintains through its
    /// internal module map.
    ///
    /// Currently rejects all specifiers. When module loading is supported,
    /// a `.loaded(source:)` case would carry the module source text.
    func load(_ specifier: JavaScriptModuleSpecifier) -> LoadOutcome {
        if let cached = cache[specifier.resolved] {
            switch cached {
            case .rejected(let error):
                return .rejected(error: error)
            }
        }
        let error = "Unsupported import in exec: \(specifier.raw)"
        cache[specifier.resolved] = .rejected(error: error)
        return .rejected(error: error)
    }

    /// Whether a canonical specifier has already been resolved (regardless
    /// of outcome). Mirrors V8's module-identity dedup: the resolve
    /// callback is called at most once per specifier per instantiation.
    func hasResolved(_ canonicalSpecifier: String) -> Bool {
        cache[canonicalSpecifier] != nil
    }

    /// Number of distinct specifiers resolved so far.
    var resolvedCount: Int { cache.count }

    // MARK: Specifier normalization

    /// Normalize a raw specifier relative to its referrer's directory.
    ///
    /// - Bare specifiers (`lodash`, `node:fs`) pass through unchanged.
    /// - Relative specifiers (`./foo`, `../bar/baz`) are joined with the
    ///   referrer's directory component and path-normalized (`.` and `..`
    ///   segments collapsed).
    ///
    /// This matches the resolution semantics a real V8 module resolver
    /// would apply before passing the canonical name to the loader.
    static func resolveSpecifier(
        _ specifier: String,
        relativeTo referrer: String
    ) -> String {
        guard specifier.hasPrefix("./") || specifier.hasPrefix("../") else {
            return specifier
        }
        let referrerDir = directoryOf(referrer)
        if referrerDir.isEmpty {
            return normalizePath(specifier)
        }
        return normalizePath("\(referrerDir)/\(specifier)")
    }

    /// The directory component of a `/`-separated path, or the empty
    /// string for a bare filename like `"exec_main.mjs"`.
    private static func directoryOf(_ path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return "" }
        let dir = path[path.startIndex..<lastSlash]
        return dir.isEmpty ? "" : String(dir)
    }

    /// Collapse `.` and `..` segments in a forward-slash path. Does not
    /// escape above the root: `../` at the top level is dropped.
    private static func normalizePath(_ path: String) -> String {
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if !segments.isEmpty { segments.removeLast() }
            default:
                segments.append(String(segment))
            }
        }
        return segments.joined(separator: "/")
    }
}
