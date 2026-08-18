// LiveSchedulerPersistence.swift
//
// The scheduler's on-disk state: the port of `ResourcesPersistence`
// (`xai-grok-tools/src/persistence.rs`) scoped to the one resource this
// composition registers, `grok_build.Scheduler`.
//
// File location: upstream derives it from the session's tool-state path —
// `ctx.state_path.parent().join("resources_state.json")`
// (`xai-grok-tools/src/registry/types.rs:1134-1139`) where the shell sets
// `state_path = session_dir.join("tool_state.json")`
// (`xai-grok-shell/src/session/acp_session_impl/spawn.rs:946-947`) and
// `session_dir = grok_home()/sessions/<encoded-cwd>/<session-id>`
// (`xai-grok-shared/src/session/mod.rs:11-13`,
// `xai-grok-config/src/paths.rs:159-161`). The port's session directory is
// `$OPENGROK_HOME/sessions/<sessionID>/` — the convention the monitor slice
// established (no cwd-encoding level; recorded divergence) — so the file is
// `$OPENGROK_HOME/sessions/<sessionID>/resources_state.json`. The session id
// is path-safe by construction: every id reaching the composition passed
// `LiveConversationStore.validateSessionID` ([A-Za-z0-9._-], ≤128, not
// "."/".."), the port's analog of upstream's `sanitize_session_id`
// (`xai-grok-workspace/src/session/tool_config.rs:271-292`).
//
// File shape: `Resources::serialize()`'s category map —
// `{"state": {"grok_build.Scheduler": <SchedulerState>}}`
// (`types/resources.rs:316-350`; the key from `register_resource!(
// "grok_build", "Scheduler", SchedulerState)`, `scheduler/types.rs:305`),
// pretty-printed (`to_vec_pretty`, `persistence.rs:324`). Upstream's file
// carries every registered resource; this composition registers only the
// scheduler, and upstream's own load-save cycle drops resource keys that
// lack a live registration (`load_from` ignores unknowns,
// `resources.rs:356-366`; `serialize` emits only registered entries), so a
// single-resource writer is that same behavior with one registration.
//
// Two write grades, exactly upstream's (`persistence.rs:297-347`):
//  * `save` — `write_json`: temp file + atomic rename, no fsync. The
//    debounced background flavor that runs after every tool call.
//  * `saveDurably` — `write_json_durable`: temp file, fsync the file,
//    atomic rename, fsync the parent directory. The barrier flavor the
//    delete/durable-expiry paths await; its failure is the caller's error,
//    and a failed attempt removes its temp file (`persistence.rs:316-321`).
// Neither creates the parent directory — a missing session dir is a real
// write error the barrier must surface (pinned upstream by
// `save_and_flush_error_can_be_retried`, `persistence.rs:559-581`); the
// directory is created once at composition, upstream's `ensure_session_dir`
// (`tool_config.rs:294-297`).

import Foundation
import OpenGrokFileUtils
import OpenGrokScheduler

struct LiveSchedulerPersistence: Sendable {
    /// `resources_state.json` (`registry/types.rs:1138`).
    static let fileName = "resources_state.json"

    let stateFileURL: URL

    init(stateFileURL: URL) {
        self.stateFileURL = stateFileURL
    }

