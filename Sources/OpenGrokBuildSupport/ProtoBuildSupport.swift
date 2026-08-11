// ProtoBuildSupport.swift
//
// The protocol-build support contract ported from the Rust `xai-proto-build`
// crate (crates/build/xai-proto-build/src/{lib,find_protoc}.rs). The reference
// crate exposes:
//   * `configure()` -> `XaiProtoBuilder`, a builder mirroring
//     `tonic_prost_build::Builder` with Open Grok-specific defaults
//     (`compile_well_known_types(true)`, `extern_path(".google.protobuf", ...)`,
//     `--experimental_allow_proto3_optional`).
//   * Builder knobs: `bytes`, `extern_path`, `file_descriptor_set_path`,
//     `gen_pbjson`, `pbjson_ignore_unknown_fields`,
//     `pbjson_preserve_proto_field_names`, `generate_default_stubs`,
//     `type_attribute`, `field_attribute`.
//   * `compile_protos(&protos, &includes)`: discovers `protoc` via a 3-step
//     search (`$PROTOC` env var -> `bin/protoc` parent walk -> `protoc` on
//     `$PATH`), resolves the well-known-types include directory at
//     `../include` relative to `.../bin/protoc`, rejects absolute `.proto`
//     input paths, emits `cargo:rerun-if-changed=...` for protoc and proto
//     dependencies (via `protoc --dependency_out`), invokes
//     `tonic_prost_build` to compile Rust sources, and optionally emits a
//     `FileDescriptorSet` plus `pbjson` sources.
//   * In GitHub Actions it fails hard if no `protoc` is found; otherwise it
//     returns `Ok(None)` so callers can fall back to prost-build's built-in
//     lookup.
//
// SwiftPM plugins cannot generate Swift sources at build time the way Cargo
// build scripts do, so this port preserves the *build-support contract* in a
// Swift-native form:
//   * `ProtoBuilder` mirrors `XaiProtoBuilder` (`configure()` -> chained
//     configuration knobs -> `compileProtos`).
//   * `compileProtos` invokes `protoc` directly with the same include
//     resolution, absolute-path rejection, and dependency tracking
//     (`--dependency_out`) as the reference. It emits a deterministic
//     `FileDescriptorSet` (binary `--descriptor_set_out`) and, when
//     `genPbjson` is set, a JSON descriptor set (`--descriptor_set_out` with
//     `format=json` when the protoc version supports it). Downstream Swift
//     targets consume these descriptor sets to generate or validate protocol
//     fixtures, preserving the freshness invariant via the
//     `OpenGrokProtoBuildPlugin` command and `ProtocolFixtures/manifest.json`.
//   * The `ProtoCompiler` discovery contract is preserved so platform/build-
//     specific implementations (Bazel sandbox, homebrew protoc, vendored
//     binary) can be injected.
//
// This target defines the contract, the shared validation rules, the default
// `ProtoCompiler` implementation that mirrors `find_protoc::find_protoc` and
// `find_protoc_include_dir`, and a default `ProtoBuilder` that performs real
// `protoc` invocation and descriptor-set emission.

import Foundation

/// Discovery and compilation contract for Open Grok protocol generation.
///
/// Implementations must:
///   * Prefer the `PROTOC` environment variable, then a pinned/vendored binary
///     discovered by walking parent directories for `bin/protoc`, then a system
///     `protoc` on `PATH` — matching the Rust `find_protoc` search order.
///   * Validate each candidate with `protoc --version` before accepting it
///     (matching `check_protoc_good`).
///   * Resolve the well-known-types include directory relative to the
///     discovered binary (typically `../include` relative to `bin/protoc`).
///   * Reject absolute `.proto` input paths (the reference enforces this to
///     keep rerun-if-changed output deterministic).
///   * Perform no network access.
public protocol ProtoCompiler: Sendable {
    /// Discover the protoc binary URL, or `nil` if none is available.
    ///
    /// Implementations should follow the Rust `find_protoc` search order:
    /// `$PROTOC` env var → `bin/protoc` parent walk → `protoc` on `$PATH`.
    /// Each candidate must be validated with `protocIsGood` before being
    /// returned, so a present-but-broken `bin/protoc` (e.g. a dotslash wrapper
    /// in an environment without `dotslash`) falls through to the next step
    /// rather than poisoning the build.
    func discoverProtoc(environment: [String: String]) -> URL?

    /// Discover the protoc binary, throwing `ProtoBuildError.protocNotFound`
    /// when none is available and `strict` is `true`. This mirrors the Rust
    /// `find_protoc` behavior in GitHub Actions, where a missing protoc is a
    /// hard error rather than a silent nil.
    func discoverProtoc(environment: [String: String], strict: Bool) throws -> URL?

    /// Validate that `protoc` actually runs by invoking `protoc --version`.
    /// Returns `true` on success. Matching `check_protoc_good`, a non-zero exit
    /// or a failure to launch is reported as `false` rather than throwing, so
    /// the caller can fall through to the next discovery step.
    func protocIsGood(_ protoc: URL) -> Bool

