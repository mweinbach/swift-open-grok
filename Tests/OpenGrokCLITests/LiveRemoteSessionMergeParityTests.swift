import Foundation
import OpenGrokCLIChatProxyTypes
import Testing
@testable import OpenGrokCLI

private func remoteMergeDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func remoteMergeLocal(
    id: String,
    directory: String = "/local/workspace",
    title: String? = "local title",
    model: String? = "grok-local",
    created: TimeInterval = 10,
    active: TimeInterval = 100,
    messages: Int = 1,
    users: Int = 1,
    assistants: Int = 0,
    parent: String? = nil,
    foreign: ForeignSessionSource? = nil
) -> LiveSessionListing {
    LiveSessionListing(
        sessionID: id,
        workingDirectory: directory,
        parentSessionID: parent,
        title: title,
        model: model,
        createdAt: remoteMergeDate(created),
        lastActivityAt: remoteMergeDate(active),
        messageCount: messages,
        userMessageCount: users,
        assistantMessageCount: assistants,
        foreignSource: foreign
    )
}

private func remoteMergeReplica(
    id: String,
    directory: String = "/remote/workspace",
    summary: String = "remote summary",
    firstPrompt: String? = "remote first prompt",
    model: String? = "grok-remote",
    created: TimeInterval = 20,
    updated: TimeInterval = 200,
    active: TimeInterval? = nil,
    turns: Int32 = 4,
    repository: String? = nil,
    parent: String? = nil
) -> SessionReplicaResponse {
    SessionReplicaResponse(
        sessionId: id,
        summary: summary,
        firstPrompt: firstPrompt,
        modelId: model,
        createdAt: remoteMergeDate(created),
        updatedAt: remoteMergeDate(updated),
        lastTurnNumber: turns,
        cwd: directory,
        repoRemoteURL: repository,
        gcsTracePrefix: "",
        gcsBucket: "",
        parentSessionId: parent,
        status: "active",
        lastActiveAt: active.map(remoteMergeDate)
    )
}

