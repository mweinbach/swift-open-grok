// Pool.swift
//
// Port of `xai-grok-config-types/src/pool.rs`.
//
// Configuration for the pre-created worktree pool. Set in `config.toml` under
// `[worktree_pool]`.

import Foundation

public struct PoolConfig: Hashable, Sendable, Codable, Equatable {
    /// Whether the pool is enabled at all. Can be set to `false` to disable
    /// pooling regardless of repo size. Default: `true` (auto-detect based on
    /// `fileCountThreshold`).
    public var enabled: Bool
    /// Number of worktrees to keep ready in the pool. Default: 2.
    public var poolSize: Int
    /// Minimum number of tracked files for the pool to activate. Default: 50_000.
    public var fileCountThreshold: Int
    /// Number of threads to use for worktree creation when populating the
    /// pool. Default: 3.
    public var parallelism: Int

    public init(
        enabled: Bool = true,
        poolSize: Int = 2,
        fileCountThreshold: Int = 50_000,
        parallelism: Int = 3
    ) {
        self.enabled = enabled
        self.poolSize = poolSize
        self.fileCountThreshold = fileCountThreshold
        self.parallelism = parallelism
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case poolSize = "pool_size"
        case fileCountThreshold = "file_count_threshold"
        case parallelism
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        poolSize = try c.decodeIfPresent(Int.self, forKey: .poolSize) ?? 2
        fileCountThreshold = try c.decodeIfPresent(Int.self, forKey: .fileCountThreshold) ?? 50_000
        parallelism = try c.decodeIfPresent(Int.self, forKey: .parallelism) ?? 3
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(poolSize, forKey: .poolSize)
        try c.encode(fileCountThreshold, forKey: .fileCountThreshold)
        try c.encode(parallelism, forKey: .parallelism)
    }
}