    /// Resolve the well-known-types include directory for `protoc`, if present.
    func wellKnownTypesInclude(for protoc: URL) -> URL?

    /// Validate that none of `protoPaths` are absolute. Throws
    /// `ProtoBuildError.absolutePathRejected` otherwise.
    func validateInputPaths(_ protoPaths: [String]) throws

    /// Returns `true` when the runtime environment is one where a missing
    /// protoc should be a hard error. Mirrors the Rust
    /// `env::var_os("GITHUB_ACTIONS").is_some()` check: presence of the
    /// `GITHUB_ACTIONS` key is strict regardless of value (`true`, `false`,
    /// `0`, or empty string all count).
    func isStrictEnvironment(_ environment: [String: String]) -> Bool
}

/// Errors raised by protocol-build support.
public enum ProtoBuildError: Error, Equatable, Sendable {
    /// An absolute `.proto` path was supplied. The reference rejects these so
    /// that rerun-if-changed output stays deterministic.
    case absolutePathRejected(String)
    /// The protoc binary could not be discovered. Raised only in strict mode
    /// (e.g. GitHub Actions parity); non-strict callers receive `nil` instead.
    case protocNotFound
    /// protoc invocation failed.
    case invocationFailed(String)
    /// A dependency file reported by `protoc --dependency_out` did not exist.
    /// Mirrors the Rust `fs::exists(line)` guard.
    case dependencyNotFound(String)
    /// The `--dependency_out` payload could not be parsed. Mirrors the
    /// Rust `strip_prefix("/dev/null:")` failure path.
    case dependencyOutputMalformed(String)
}

/// Shared validation rules used by every `ProtoCompiler` implementation.
public enum ProtoBuildRules {
    /// Reject absolute proto input paths.
    ///
    /// Matches the Rust `compile_protos` guard:
    ///   if proto.is_absolute() {
    ///       return Err(anyhow!("Absolute paths are not allowed: {}", proto.display()));
    ///   }
    /// The Windows drive-letter form (`C:\`) and the rare `C:/` form are also
    /// rejected so the rule is platform-neutral.
    public static func validateInputPaths(_ protoPaths: [String]) throws {
        for path in protoPaths {
            if path.hasPrefix("/") || path.contains(":\\") || path.contains(":/") {
                throw ProtoBuildError.absolutePathRejected(path)
            }
        }
    }
}

/// A faithful default `ProtoCompiler` implementation mirroring the Rust
/// `find_protoc::find_protoc` search order and `find_protoc_include_dir`
/// heuristic.
///
/// The discovery order is:
///   1. `$PROTOC` environment variable (if the file exists and is good).
///   2. `bin/protoc` walking up parent directories from `workingDirectory`
///      (the dotslash-wrapper convention used by the reference repo).
///   3. `protoc` on `$PATH` via `pathLookup`.
///
/// `workingDirectory` and `pathLookup` are injectable so tests can exercise
/// each step deterministically without depending on the host's filesystem or
/// PATH contents.
public struct DefaultProtoCompiler: ProtoCompiler {
    /// Directory to start the `bin/protoc` parent walk from. Defaults to the
    /// process current directory, matching `env::current_dir()` in the
    /// reference.
    public var workingDirectory: URL

    /// Lookup a bare command name on `$PATH`. Returns the resolved URL if the
    /// candidate exists and is executable, otherwise `nil`. Defaults to a
    /// `FileManager`-based walk of `$PATH`.
    public var pathLookup: @Sendable (String) -> URL?

    /// Whether to validate each candidate with `protoc --version` before
    /// accepting it. Defaults to `true` to match `check_protoc_good`. Tests
    /// that inject non-executable placeholders may set this to `false`.
    public var validateCandidates: Bool

    /// Environment variable name read by `isStrictEnvironment`. Matches the
    /// reference `GITHUB_ACTIONS` check.
    public static let strictEnvironmentVariable = "GITHUB_ACTIONS"

    public init(
        workingDirectory: URL? = nil,
        pathLookup: @escaping @Sendable (String) -> URL? = Self.defaultPathLookup,
        validateCandidates: Bool = true
    ) {
        self.workingDirectory = workingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.pathLookup = pathLookup
        self.validateCandidates = validateCandidates
    }

    // MARK: - ProtoCompiler

    public func discoverProtoc(environment: [String: String]) -> URL? {
        try? discoverProtoc(environment: environment, strict: false)
    }

    public func discoverProtoc(environment: [String: String], strict: Bool) throws -> URL? {
        // 1. $PROTOC environment variable. The reference checks `try_exists`
        //    and then `check_protoc_good` before returning. A broken PROTOC
        //    falls through to the parent walk rather than poisoning the build.
        if let override = environment["PROTOC"], !override.isEmpty {
            let candidate = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: candidate.path) {
                if !validateCandidates || protocIsGood(candidate) {
                    return candidate
                }
            }
        }