@Suite("Host-preserving remote session merge parity")
struct LiveRemoteSessionMergeParityTests {
    @Test("SSH, HTTPS, HTTP, ssh://, git:// and credentials normalize to one host-preserving repository")
    func repositoryNormalizationMatchesUpstreamTransportForms() {
        let spellings = [
            "git@GitHub.COM:Acme/Repository.git",
            "GITHUB.com:Acme/Repository.git/",
            "https://github.com/Acme/Repository.git",
            "https://x-access-token:PRIVATE_TOKEN@github.com/Acme/Repository.git/",
            "http://github.com:8443/Acme/Repository",
            "ssh://git@github.com:2222/Acme/Repository.git/",
            "git://github.com/Acme/Repository.git",
            "  https://GITHUB.COM/Acme/Repository.git/  ",
        ]

        for spelling in spellings {
            #expect(LiveRemoteSessionMerge.normalizeRepositoryURL(spelling)
                == "github.com/Acme/Repository")
        }
        #expect(LiveRemoteSessionMerge.normalizeRepositoryURL(
            "https://github.com/Acme/repository"
        ) != "github.com/Acme/Repository")
    }

    @Test("Git host identity survives normalization even for identical organizations and repositories")
    func repositoryNormalizationNeverDropsOrConfusesHost() {
        let trusted = LiveRemoteSessionMerge.normalizeRepositoryURL(
            "git@github.com:acme/private.git"
        )
        let hostile = LiveRemoteSessionMerge.normalizeRepositoryURL(
            "https://github.evil.example/acme/private.git"
        )
        let suffixSpoof = LiveRemoteSessionMerge.normalizeRepositoryURL(
            "https://github.com.attacker.example/acme/private.git"
        )

        #expect(trusted == "github.com/acme/private")
        #expect(hostile == "github.evil.example/acme/private")
        #expect(suffixSpoof == "github.com.attacker.example/acme/private")
        #expect(trusted != hostile)
        #expect(trusted != suffixSpoof)
    }

    @Test("malformed repositories, traversal, encoded delimiters, credentials ambiguity, and injection fail closed")
    func malformedRepositoryURLsNeverBecomeTrustedIdentities() {
        let malformed = [
            "",
            "   ",
            "file:///tmp/repository",
            "/tmp/repository",
            "github.com/acme/repository",
            "https:///acme/repository",
            "https://github.com",
            "https://github.com/",
            "https://github.com/.git",
            "https://github.com/acme//repository",
            "https://github.com/acme/../repository",
            "https://github.com/acme/%2e%2e/repository",
            "https://github.com/acme%2Frepository",
            "https://github.com/acme/%5Crepository",
            "https://github.com/acme/%ZZ",
            "https://github.com/acme/repository?access_token=PRIVATE",
            "https://github.com/acme/repository#fragment",
            "https://github.com/acme/repository\nInjected: yes",
            "https://github.com/acme/\u{0000}repository",
            "https://github.com\\attacker.example/acme/repository",
            "https://@github.com/acme/repository",
            "https://one@two@github.com/acme/repository",
            "https://github.com:0/acme/repository",
            "https://github.com:65536/acme/repository",
            "https://github..com/acme/repository",
            "https://-github.com/acme/repository",
            "ftp://github.com/acme/repository",
            "javascript://github.com/acme/repository",
            "git@:acme/repository",
            "git@github.com:",
        ]

        for repository in malformed {
            #expect(LiveRemoteSessionMerge.normalizeRepositoryURL(repository) == nil)
        }
        let oversized = "https://github.com/" + String(
            repeating: "a",
            count: LiveRemoteSessionMerge.maximumRepositoryBytes
        )
        #expect(LiveRemoteSessionMerge.normalizeRepositoryURL(oversized) == nil)
    }

    @Test("local-only and remote-only rows retain exact source, identity, and first-prompt provenance")
    func independentLanesKeepTheirProvenance() throws {
        let local = remoteMergeLocal(id: "local-only", active: 400, parent: "local-parent")
        let remote = remoteMergeReplica(
            id: "remote-only",
            active: 300,
            turns: 7,
            parent: "remote-parent"
        )

        let merged = LiveRemoteSessionMerge.merge(
            local: [local],
            remote: [remote],
            repositoryRemotes: [],
            limit: 10
        )

        #expect(merged.map(\.listing.sessionID) == ["local-only", "remote-only"])
        #expect(merged.map(\.source) == [.local, .remote])
        #expect(merged[0].firstPrompt == nil)
        #expect(merged[0].listing.parentSessionID == "local-parent")
        #expect(merged[1].firstPrompt == "remote first prompt")
        #expect(merged[1].listing.parentSessionID == "remote-parent")
        #expect(merged[1].listing.messageCount == 7)
        #expect(merged[1].listing.userMessageCount == 0)
        #expect(merged[1].listing.assistantMessageCount == 0)
    }

    @Test("remote collisions replace display metadata while preserving local message counts and provenance")
    func remoteCollisionWinsMetadataAndRetainsLocalCounts() throws {
        let local = remoteMergeLocal(
            id: "same-session",
            directory: "/mac/local-worktree",
            title: "local title",
            model: "local-model",
            created: 10,
            active: 100,
            messages: 12,
            users: 5,
            assistants: 7,
            parent: "local-parent"
        )
        let remote = remoteMergeReplica(
            id: "same-session",
            directory: "/linux/remote-worktree",
            summary: "remote title",
            firstPrompt: "remote prompt",
            model: "remote-model",
            created: 20,
            updated: 220,
            active: 210,
            turns: 3,
            parent: "different-remote-parent"
        )

        let entry = try #require(LiveRemoteSessionMerge.merge(
            local: [local],
            remote: [remote],
            repositoryRemotes: [],
            limit: 10
        ).first)

        #expect(entry.source == .both)
        #expect(entry.firstPrompt == "remote prompt")
        #expect(entry.listing.title == "remote title")
        #expect(entry.listing.model == "remote-model")
        #expect(entry.listing.workingDirectory == "/linux/remote-worktree")
        #expect(entry.listing.createdAt == remoteMergeDate(20))
        #expect(entry.listing.lastActivityAt == remoteMergeDate(210))
        #expect(entry.listing.messageCount == 12)
        #expect(entry.listing.userMessageCount == 5)
        #expect(entry.listing.assistantMessageCount == 7)
        #expect(entry.listing.parentSessionID == "local-parent")
    }

    @Test("remote nil model and empty summary override existing local display metadata")
    func missingRemoteDisplayMetadataStillWinsCollision() throws {
        let local = remoteMergeLocal(
            id: "remote-clears-display",
            title: "stale local title",
            model: "stale-local-model"
        )
        let remote = remoteMergeReplica(
            id: "remote-clears-display",
            summary: "",
            firstPrompt: nil,
            model: nil,
            parent: "must-not-replace-local-nil"
        )

        let entry = try #require(LiveRemoteSessionMerge.merge(
            local: [local],
            remote: [remote],
            repositoryRemotes: [],
            limit: 1
        ).first)

        #expect(entry.source == .both)
        #expect(entry.listing.title == nil)
        #expect(entry.listing.model == nil)
        #expect(entry.firstPrompt == nil)
        #expect(entry.listing.parentSessionID == nil)
    }

    @Test("last-active timestamps use the newer lane and fall back to the remote update timestamp")
    func activityTimestampsPreserveTheNewestRealLane() throws {
        let newerLocal = remoteMergeLocal(id: "newer-local", active: 500)
        let olderRemote = remoteMergeReplica(id: "newer-local", updated: 700, active: 300)
        let updatedFallbackLocal = remoteMergeLocal(id: "updated-fallback", active: 400)
        let updatedFallbackRemote = remoteMergeReplica(
            id: "updated-fallback",
            updated: 600,
            active: nil
        )
        let remoteOnly = remoteMergeReplica(
            id: "remote-updated-only",
            updated: 550,
            active: nil
        )

        let merged = LiveRemoteSessionMerge.merge(
            local: [newerLocal, updatedFallbackLocal],
            remote: [olderRemote, updatedFallbackRemote, remoteOnly],
            repositoryRemotes: [],
            limit: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: merged.map {
            ($0.listing.sessionID, $0.listing.lastActivityAt)
        })

        #expect(byID["newer-local"] == remoteMergeDate(500))
        #expect(byID["updated-fallback"] == remoteMergeDate(600))
        #expect(byID["remote-updated-only"] == remoteMergeDate(550))
        #expect(merged.map(\.listing.sessionID)
            == ["updated-fallback", "remote-updated-only", "newer-local"])
    }

    @Test("negative registry turns and malformed local message counters never underflow")
    func negativeMessageCountsAreClamped() throws {
        let negativeRemote = remoteMergeReplica(
            id: "negative-remote",
            directory: "/negative/remote",
            turns: -42
        )
        let negativeLocal = remoteMergeLocal(
            id: "negative-local",
            directory: "/negative/local",
            messages: -9,
            users: -3,
            assistants: -5
        )
        let growsFromRemote = remoteMergeLocal(id: "grows", messages: 2, users: 1)
        let largerRemote = remoteMergeReplica(id: "grows", turns: 8)

        let merged = LiveRemoteSessionMerge.merge(
            local: [negativeLocal, growsFromRemote],
            remote: [negativeRemote, largerRemote],
            repositoryRemotes: [],
            limit: 10
        )
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.listing.sessionID, $0) })

        #expect(byID["negative-remote"]?.listing.messageCount == 0)
        #expect(byID["negative-local"]?.listing.messageCount == 0)
        #expect(byID["negative-local"]?.listing.userMessageCount == 0)
        #expect(byID["negative-local"]?.listing.assistantMessageCount == 0)
        #expect(byID["grows"]?.listing.messageCount == 8)
        #expect(byID["grows"]?.listing.userMessageCount == 1)
    }

    @Test("repository-scoped listing matches SSH and HTTPS but never imports an identical path from another host")
    func repositoryFilteringIsTransportAgnosticAndHostBound() {
        let trusted = remoteMergeReplica(
            id: "trusted-repository",
            updated: 300,
            repository: "https://github.com/Acme/Private.git"
        )
        let hostile = remoteMergeReplica(
            id: "hostile-repository",
            updated: 400,
            repository: "https://evil.example/Acme/Private.git"
        )
        let missing = remoteMergeReplica(
            id: "missing-repository",
            updated: 500,
            repository: nil
        )

        let merged = LiveRemoteSessionMerge.merge(
            local: [remoteMergeLocal(id: "always-local", active: 100)],
            remote: [trusted, hostile, missing],
            repositoryRemotes: ["git@GITHUB.com:Acme/Private.git"],
            limit: 10
        )

        #expect(merged.map(\.listing.sessionID) == ["trusted-repository", "always-local"])
        #expect(merged.map(\.source) == [.remote, .local])
    }

    @Test("a malformed requested repository never silently widens the registry search")
    func invalidRepositoryScopeRejectsEveryRemoteRow() {
        let trustedLooking = remoteMergeReplica(
            id: "must-not-be-imported",
            repository: "https://github.com/acme/private"
        )

        let merged = LiveRemoteSessionMerge.merge(
            local: [remoteMergeLocal(id: "local-preserved")],
            remote: [trustedLooking],
            repositoryRemotes: ["file:///tmp/private", "github.com/acme/private"],
            limit: 10
        )

        #expect(merged.map(\.listing.sessionID) == ["local-preserved"])
        #expect(merged.first?.source == .local)
    }

    @Test("an unscoped listing preserves remote sessions without repository metadata")
    func absentRepositoryScopeDoesNotInventAFilter() {
        let missing = remoteMergeReplica(id: "without-repository", repository: nil)
        let present = remoteMergeReplica(
            id: "with-repository",
            updated: 300,
            repository: "https://other.example/org/repository"
        )

        let merged = LiveRemoteSessionMerge.merge(
            local: [],
            remote: [missing, present],
            repositoryRemotes: [],
            limit: 10
        )

        #expect(merged.map(\.listing.sessionID)
            == ["with-repository", "without-repository"])
    }

    @Test("equal effective timestamps sort deterministically by ascending session identity")
    func equalActivityUsesStableIdentityTieBreaker() {
        let entries = LiveRemoteSessionMerge.merge(
            local: [
                remoteMergeLocal(id: "session-z", active: 500),
                remoteMergeLocal(id: "session-b", active: 500),
            ],
            remote: [
                remoteMergeReplica(id: "session-y", active: 500),
                remoteMergeReplica(id: "session-a", active: 500),
            ],
            repositoryRemotes: [],
            limit: 10
        )

        #expect(entries.map(\.listing.sessionID)
            == ["session-a", "session-b", "session-y", "session-z"])
    }

    @Test("zero-message sessions deduplicate normalized cwd before the final page limit")
    func emptySessionDeduplicationPrecedesPagination() {
        let entries = LiveRemoteSessionMerge.merge(
            local: [
                remoteMergeLocal(
                    id: "empty-newest",
                    directory: "/repo/./worktree/",
                    active: 600,
                    messages: 0,
                    users: 0
                ),
                remoteMergeLocal(
                    id: "empty-older-duplicate",
                    directory: "/repo/worktree",
                    active: 550,
                    messages: 0,
                    users: 0
                ),
                remoteMergeLocal(
                    id: "messaged-same-directory",
                    directory: "/repo/worktree/",
                    active: 500,
                    messages: 2,
                    users: 1,
                    assistants: 1
                ),
                remoteMergeLocal(
                    id: "different-empty-directory",
                    directory: "/other/worktree",
                    active: 450,
                    messages: 0,
                    users: 0
                ),
            ],
            remote: [],
            repositoryRemotes: [],
            limit: 3
        )

        #expect(entries.map(\.listing.sessionID) == [
            "empty-newest",
            "messaged-same-directory",
            "different-empty-directory",
        ])
    }

    @Test("root and empty cwd spellings collapse to the same empty-session identity")
    func emptyRootDirectorySpellingsDeduplicate() {
        let entries = LiveRemoteSessionMerge.merge(
            local: [
                remoteMergeLocal(id: "root-newest", directory: "/", active: 200, messages: 0),
                remoteMergeLocal(id: "empty-root", directory: "", active: 100, messages: 0),
            ],
            remote: [],
            repositoryRemotes: [],
            limit: 10
        )

        #expect(entries.map(\.listing.sessionID) == ["root-newest"])
    }

    @Test("remote duplicates do not fabricate local provenance")
    func repeatedRegistryRowsRemainRemoteOnly() throws {
        let first = remoteMergeReplica(id: "repeated-remote", updated: 400, turns: 9)
        let second = remoteMergeReplica(
            id: "repeated-remote",
            summary: "latest registry row",
            updated: 300,
            turns: 2
        )

        let entry = try #require(LiveRemoteSessionMerge.merge(
            local: [],
            remote: [first, second],
            repositoryRemotes: [],
            limit: 5
        ).first)

        #expect(entry.source == .remote)
        #expect(entry.listing.title == "latest registry row")
        #expect(entry.listing.messageCount == 9)
        #expect(entry.listing.lastActivityAt == remoteMergeDate(400))
    }

    @Test("unsafe identities and terminal-control metadata are rejected without affecting valid local rows")
    func unsafeRemoteRowsFailClosed() {
        let unsafe = [
            remoteMergeReplica(id: "../outside"),
            remoteMergeReplica(id: ""),
            remoteMergeReplica(id: "embedded\u{0000}null"),
            remoteMergeReplica(id: "newline-summary", summary: "title\nINJECTED"),
            remoteMergeReplica(id: "escape-prompt", firstPrompt: "\u{001B}[31msecret"),
            remoteMergeReplica(id: "bad-cwd", directory: "/safe\n/unsafe"),
            remoteMergeReplica(id: "bad-model", model: "model\u{0000}injected"),
            remoteMergeReplica(id: "bad-parent", parent: "../../parent"),
        ]

        let merged = LiveRemoteSessionMerge.merge(
            local: [remoteMergeLocal(id: "trusted-local")],
            remote: unsafe,
            repositoryRemotes: [],
            limit: 20
        )

        #expect(merged.map(\.listing.sessionID) == ["trusted-local"])
    }

    @Test("oversized registry display fields are bounded before entering local session results")
    func oversizedRegistryRowsAreIgnored() {
        let oversized = String(
            repeating: "x",
            count: LiveRemoteSessionMerge.maximumDisplayBytes + 1
        )
        let invalid = [
            remoteMergeReplica(id: "oversized-summary", summary: oversized),
            remoteMergeReplica(id: "oversized-cwd", directory: oversized),
            remoteMergeReplica(id: "oversized-prompt", firstPrompt: oversized),
            remoteMergeReplica(id: "oversized-model", model: oversized),
        ]
        let valid = remoteMergeReplica(id: "normal-row")

        let merged = LiveRemoteSessionMerge.merge(
            local: [],
            remote: invalid + [valid],
            repositoryRemotes: [],
            limit: Int.max
        )

        #expect(merged.map(\.listing.sessionID) == ["normal-row"])
    }

    @Test("zero and negative limits return nothing without widening either session lane")
    func nonpositiveLimitsReturnEmptyResults() {
        let local = [remoteMergeLocal(id: "local")]
        let remote = [remoteMergeReplica(id: "remote")]

        #expect(LiveRemoteSessionMerge.merge(
            local: local,
            remote: remote,
            repositoryRemotes: [],
            limit: 0
        ).isEmpty)
        #expect(LiveRemoteSessionMerge.merge(
            local: local,
            remote: remote,
            repositoryRemotes: [],
            limit: -1
        ).isEmpty)
    }

    @Test("multiple repository remotes match only their exact normalized host and case-sensitive path")
    func multipleRepositoryRemotesRemainExact() {
        let github = remoteMergeReplica(
            id: "github-match",
            updated: 400,
            repository: "ssh://git@github.com/acme/repository.git"
        )
        let gitlab = remoteMergeReplica(
            id: "gitlab-match",
            updated: 300,
            repository: "https://gitlab.example/acme/repository.git"
        )
        let wrongPathCase = remoteMergeReplica(
            id: "wrong-path-case",
            updated: 500,
            repository: "https://github.com/Acme/repository.git"
        )

        let entries = LiveRemoteSessionMerge.merge(
            local: [],
            remote: [github, gitlab, wrongPathCase],
            repositoryRemotes: [
                "https://GitHub.com/acme/repository.git",
                "git@gitlab.example:acme/repository.git",
            ],
            limit: 10
        )

        #expect(entries.map(\.listing.sessionID) == ["github-match", "gitlab-match"])
    }
}
