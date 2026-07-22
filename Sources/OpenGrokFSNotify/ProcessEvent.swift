// ProcessEvent.swift
//
// Semantic classification of raw OS events into `FsEvent`s using the lock
// state machine and git path classifier. Port of xai-fsnotify `source.rs`
// `process_event` (pure core).

import Foundation

/// Raw OS-level event after debouncing. Internal to the semantic pipeline.
public struct RawFsEvent: Sendable, Equatable {
    public var paths: [String]
    public var kind: FsEventKind

    public init(paths: [String], kind: FsEventKind) {
        self.paths = paths
        self.kind = kind
    }
}

/// VCS metadata directories discovered for the watched workspace.
public struct VcsDirs: Sendable, Equatable {
    public var gitDir: String?
    public var saplingDir: String?
    /// Whether Sapling suppression is enabled.
    public var sapling: Bool

    public init(gitDir: String? = nil, saplingDir: String? = nil, sapling: Bool = true) {
        self.gitDir = gitDir
        self.saplingDir = saplingDir
        self.sapling = sapling
    }

    public static let empty = VcsDirs()

    /// Git metadata only; Sapling contributes no `GitMetaKind`.
    public func classify(_ path: String) -> GitMetaKind? {
        guard let gitDir else { return nil }
        return classifyGitPath(path: path, gitDir: gitDir)
    }

    /// Paths under the discovered `.git`/`.sl` dir tick the state machine but
    /// are not workspace files.
    public func isInternal(_ path: String) -> Bool {
        if let gitDir, pathHasPrefix(path, prefix: gitDir) { return true }
        if let saplingDir, pathHasPrefix(path, prefix: saplingDir) { return true }
        return false
    }

    /// True only for the exact VCS lock files that arm suppression.
    public func isLockPath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if name == "index.lock" || name == "gc.pid" {
            return gitDir.map { canonicalizePath($0) == canonicalizePath(parent) } ?? false
        }
        if name == "wlock", sapling {
            return saplingDir.map { canonicalizePath($0) == canonicalizePath(parent) } ?? false
        }
        return false
    }

    public func lockPresent() -> Bool {
        let fm = FileManager.default
        if let gitDir {
            if fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("index.lock")) {
                return true
            }
            if fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("gc.pid")) {
                return true
            }
        }
        if sapling, let saplingDir {
            if fm.fileExists(atPath: (saplingDir as NSString).appendingPathComponent("wlock")) {
                return true
            }
        }
        return false
    }

    /// Combined head token `"\(git HEAD)|\(sl p1)"`.
    public func readHead() -> String? {
        let slActive = sapling && saplingDir != nil
        if gitDir == nil && !slActive { return nil }
        let git: String
        if let gitDir {
            let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
            git = (try? String(contentsOfFile: headPath, encoding: .utf8)) ?? ""
        } else {
            git = ""
        }
        let sl: String
        if sapling, let saplingDir {
            sl = readSaplingParent(saplingDir: saplingDir) ?? ""
        } else {
            sl = ""
        }
        return "\(git)|\(sl)"
    }
}

/// Read first 20 bytes of `.sl/dirstate` as hex-encoded p1.
public func readSaplingParent(saplingDir: String) -> String? {
    let path = (saplingDir as NSString).appendingPathComponent("dirstate")
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let type = attrs[.type] as? FileAttributeType,
          type == .typeRegular
    else { return nil }
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 20)
    guard data.count == 20 else { return nil }
    return data.map { String(format: "%02x", $0) }.joined()
}

private func pathHasPrefix(_ path: String, prefix: String) -> Bool {
    let p = canonicalizePath(path)
    let pre = canonicalizePath(prefix)
    if p == pre { return true }
    let withSlash = pre.hasSuffix("/") ? pre : pre + "/"
    return p.hasPrefix(withSlash)
}