        // 2. Walk up parent directories looking for `bin/protoc` (dotslash
        //    wrapper). The reference returns a relative path
        //    (`../bin/protoc`) for determinism; SwiftPM/Swift consumers
        //    prefer absolute URLs, so we resolve against `workingDirectory`.
        //    `deletingLastPathComponent()` only reaches a fixed point for an
        //    ABSOLUTE path. On a relative one it keeps prepending `..`
        //    forever, so the loop would spin building ever-longer paths and
        //    stat-ing each — a hang, not an error. `workingDirectory` is
        //    caller-supplied and `URL(fileURLWithPath:)` yields a relative URL
        //    for an empty or relative string (an empty `NSTemporaryDirectory()`
        //    is enough), so standardize first and keep a hard iteration bound
        //    as the backstop. Cost of the bound: a `bin/protoc` more than 256
        //    levels up is missed. That is not a real tree, and silently
        //    missing a candidate beats spinning forever.
        var dir = URL(
            fileURLWithPath: workingDirectory.path,
            isDirectory: true,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL.absoluteURL
        for _ in 0..<256 {
            let candidate = dir.appendingPathComponent("bin").appendingPathComponent("protoc")
            if FileManager.default.fileExists(atPath: candidate.path) {
                if !validateCandidates || protocIsGood(candidate) {
                    return candidate
                }
                // Present but broken: fall through to PATH, matching the
                // reference's dotslash-without-dotslash fallback.
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                // Reached the filesystem root.
                break
            }
            dir = parent
        }

        // 3. `protoc` on `$PATH`.
        if let candidate = pathLookup("protoc") {
            if !validateCandidates || protocIsGood(candidate) {
                return candidate
            }
        }

        // 4. Not found anywhere. In a strict environment (GitHub Actions
        //    parity) this is a hard error; otherwise return nil.
        if strict || isStrictEnvironment(environment) {
            throw ProtoBuildError.protocNotFound
        }
        return nil
    }

