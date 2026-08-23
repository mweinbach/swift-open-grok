import Foundation
import OpenGrokFastWorktree
import OpenGrokWorkspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Rust `xai-grok-workspace/src/trust.rs:350-406`: folder-trust identity is
/// repository-wide, while configuration and filesystem authority remain bound
/// to the checkout the session actually opened.
enum LiveWorkspaceTrustIdentity {
    private struct GitTopology {
        let root: URL
        let commonDirectory: URL
        let checkoutGitDirectory: URL
    }

    static func resolve(
        workingDirectory: URL,
        environment: [String: String]
    ) -> URL {
        let effectiveDirectory = canonical(workingDirectory)
        let identity = resolve(
            workingDirectory: effectiveDirectory,
            openGrokHome: OpenGrokHomeResolver.resolve(environment: environment)
        )
        return isUnsafeTrustRoot(identity.path, home: environment["HOME"])
            ? effectiveDirectory
            : identity
    }

    static func resolve(
        workingDirectory: URL,
        openGrokHome: URL
    ) -> URL {
        let effectiveDirectory = canonical(workingDirectory)
        let topology = gitTopology(at: effectiveDirectory)

        if let source = registeredSource(
            workingDirectory: effectiveDirectory,
            topology: topology,
            openGrokHome: openGrokHome
        ) {
            return source
        }

        guard let topology else { return effectiveDirectory }
        guard !samePath(topology.commonDirectory, topology.checkoutGitDirectory) else {
            return topology.root
        }

        let mainCheckout = topology.commonDirectory.deletingLastPathComponent()
        guard samePath(
            canonical(mainCheckout.appendingPathComponent(".git")),
            topology.commonDirectory
        ),
        let mainTopology = gitTopology(at: mainCheckout),
        samePath(mainTopology.root, mainCheckout),
        samePath(mainTopology.commonDirectory, topology.commonDirectory)
        else {
            // Bare and --separate-git-dir worktrees have no conventional main
            // checkout. Their gitdir parent may contain unrelated repositories.
            return topology.root
        }
        return mainTopology.root
    }

    private static func registeredSource(
        workingDirectory: URL,
        topology: GitTopology?,
        openGrokHome: URL
    ) -> URL? {
        let registry = WorktreeRegistry(openGrokHome: openGrokHome)
        let ownerHome = canonical(openGrokHome)
        let expectedPool = ownerHome.appendingPathComponent("worktrees", isDirectory: true)
            .standardizedFileURL
        let pool = canonical(registry.poolRoot)
        guard samePath(expectedPool, pool),
              relativeComponents(of: workingDirectory, below: pool)?.isEmpty == false,
              registryFileIsDirectlyOwned(registry.databaseURL, ownerHome: ownerHome),
              let records = try? registry.records()
        else {
            return nil
        }

        let candidates = records.compactMap { record -> (WorktreeRecord, URL)? in
            let lexicalRecord = record.url.standardizedFileURL
            guard let relative = relativeComponents(
                of: lexicalRecord,
                below: registry.poolRoot.standardizedFileURL
            ) ?? relativeComponents(of: lexicalRecord, below: expectedPool),
            !relative.isEmpty
            else {
                return nil
            }

            let expectedRecord = relative.reduce(expectedPool) {
                $0.appendingPathComponent($1, isDirectory: true)
            }.standardizedFileURL
            let actualRecord = canonical(lexicalRecord)
            guard samePath(expectedRecord, actualRecord),
                  relativeComponents(of: workingDirectory, below: actualRecord) != nil,
                  FileManager.default.fileExists(atPath: actualRecord.path)
            else {
                return nil
            }
            return (record, actualRecord)
        }.sorted { $0.1.path.count > $1.1.path.count }

        guard let (record, checkout) = candidates.first else { return nil }
        let recordedSource = canonical(record.sourceURL)
        guard let sourceTopology = gitTopology(at: recordedSource),
              relativeComponents(of: recordedSource, below: sourceTopology.root) != nil
        else {
            return nil
        }

        if let topology {
            guard samePath(topology.root, checkout) else { return nil }
            if samePath(topology.commonDirectory, sourceTopology.commonDirectory) {
                return sourceTopology.root
            }
            guard record.creationMode == .standalone,
                  standaloneSharesRecordedCommit(
                    record,
                    checkout: checkout,
                    source: sourceTopology.root
                  )
            else {
                return nil
            }
            return sourceTopology.root
        }

        // Rust also recognizes a registry-owned standalone snapshot before its
        // Git metadata is populated. A present or dangling .git entry is not
        // equivalent to absent metadata and must never bypass topology checks.
        guard record.creationMode == .standalone,
              !metadataExists(checkout.appendingPathComponent(".git"))
        else {
            return nil
        }
        return sourceTopology.root
    }