    /// Bind persistence to a session directory, creating it like upstream's
    /// `ensure_session_dir` (`tool_config.rs:294-297`). A failed create
    /// disables persistence for the session rather than failing the launch —
    /// upstream's empty-`state_path` arm (`tool_config.rs:364-377`).
    static func forSessionDirectory(_ directory: URL) -> LiveSchedulerPersistence? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        return LiveSchedulerPersistence(
            stateFileURL: directory.appendingPathComponent(fileName, isDirectory: false)
        )
    }

    // MARK: - Load

    /// Load the persisted scheduler state, or `nil` for "start fresh".
    ///
    /// Every failure arm is fresh-state, never a crash, matching upstream
    /// exactly: a missing file (`persistence.rs:114-117`), unparseable JSON
    /// (`:119-129`), a top level that is not an object-of-objects
    /// (`value_to_nested_map`, `:131-140, 215-231`), and a
    /// `grok_build.Scheduler` value the strict `SchedulerState` decoder
    /// refuses (`Resources::load_from`'s `if let Ok` deserialize_fn,
    /// `resources.rs:307-314`). A malformed occurrence JOURNAL inside an
    /// otherwise valid state never reaches this arm — its decoder is total
    /// and quarantines instead (OccurrenceJournal.swift).
    func load() -> SchedulerState? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        guard let top = try? JSONSerialization.jsonObject(with: data),
              let topObject = top as? [String: Any]
        else { return nil }
        var categories: [String: [String: Any]] = [:]
        for (key, value) in topObject {
            guard let inner = value as? [String: Any] else { return nil }
            categories[key] = inner
        }
        guard let schedulerValue = categories["state"]?[
            "\(SchedulerResourceKey.namespace).\(SchedulerResourceKey.name)"
        ] else { return nil }
        guard let valueData = try? JSONSerialization.data(
            withJSONObject: schedulerValue, options: [.fragmentsAllowed]
        ) else { return nil }
        return try? JSONDecoder().decode(SchedulerState.self, from: valueData)
    }

    // MARK: - Save

    /// Best-effort save — `write_json` (`persistence.rs:297-301`): temp +
    /// atomic rename, no fsync. Failures are swallowed exactly as the
    /// background writer logs-and-continues (`persistence.rs:282-292`);
    /// durability guarantees belong to `saveDurably` alone.
    func save(_ state: SchedulerState) {
        try? write(state, durable: false)
    }

    /// The durability barrier — `write_json_durable` (`persistence.rs:
    /// 303-314`): write temp, fsync the file, atomic rename, fsync the
    /// parent directory (`publish_durable`, `persistence.rs:340-347`). The
    /// delete and durable-expiry barriers await this and treat a throw as
    /// "not committed".
    func saveDurably(_ state: SchedulerState) throws {
        try write(state, durable: true)
    }

    private func write(_ state: SchedulerState, durable: Bool) throws {
        let encoder = JSONEncoder()
        // `serde_json::to_vec_pretty` (`persistence.rs:324`); sorted keys are
        // the port's determinism convention — key order is not part of the
        // JSON contract either side parses.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let key = "\(SchedulerResourceKey.namespace).\(SchedulerResourceKey.name)"
        let json = try encoder.encode(["state": [key: state]])
        // `path.with_extension("json.tmp")` (`persistence.rs:326`):
        // resources_state.json → resources_state.json.tmp.
        let tempURL = stateFileURL.deletingLastPathComponent()
            .appendingPathComponent(Self.fileName + ".tmp", isDirectory: false)

        do {
            if durable {
                // Create-then-fsync, upstream's `File::create` + `write_all`
                // + `sync_all` (`persistence.rs:306-308`).
                guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: tempURL.path,
                    ])
                }
                let handle = try FileHandle(forWritingTo: tempURL)
                do {
                    try handle.write(contentsOf: json)
                    try handle.synchronize()
                } catch {
                    try? handle.close()
                    throw error
                }
                try handle.close()
            } else {
                try json.write(to: tempURL)
            }
            try replaceStatePath(with: tempURL)
            if durable {
                try syncDirectory(stateFileURL.deletingLastPathComponent())
            }
        } catch {
            // `cleanup_temp_on_error` (`persistence.rs:316-321`): a failed
            // publish must not strand a partial temp file where the next
            // attempt's create would trip over it.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// `replace_state_path` (`persistence.rs:329-338`): a directory squatting
    /// on the state path is removed before the rename — rename(2) onto a
    /// directory fails, and upstream treats the squatter as legacy debris.
    private func replaceStatePath(with tempURL: URL) throws {
        let parent = stateFileURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: parent.path])
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: stateFileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            try FileManager.default.removeItem(at: stateFileURL)
        }
        try AtomicFile.rename(tempURL, to: stateFileURL, directorySync: .none)
    }

    /// The parent-directory fsync that makes the rename itself durable
    /// (`publish_durable`, `persistence.rs:341-347`).
    private func syncDirectory(_ directory: URL) throws {
        try AtomicFile.fsyncDirectory(at: directory)
    }
}
