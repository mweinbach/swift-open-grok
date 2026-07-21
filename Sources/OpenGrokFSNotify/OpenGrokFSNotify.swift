// OpenGrokFSNotify.swift
//
// Cross-platform filesystem-observation contract (W2-S3 bootstrap scaffold).
// macOS uses FSEvents/kqueue, Linux uses inotify, Windows uses
// ReadDirectoryChangesW. Adapters normalize all three into ordered
// create/modify/remove/rename/overflow events with cancellation-safe teardown.
//
// The owning slice (W2-S3) replaces `BootstrapFileSystemWatcher` with the real
// platform watcher. Reference: xai-fsnotify.

import Foundation

/// Filesystem watcher errors.
public enum FSNotifyError: Error, Equatable, Sendable {
    case watchFailed(String)
    case unsupported(String)
    case cancelled
    case overflow
}

/// The kind of a filesystem event.
public enum WatchEventKind: Sendable, Equatable, Codable {
    case create
    case modify
    case remove
    case rename
    case overflow
}

/// A single normalized filesystem event.
public struct WatchEvent: Sendable, Equatable {
    public var kind: WatchEventKind
    public var path: String
    public init(kind: WatchEventKind, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// A cancellation-safe filesystem watcher producing ordered events.
public protocol FileSystemWatcher: AnyObject, Sendable {
    /// Begin watching the given root paths (recursively).
    func watch(roots: [URL]) async throws
    /// Ordered events as a bounded, cancellable async sequence.
    func events() -> AsyncThrowingStream<WatchEvent, Error>
    /// Stop watching and release all OS resources.
    func cancel() async
}

/// Bootstrap watcher that reports `unsupported` for `watch`. The owning slice
/// (W2-S3) provides the FSEvents/kqueue/inotify/ReadDirectoryChangesW adapter.
public final class BootstrapFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    public init() {}
    public func watch(roots: [URL]) async throws {
        throw FSNotifyError.unsupported("BootstrapFileSystemWatcher does not watch; W2-S3 provides the platform adapter.")
    }
    public func events() -> AsyncThrowingStream<WatchEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    public func cancel() async {}
}