    private static func standaloneSharesRecordedCommit(
        _ record: WorktreeRecord,
        checkout: URL,
        source: URL
    ) -> Bool {
        let commit: String
        if !record.head.isEmpty {
            commit = record.head
        } else {
            guard let result = try? runGit(["rev-parse", "--verify", "HEAD"], cwd: source),
                  result.exitCode == 0
            else {
                return false
            }
            commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (40...64).contains(commit.utf8.count),
              commit.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value)
                      || (97...102).contains($0.value)
                      || (65...70).contains($0.value)
              })
        else {
            return false
        }

        let expression = "\(commit)^{commit}"
        guard let sourceResult = try? runGit(["cat-file", "-e", expression], cwd: source),
              sourceResult.exitCode == 0,
              let checkoutResult = try? runGit(["cat-file", "-e", expression], cwd: checkout)
        else {
            return false
        }
        return checkoutResult.exitCode == 0
    }

    private static func gitTopology(at workingDirectory: URL) -> GitTopology? {
        guard nearestGitMetadata(for: workingDirectory) != nil,
              let result = try? runGit(
                ["rev-parse", "--show-toplevel", "--git-common-dir", "--git-dir"],
                cwd: workingDirectory
              ),
              result.exitCode == 0
        else {
            return nil
        }

        let components = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty })
        else {
            return nil
        }

        let root = canonical(URL(fileURLWithPath: components[0]))
        guard relativeComponents(of: workingDirectory, below: root) != nil else {
            return nil
        }
        let common = canonical(URL(fileURLWithPath: components[1], relativeTo: workingDirectory))
        let gitDirectory = canonical(URL(fileURLWithPath: components[2], relativeTo: workingDirectory))
        return GitTopology(root: root, commonDirectory: common, checkoutGitDirectory: gitDirectory)
    }

    private static func nearestGitMetadata(for workingDirectory: URL) -> URL? {
        var candidate = workingDirectory
        while true {
            let metadata = candidate.appendingPathComponent(".git")
            if metadataExists(metadata) { return metadata }
            let parent = candidate.deletingLastPathComponent()
            guard !samePath(parent, candidate) else { return nil }
            candidate = parent
        }
    }

    private static func metadataExists(_ path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.path)
            || (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil
    }

    private static func registryFileIsDirectlyOwned(_ path: URL, ownerHome: URL) -> Bool {
        guard samePath(canonical(path.deletingLastPathComponent()), ownerHome),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              samePath(canonical(path), ownerHome.appendingPathComponent("worktrees.db"))
        else {
            return false
        }
        #if canImport(Darwin) || canImport(Glibc)
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == UInt32(geteuid())
        else {
            return false
        }
        #endif
        return true
    }

    private static func relativeComponents(of directory: URL, below parent: URL) -> [String]? {
        let childComponents = directory.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard childComponents.count >= parentComponents.count else { return nil }
        for (left, right) in zip(childComponents.prefix(parentComponents.count), parentComponents) {
            #if os(Windows)
            guard left.caseInsensitiveCompare(right) == .orderedSame else { return nil }
            #else
            guard left == right else { return nil }
            #endif
        }
        return Array(childComponents.dropFirst(parentComponents.count))
    }

    private static func canonical(_ path: URL) -> URL {
        path.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        #if os(Windows)
        return first.standardizedFileURL.path.caseInsensitiveCompare(
            second.standardizedFileURL.path
        ) == .orderedSame
        #else
        return first.standardizedFileURL.path == second.standardizedFileURL.path
        #endif
    }
}