/// Mutable processing context for the lock-aware event pipeline.
public struct FsEventProcessor: Sendable {
    public var state: LockState = .idle
    public var lastIdleHead: String?
    public var vcs: VcsDirs
    public var cooldown: TimeInterval

    public init(
        vcs: VcsDirs = .empty,
        cooldown: TimeInterval = TimeInterval(cooldownMilliseconds) / 1000.0
    ) {
        self.vcs = vcs
        self.cooldown = cooldown
        self.lastIdleHead = vcs.readHead()
    }

    /// Process one raw event batch; return emitted semantic events.
    public mutating func process(_ raw: RawFsEvent, now: Date = Date()) -> [FsEvent] {
        var out: [FsEvent] = []
        let headNow = vcs.readHead()
        let lockNow = vcs.lockPresent()
        let sawLockEvent = raw.paths.contains { vcs.isLockPath($0) }

        let entryHead = (lockNow || sawLockEvent) ? lastIdleHead : headNow
        let transition = driveLockState(
            &state,
            lockPresent: lockNow || sawLockEvent,
            headNow: entryHead,
            now: now,
            cooldown: cooldown
        )
        appendTransition(transition, to: &out)

        if !lockNow && sawLockEvent {
            // Lock already gone: release into Settling (silent by construction).
            let t2 = driveLockState(
                &state,
                lockPresent: false,
                headNow: headNow,
                now: now,
                cooldown: cooldown
            )
            appendTransition(t2, to: &out)
        }

        if case .idle = state {
            lastIdleHead = headNow
        } else if case .cooldown = state {
            lastIdleHead = headNow
        }

        let inOp: Bool = {
            switch state {
            case .locked, .settling, .cooldown: return true
            case .idle: return false
            }
        }()
        let inCooldown: Bool = {
            if case .cooldown = state { return true }
            return false
        }()

        var filePaths: [String] = []
        var gitMetaKinds: [GitMetaKind] = []
        for path in raw.paths {
            if let kind = vcs.classify(path) {
                gitMetaKinds.append(kind)
            } else if vcs.isInternal(path) {
                // VCS-internal: state-machine tick only.
            } else {
                filePaths.append(path)
            }
        }
        gitMetaKinds = Array(Set(gitMetaKinds)).sorted()

        if !inOp {
            for kind in gitMetaKinds {
                out.append(.gitMetaChanged(kind: kind))
            }
        }
        if !inCooldown && !filePaths.isEmpty {
            out.append(.filesChanged(paths: filePaths, kind: raw.kind))
        }
        return out
    }

    /// Advance timers (settle / cooldown expiry). Call when wall clock crosses
    /// a deadline with no new raw events.
    public mutating func tick(now: Date = Date()) -> [FsEvent] {
        var out: [FsEvent] = []
        let headNow = vcs.readHead()
        let lockNow = vcs.lockPresent()
        let transition: LockTransition
        if lockNow {
            transition = driveLockState(
                &state,
                lockPresent: true,
                headNow: lastIdleHead,
                now: now,
                cooldown: cooldown
            )
        } else {
            transition = driveLockState(
                &state,
                lockPresent: false,
                headNow: headNow,
                now: now,
                cooldown: cooldown
            )
        }
        appendTransition(transition, to: &out)
        if case .idle = state {
            lastIdleHead = headNow
        } else if case .cooldown = state {
            lastIdleHead = headNow
        }
        return out
    }

    /// Next timer deadline if the state machine is waiting.
    public var timerDeadline: Date? {
        switch state {
        case .settling(_, _, let until), .cooldown(let until):
            return until
        default:
            return nil
        }
    }

    private func appendTransition(_ t: LockTransition, to out: inout [FsEvent]) {
        switch t {
        case .started:
            out.append(.gitOperationStarted)
        case .completed(let headChanged):
            out.append(.gitOperationCompleted(headChanged: headChanged))
        case .none, .cooldownEnded:
            break
        }
    }
}