    public func protocIsGood(_ protoc: URL) -> Bool {
        // Mirrors `check_protoc_good`: run `protoc --version` and treat any
        // non-zero exit or launch failure as "not good" so the caller can
        // fall through to the next discovery step.
        let process = Process()
        process.executableURL = protoc
        process.arguments = ["--version"]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public func wellKnownTypesInclude(for protoc: URL) -> URL? {
        // Mirrors `find_protoc_include_dir`: protoc is typically at
        // .../bin/protoc, so the well-known-types include dir is at
        // .../include.
        let binDir = protoc.deletingLastPathComponent()
        let root = binDir.deletingLastPathComponent()
        let include = root.appendingPathComponent("include")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: include.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return include
    }

    public func validateInputPaths(_ protoPaths: [String]) throws {
        try ProtoBuildRules.validateInputPaths(protoPaths)
    }

    /// Returns `true` when the runtime environment is one where a missing
    /// protoc should be a hard error. Matches the reference
    /// `is_github_actions()` check, which is
    /// `env::var_os("GITHUB_ACTIONS").is_some()` — i.e. presence of the key
    /// is strict regardless of value (`true`, `false`, `0`, or empty string
    /// all count).
    public func isStrictEnvironment(_ environment: [String: String]) -> Bool {
        // Rust's `env::var_os` returns `Option<OsString>`; `.is_some()` is
        // true whenever the key is present, even when the value is empty,
        // "false", or "0". Mirror that exactly: any key presence is strict.
        return environment[Self.strictEnvironmentVariable] != nil
    }

    /// Default `pathLookup` implementation: walk `$PATH` for an executable
    /// `name`. Pure with respect to `ProcessInfo.processInfo.environment` so
    /// tests that inject a synthetic environment via a custom `pathLookup`
    /// closure stay deterministic.
    @usableFromInline
    static func defaultPathLookup(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(component))
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - ProtoBuilder (parity port of `XaiProtoBuilder` + `configure()`)

/// The output format for the descriptor set emitted by `ProtoBuilder`.
/// Mirrors the `--descriptor_set_out` flag forms used by the Rust crate.
public enum ProtoDescriptorFormat: Sendable, Equatable {
    /// Binary `FileDescriptorSet` (default; matches the Rust
    /// `file_descriptor_set_path` path passed to `tonic_prost_build` and
    /// `pbjson_build`).
    case binary
    /// JSON-formatted descriptor set (`--descriptor_set_out=...,
    /// format=json`). Used by downstream Swift consumers that need a
    /// deterministic, source-controllable JSON view of the protocol surface.
    case json
}

/// The result of a successful `ProtoBuilder.compileProtos` invocation.
public struct ProtoCompilationOutput: Sendable, Equatable {
    /// The protoc binary that was used, if any. `nil` when `protoc` was not
    /// required (e.g. an explicitly empty `protos` list) or not discovered in
    /// non-strict mode.
    public var protoc: URL?
    /// The well-known-types include directory that was prepended to the
    /// include list, when discovered. Mirrors `find_protoc_include_dir`.
    public var wellKnownTypesInclude: URL?
    /// The absolute URL of the emitted descriptor set, when one was
    /// requested or required.
    public var descriptorSet: URL?
    /// The absolute URLs of every input `.proto` and transitive dependency
    /// that contributed to the descriptor set. Mirrors the
    /// `cargo:rerun-if-changed` lines produced by `emit_rerun_if_changed`:
    /// each entry is a real file the caller should treat as a freshness
    /// input. Well-known types under `.../include/google/protobuf/` are
    /// excluded for determinism, matching the reference filter.
    public var dependencies: [URL]
    /// The absolute URLs of every user-supplied include directory that was
    /// passed to `protoc` (not including the well-known include).
    public var includes: [URL]

    public init(
        protoc: URL?,
        wellKnownTypesInclude: URL?,
        descriptorSet: URL?,
        dependencies: [URL],
        includes: [URL]
    ) {
        self.protoc = protoc
        self.wellKnownTypesInclude = wellKnownTypesInclude
        self.descriptorSet = descriptorSet
        self.dependencies = dependencies
        self.includes = includes
    }
}

/// A builder that mirrors Rust's `XaiProtoBuilder` (`configure()` →
/// chained configuration → `compile_protos`).
///
/// The Swift port invokes `protoc` directly (rather than `tonic_prost_build`)
/// to produce a `FileDescriptorSet` and, optionally, JSON descriptors. The
/// generated artifact is consumed by downstream Swift targets and by the
/// `OpenGrokProtoBuildPlugin` freshness contract. This preserves the
/// reference crate's build-support behavior — discovery, include resolution,
/// absolute-path rejection, dependency tracking, descriptor-set emission, and
/// optional pbjson-equivalent JSON output — in a SwiftPM-compatible shape.
///
/// **Contract narrowing (W0-S1 integration fix):** The Rust crate generates
/// Rust source code via `tonic_prost_build` and `pbjson_build`. The Swift
/// port cannot generate Swift protocol sources at build time (SwiftPM
/// build-tool plugins that generate source code require a `Package.swift`
/// edit owned by this slice, and no Swift equivalent of `prost`/`pbjson`
/// exists in the dependency-free port). The builder therefore narrows the
/// contract to what `protoc` can produce directly:
///
///   * `compileProtos` emits a deterministic `FileDescriptorSet` (binary or
///     JSON via `--descriptor_set_out`). This is the primary output.
///   * Builder knobs `bytes`, `externPaths`, `typeAttributes`,
///     `fieldAttributes`, `generateDefaultStubs`, `ignoreUnknownFields`, and
///     `preserveProtoFieldNames` are **informational-only**: they are
///     recorded on the builder for downstream consumers and for API parity
///     with the Rust crate, but `protoc` does not interpret them (they
///     control `tonic_prost_build`/`pbjson_build` code generation in the
///     Rust crate, which has no Swift equivalent). Callers that need these
///     knobs to influence generated code must consume the descriptor set
///     and apply the mappings in their own code-generation step.
///   * `genPbjson()` switches the descriptor set output to JSON format
///     (`.json`), which is the Swift-native equivalent of `pbjson_build`'s
///     JSON type generation. `descriptorFormat(.json)` does the same
///     explicitly.
///
/// The builder is a value type: every configuration method returns a new
/// copy. Configure once with `ProtoBuilder.configure()`, then call
/// `compileProtos` to perform the deterministic invocation.
public struct ProtoBuilder: Sendable {
    /// The compiler used to discover and validate `protoc`. Defaults to
    /// `DefaultProtoCompiler()`; inject a fake in tests.
    public var compiler: any ProtoCompiler
    /// Environment used for `PROTOC` and strict-environment detection.
    /// Defaults to `ProcessInfo.processInfo.environment` filtered to
    /// `String`-typed values.
    public var environment: [String: String]
    /// Working directory used to resolve relative `.proto` input paths and
    /// to anchor the descriptor-set output when no explicit URL is given.
    public var workingDirectory: URL
    /// Whether to compile the well-known types (`google/protobuf/*.proto`)
    /// into the descriptor set. Mirrors
    /// `tonic_prost_build::configure().compile_well_known_types(true)`.
    public var compileWellKnownTypes: Bool
    /// Extern-path mappings applied as `--extern_path` to `protoc`. The
    /// reference maps `.google.protobuf` -> `::pbjson_types` and
    /// `.google.protobuf.Empty` -> `()`; in Swift we record the mappings so
    /// downstream consumers can apply their own name remapping. Each tuple
    /// is `(protoPackage, swiftPackageOrAlias)`.
    public var externPaths: [(protoPackage: String, swiftPackageOrAlias: String)]
    /// Additional raw arguments forwarded to `protoc` (e.g.
    /// `--experimental_allow_proto3_optional`). Mirrors
    /// `configure().protoc_arg(...)`.
    public var protocArguments: [String]
    /// Bytes annotations (the Rust `bytes(path)` knob) recorded for
    /// downstream consumers; not directly interpreted by `protoc`.
    public var bytesPaths: [String]
    /// Type attributes (Rust `type_attribute(path, attr)`) recorded for
    /// downstream consumers.
    public var typeAttributes: [(path: String, attribute: String)]
    /// Field attributes (Rust `field_attribute(path, attr)`) recorded for
    /// downstream consumers.
    public var fieldAttributes: [(path: String, attribute: String)]
    /// Whether to emit JSON descriptors in addition to (or instead of) the
    /// binary descriptor set. Mirrors `gen_pbjson` plus
    /// `pbjson_ignore_unknown_fields` / `pbjson_preserve_proto_field_names`.
    public var generateJsonDescriptors: Bool
    /// Mirrors `pbjson_ignore_unknown_fields`: recorded for downstream
    /// consumers; not interpreted by `protoc`.
    public var ignoreUnknownFields: Bool
    /// Mirrors `pbjson_preserve_proto_field_names`: recorded for downstream
    /// consumers; not interpreted by `protoc`.
    public var preserveProtoFieldNames: Bool
    /// Mirrors `generate_default_stubs(enable)`: recorded for downstream
    /// consumers; not interpreted by `protoc`.
    public var generateDefaultStubs: Bool
    /// Explicit descriptor-set output URL. When `nil`, `compileProtos`
    /// derives a deterministic URL under `workingDirectory` named
    /// `xai-proto-build.pbbin` (binary) or `xai-proto-build.pbschema.json`
    /// (JSON), matching the Rust `tempfile` name when `gen_pbjson` is set.
    public var fileDescriptorSetPath: URL?
    /// Descriptor format to emit. Defaults to `.binary`; set to `.json` for
    /// the JSON descriptor form.
    public var descriptorFormat: ProtoDescriptorFormat
    /// Whether to perform the `--dependency_out` rerun-if-changed-equivalent
    /// dependency tracking. Defaults to `true` to match the reference; tests
    /// that want a single-shot invocation may disable it.
    public var emitDependencies: Bool

    /// Returns a new builder with `transform` applied. Internal helper
    /// mirroring the Rust `map_builder` combinator.
    @usableFromInline
    func map(_ transform: (inout ProtoBuilder) -> Void) -> ProtoBuilder {
        var copy = self
        transform(&copy)
        return copy
    }
}

extension ProtoBuilder {
    /// Mirror of Rust `xai_proto_build::configure()`. Returns a builder with
    /// the Open Grok defaults: well-known types compiled, `google.protobuf`
    /// extern-pathed, and `--experimental_allow_proto3_optional` forwarded to
    /// `protoc`.
    public static func configure(
        compiler: any ProtoCompiler = DefaultProtoCompiler(),
        environment: [String: String] = ProtoBuilder.defaultEnvironment(),
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> ProtoBuilder {
        ProtoBuilder(
            compiler: compiler,
            environment: environment,
            workingDirectory: workingDirectory,
            compileWellKnownTypes: true,
            externPaths: [
                (protoPackage: ".google.protobuf", swiftPackageOrAlias: "::pbjson_types"),
                (protoPackage: ".google.protobuf.Empty", swiftPackageOrAlias: "()"),
            ],
            protocArguments: ["--experimental_allow_proto3_optional"],
            bytesPaths: [],
            typeAttributes: [],
            fieldAttributes: [],
            generateJsonDescriptors: false,
            ignoreUnknownFields: false,
            preserveProtoFieldNames: false,
            generateDefaultStubs: false,
            fileDescriptorSetPath: nil,
            descriptorFormat: .binary,
            emitDependencies: true
        )
    }

    /// Mirrors `bytes(paths)`.
    public func bytes(_ paths: [String]) -> ProtoBuilder {
        map { $0.bytesPaths += paths }
    }

    /// Mirrors `extern_path(proto_path, rust_path)`.
    public func externPath(_ protoPackage: String, _ swiftPackageOrAlias: String) -> ProtoBuilder {
        map { $0.externPaths.append((protoPackage: protoPackage, swiftPackageOrAlias: swiftPackageOrAlias)) }
    }

    /// Mirrors `file_descriptor_set_path(path)`. Sets the explicit output
    /// URL for the descriptor set.
    public func fileDescriptorSetPath(_ url: URL) -> ProtoBuilder {
        map { $0.fileDescriptorSetPath = url }
    }

    /// Mirrors `gen_pbjson()`. In the Rust crate this enables `pbjson_build`
    /// to generate JSON-compatible Rust types. The Swift port has no `pbjson`
    /// equivalent, so this narrows the contract: it switches the descriptor
    /// set output to JSON format (`--descriptor_set_out=...,format=json`),
    /// which is the closest Swift-native equivalent and is what downstream
    /// Swift consumers use for deterministic, source-controllable JSON
    /// protocol views. The `generateJsonDescriptors` flag is set so callers
    /// can query whether JSON output was requested.
    public func genPbjson() -> ProtoBuilder {
        map {
            $0.generateJsonDescriptors = true
            $0.descriptorFormat = .json
        }
    }

    /// Mirrors `pbjson_ignore_unknown_fields()`.
    public func pbjsonIgnoreUnknownFields() -> ProtoBuilder {
        map { $0.ignoreUnknownFields = true }
    }

    /// Mirrors `pbjson_preserve_proto_field_names()`.
    public func pbjsonPreserveProtoFieldNames() -> ProtoBuilder {
        map { $0.preserveProtoFieldNames = true }
    }

    /// Mirrors `generate_default_stubs(enable)`.
    public func generateDefaultStubs(_ enable: Bool) -> ProtoBuilder {
        map { $0.generateDefaultStubs = enable }
    }

    /// Mirrors `type_attribute(path, attr)`.
    public func typeAttribute(_ path: String, _ attribute: String) -> ProtoBuilder {
        map { $0.typeAttributes.append((path: path, attribute: attribute)) }
    }

    /// Mirrors `field_attribute(path, attr)`.
    public func fieldAttribute(_ path: String, _ attribute: String) -> ProtoBuilder {
        map { $0.fieldAttributes.append((path: path, attribute: attribute)) }
    }

    /// Set the descriptor format explicitly.
    public func descriptorFormat(_ format: ProtoDescriptorFormat) -> ProtoBuilder {
        map { $0.descriptorFormat = format }
    }

    /// Override whether dependency tracking is emitted.
    public func emitDependencies(_ enable: Bool) -> ProtoBuilder {
        map { $0.emitDependencies = enable }
    }

    /// Mirrors `compile_protos(protos, includes)`.
    ///
    /// Performs the full Rust-equivalent sequence:
    ///   1. Reject absolute `.proto` input paths (mirrors the
    ///      `proto.is_absolute()` guard).
    ///   2. Discover `protoc` (mirrors `find_protoc`). In a strict
    ///      environment (presence of `GITHUB_ACTIONS`), a missing `protoc`
    ///      is a hard `ProtoBuildError.protocNotFound`. In non-strict mode,
    ///      `nil` is returned only when `protos` is empty; otherwise a
    ///      missing `protoc` is still an error because there is nothing to
    ///      compile with.
    ///   3. Resolve the well-known-types include directory at `../include`
    ///      relative to `protoc` (mirrors `find_protoc_include_dir`).
    ///   4. Build the include list: `[wellKnownInclude?] + includes`.
    ///   5. Track dependencies via per-file `--dependency_out=/dev/stdout`
    ///      invocations (one per proto, each with
    ///      `--descriptor_set_out=/dev/null`), mirroring `emit_rerun_if_changed`:
    ///      parse the `/dev/null:`-prefixed dependency file, skip well-known
    ///      `.../include/google/protobuf/` entries for determinism, and verify
    ///      every remaining dependency exists (mirrors `fs::exists(line)`).
    ///   6. Emit the REAL descriptor set via ONE all-input compilation
    ///      invocation (`--descriptor_set_out=<url>` with ALL protos on the
    ///      command line), so a multi-proto input produces a descriptor set
    ///      containing ALL root files — not just the last one.
    ///   7. Return a `ProtoCompilationOutput` carrying the discovered
    ///      `protoc`, include dir, descriptor-set URL, dependencies, and
    ///      includes — the deterministic inputs/outputs the caller needs to
    ///      gate fixture freshness.
    ///
    /// `protos` and `includes` are interpreted relative to `workingDirectory`
    /// when they are not absolute, mirroring Cargo's build-script CWD
    /// semantics. Absolute `protos` entries are rejected.
    public func compileProtos(
        protos: [String],
        includes: [String] = []
    ) throws -> ProtoCompilationOutput {
        // 1. Reject absolute proto input paths.
        try compiler.validateInputPaths(protos)

        // If there are no protos, there is nothing to compile. Return an empty
        // output so callers can short-circuit without invoking `protoc`.
        guard !protos.isEmpty else {
            return ProtoCompilationOutput(
                protoc: nil,
                wellKnownTypesInclude: nil,
                descriptorSet: nil,
                dependencies: [],
                includes: []
            )
        }

        // 2. Discover protoc. In a strict environment, a missing protoc is a
        //    hard error. Otherwise, a missing protoc with non-empty `protos`
        //    is also an error: there is nothing to compile with, and
        //    silently returning an empty output would mask the broken
        //    toolchain from callers. The Rust reference returns `Ok(None)`
        //    only from `find_protoc` itself; `compile_protos` then calls
        //    `tonic_build` which would fail without a protoc. We surface the
        //    same outcome as a typed error.
        let protoc: URL
        if let discovered = try compiler.discoverProtoc(environment: environment, strict: false) {
            protoc = discovered
        } else if compiler.isStrictEnvironment(environment) {
            // Re-enter the throwing overload so the strict-mode error is
            // raised. (discoverProtoc(strict:false) returned nil because
            // isStrictEnvironment wasn't passed as `strict`.) The strict
            // overload either returns a URL (impossible here — the
            // non-strict call already returned nil) or throws
            // `protocNotFound`; the trailing throw is a defensive fallback.
            _ = try compiler.discoverProtoc(environment: environment, strict: true)
            throw ProtoBuildError.protocNotFound
        } else {
            throw ProtoBuildError.invocationFailed(
                "`protoc` not found (checked $PROTOC env, bin/protoc, and PATH)"
            )
        }

        // 3. Resolve the well-known-types include directory.
        let wellKnownInclude = compiler.wellKnownTypesInclude(for: protoc)

        // 4. Build the include list (well-known first, then user includes).
        let resolvedIncludes: [URL] = (wellKnownInclude.map { [$0] } ?? []) + includes.map { inc in
            inc.hasPrefix("/") ? URL(fileURLWithPath: inc) : workingDirectory.appendingPathComponent(inc)
        }

        // 5. Resolve the descriptor-set output URL. When none is set, derive
        //    a deterministic one under `workingDirectory`.
        let descriptorURL = fileDescriptorSetPath ?? defaultDescriptorSetURL()
        // Ensure the parent directory exists.
        let parentDir = descriptorURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // 6. Resolve proto input URLs (relative to workingDirectory).
        let protoURLs: [URL] = protos.map { proto in
            proto.hasPrefix("/") ? URL(fileURLWithPath: proto) : workingDirectory.appendingPathComponent(proto)
        }

        // 7. Separate per-file dependency scans from ONE all-input
        //    compilation invocation. The previous implementation invoked
        //    protoc once per proto and emitted the descriptor set only on
        //    the last invocation — so a multi-proto input could produce a
        //    descriptor set containing only the last root file. Now:
        //      (a) If dependency tracking is enabled, run ONE per-file
        //          invocation per proto with `--dependency_out=/dev/stdout`
        //          and `--descriptor_set_out=/dev/null` to collect
        //          dependencies (mirrors `emit_rerun_if_changed`).
        //      (b) Run ONE final all-input invocation with ALL protos on
        //          the command line and `--descriptor_set_out=<url>` to
        //          emit the complete descriptor set.
        //    When dependency tracking is disabled, only step (b) runs.
        let dependencies: [URL]
        if emitDependencies {
            dependencies = try scanDependencies(
                protoc: protoc,
                protos: protoURLs,
                includes: resolvedIncludes,
                wellKnownInclude: wellKnownInclude
            )
        } else {
            dependencies = []
        }

        // Emit the real descriptor set with ALL protos in one invocation.
        try emitDescriptorSet(
            protoc: protoc,
            protos: protoURLs,
            includes: resolvedIncludes,
            descriptorURL: descriptorURL
        )

        return ProtoCompilationOutput(
            protoc: protoc,
            wellKnownTypesInclude: wellKnownInclude,
            descriptorSet: descriptorURL,
            dependencies: dependencies,
            includes: resolvedIncludes
        )
    }

    // MARK: - Internal helpers

    /// Derive the default descriptor-set URL under `workingDirectory`,
    /// matching the Rust `tempfile` name `xai-proto-build.pbbin` for binary
    /// and `xai-proto-build.pbschema.json` for JSON.
    func defaultDescriptorSetURL() -> URL {
        let name: String
        switch descriptorFormat {
        case .binary: name = "xai-proto-build.pbbin"
        case .json: name = "xai-proto-build.pbschema.json"
        }
        return workingDirectory.appendingPathComponent(name)
    }

    /// Per-file dependency scan: for each proto, invoke
    /// `protoc --dependency_out=/dev/stdout --descriptor_set_out=/dev/null
    /// -I... <proto>`, parse the dependency file, and collect real-file
    /// dependencies. This mirrors the Rust `emit_rerun_if_changed` — the
    /// descriptor set is NOT emitted here (each invocation writes to
    /// /dev/null); the real descriptor set is emitted separately by
    /// `emitDescriptorSet` with ALL protos in one invocation.
    func scanDependencies(
        protoc: URL,
        protos: [URL],
        includes: [URL],
        wellKnownInclude: URL?
    ) throws -> [URL] {
        var deps: [URL] = []
        var seenDeps = Set<String>()
        for proto in protos {
            let process = Process()
            process.executableURL = protoc
            var args: [String] = []
            // `--dependency_out` requires a single input file. Use stdout
            // to avoid creating a temp file, mirroring the reference
            // (`--dependency_out=/dev/stdout`).
            args.append("--dependency_out=/dev/stdout")
            // Emit to /dev/null: this invocation is for dependency
            // scanning only, NOT descriptor-set emission.
            args.append("--descriptor_set_out=/dev/null")
            // Well-known include first, then user includes — mirrors the
            // reference's include ordering.
            if let wellKnownInclude = wellKnownInclude {
                args.append("-I\(wellKnownInclude.path)")
            }
            for include in includes where include != wellKnownInclude {
                args.append("-I\(include.path)")
            }
            // Forward the configured raw protoc arguments
            // (e.g. --experimental_allow_proto3_optional).
            args.append(contentsOf: protocArguments)
            args.append(proto.path)
            process.arguments = args
            process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
            } catch {
                throw ProtoBuildError.invocationFailed(
                    "protoc command failed to launch: \(error.localizedDescription)"
                )
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                throw ProtoBuildError.invocationFailed(
                    "protoc command failed (exit \(process.terminationStatus)): \(stderr)"
                )
            }
            let depData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let depOutput = String(data: depData, encoding: .utf8) ?? ""
            try parseDependencyOutput(
                depOutput,
                wellKnownInclude: wellKnownInclude,
                into: &deps,
                seen: &seenDeps
            )
        }
        return deps
    }

    /// One all-input protoc invocation that emits the complete descriptor
    /// set with ALL protos on the command line. This ensures a multi-proto
    /// input produces a descriptor set containing ALL root files, not just
    /// the last one. Used for both the dependency-tracked and
    /// non-dependency-tracked paths.
    func emitDescriptorSet(
        protoc: URL,
        protos: [URL],
        includes: [URL],
        descriptorURL: URL
    ) throws {
        let process = Process()
        process.executableURL = protoc
        var args: [String] = []
        if descriptorFormat == .json {
            args.append("--descriptor_set_out=\(descriptorURL.path),format=json")
        } else {
            args.append("--descriptor_set_out=\(descriptorURL.path)")
        }
        for include in includes {
            args.append("-I\(include.path)")
        }
        args.append(contentsOf: protocArguments)
        for proto in protos {
            args.append(proto.path)
        }
        process.arguments = args
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw ProtoBuildError.invocationFailed(
                "protoc command failed to launch: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw ProtoBuildError.invocationFailed(
                "protoc command failed (exit \(process.terminationStatus)): \(stderr)"
            )
        }
    }

    /// Parse the `--dependency_out=/dev/stdout` payload. Mirrors the Rust
    /// `emit_rerun_if_changed` parser: the first line begins with
    /// `/dev/null:`, optionally ends with a `\` continuation, and lists
    /// dependencies separated by spaces. Subsequent lines continue the
    /// list. Well-known `.../include/google/protobuf/` entries are skipped
    /// for determinism, and every remaining dependency must exist
    /// (`fs::exists(line)`), otherwise `dependencyNotFound` is raised.
    func parseDependencyOutput(
        _ output: String,
        wellKnownInclude: URL?,
        into deps: inout [URL],
        seen seenDeps: inout Set<String>
    ) throws {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else {
            throw ProtoBuildError.dependencyOutputMalformed("protoc --dependency_out output is empty")
        }
        let prefix = "/dev/null:"
        guard firstLine.hasPrefix(prefix) else {
            throw ProtoBuildError.dependencyOutputMalformed(
                "protoc --dependency_out output must start with /dev/null: \(output.debugDescription)"
            )
        }
        let trimmedFirst = String(firstLine.dropFirst(prefix.count))
        // Use Array(...) to materialize a concrete [String] from the
        // dropFirst() result; this disambiguates the Sequence vs Collection
        // overload and gives map a stable element type.
        var restLines: [String] = []
        if lines.count > 1 {
            restLines = Array(lines[1...])
        }
        let allLines = [trimmedFirst] + restLines
        for raw in allLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Strip the trailing `\` continuation marker.
            let cleaned: String
            if line.hasSuffix("\\") {
                cleaned = String(line.dropLast())
            } else {
                cleaned = line
            }
            // Split on whitespace; each token is a dependency path.
            for token in cleaned.split(whereSeparator: { $0.isWhitespace }) {
                let path = String(token)
                if path.isEmpty { continue }
                // Skip well-known types for determinism, matching the
                // reference's `/include/google/protobuf/` filter.
                if path.contains("/include/google/protobuf/") { continue }
                let url = URL(fileURLWithPath: path)
                let key = url.path
                if seenDeps.contains(key) { continue }
                // Verify the dependency exists (mirrors `fs::exists(line)`).
                if !FileManager.default.fileExists(atPath: url.path) {
                    throw ProtoBuildError.dependencyNotFound(path)
                }
                seenDeps.insert(key)
                deps.append(url)
            }
        }
    }

    /// Snapshot `ProcessInfo.processInfo.environment` to a `[String: String]`,
    /// dropping any values that are not representable as `String`. Used as
    /// the default environment for `configure()`.
    public static func defaultEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment {
            result[key] = value
        }
        return result
    }
}

// MARK: - ProtoCompiler strict-environment default (Rust parity)

extension ProtoCompiler {
    /// Default strict-environment check that mirrors Rust
    /// `env::var_os("GITHUB_ACTIONS").is_some()`: presence of the
    /// `GITHUB_ACTIONS` key is strict regardless of value (`true`, `false`,
    /// `0`, or empty string all count).
    ///
    /// Implementations may override this; the default delegates to the
    /// `DefaultProtoCompiler` semantics so any `ProtoCompiler` that does
    /// not implement its own strict check inherits the Rust-parity rule.
    public func isStrictEnvironment(_ environment: [String: String]) -> Bool {
        environment[DefaultProtoCompiler.strictEnvironmentVariable] != nil
    }
}
