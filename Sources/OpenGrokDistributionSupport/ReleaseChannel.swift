// ReleaseChannel.swift
//
// Version-channel semantics for the release side.
//
// The channel vocabulary itself already exists in the port as
// `OpenGrokUpdate.UpdateChannel`; this file adds the two channel behaviours the
// release/update handoff depends on, both taken from
// `crates/codegen/xai-grok-update/src/version.rs`:
//
//   1. Default channel is `"stable"` (`src/version.rs:48,73`).
//   2. On `alpha`, the resolver fetches BOTH the alpha and the stable pointer
//      and returns the semver-greater of the two (`src/version.rs:125-134`,
//      `:193-203`, `:295-332`). The doc comment there states why: it "prevents
//      alpha users getting stuck when a newer stable ships without updating the
//      alpha dist-tag". A stable-channel resolve uses the stable pointer alone.
//
// The user-facing label format comes from
// `crates/codegen/xai-grok-version/src/lib.rs:33` — `display_version` appends a
// pre-formatted suffix such as `" [alpha]"`, `" [stable]"`, or `""`.

import Foundation
import OpenGrokUpdate
import OpenGrokVersion

/// Release-channel behaviour for the distribution pipeline.
public enum ReleaseChannelPolicy {
    /// The channel used when configuration does not specify one.
    ///
    /// `src/version.rs:73` initialises the updater config with
    /// `channel: "stable".to_string()`.
    public static let defaultChannel: UpdateChannel = .stable

    /// The display suffix for a channel, e.g. `" [alpha]"`.
    ///
    /// `xai_grok_version::display_version` takes a pre-formatted suffix and
    /// concatenates it, so the bracket-and-leading-space shape lives here.
    /// An empty suffix (no cached pointer available) is represented by `nil`.
    public static func channelLabel(for channel: UpdateChannel?) -> String {
        guard let channel else { return "" }
        return " [\(channel.rawValue)]"
    }

    /// Format an arbitrary version string with its channel label.
    ///
    /// `OpenGrokVersion.displayVersion(channelLabel:)` already covers the
    /// compiled version; the release pipeline also has to label versions it is
    /// about to publish or install, which are not the running binary's. Both
    /// use the same `"{version}{label}"` concatenation as the Rust
    /// `display_version` at `xai-grok-version/src/lib.rs:33`.
    public static func displayVersion(_ version: String, channel: UpdateChannel?) -> String {
        OpenGrokVersion.displayVersionWithCommit(
            version,
            channelLabel: channelLabel(for: channel)
        )
    }

    /// Which channel pointers a resolve on `channel` must consult.
    ///
    /// `alpha` consults both pointers; every other channel consults only its
    /// own. Returned in a stable order so a caller can fan out deterministically.
    public static func pointersToConsult(for channel: UpdateChannel) -> [UpdateChannel] {
        channel == .alpha ? [.alpha, .stable] : [channel]
    }

    /// Resolve the target version for `channel` from the fetched pointers.
    ///
    /// On `alpha`, returns the semver-greater of the alpha and stable pointers
    /// (`src/version.rs:129-134`). On any other channel, returns that channel's
    /// own pointer. A pointer that fails to parse as semver is ignored rather
    /// than failing the resolve, matching the reference's fail-soft posture in
    /// `semver_max`.
    ///
    /// - Parameter pointers: channel-to-version-string map, as fetched.
    /// - Returns: the version to install, or `nil` when no usable pointer exists.
    public static func resolveTarget(
        channel: UpdateChannel,
        pointers: [UpdateChannel: String]
    ) -> String? {
        let candidates = pointersToConsult(for: channel).compactMap { pointers[$0] }
        return semverMax(candidates)
    }

    /// The semver-greater of a set of version strings.
    ///
    /// Unparseable entries are skipped. When nothing parses, the first raw
    /// candidate is returned so a caller still has something to report.
    public static func semverMax(_ versions: [String]) -> String? {
        var best: (parsed: SemVerVersion, raw: String)?
        for raw in versions {
            guard let parsed = try? SemVerVersion.parse(raw) else { continue }
            if best == nil || parsed > best!.parsed {
                best = (parsed, raw)
            }
        }
        return best?.raw ?? versions.first
    }
}
