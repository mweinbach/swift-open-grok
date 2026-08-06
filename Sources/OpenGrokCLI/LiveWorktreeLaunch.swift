import Foundation
import OpenGrokFastWorktree

struct LiveWorktreePreparation: Sendable {
    let sourceDirectory: URL
    let effectiveDirectory: URL
    let recordID: String
    let registry: WorktreeRegistry
}

enum LiveWorktreeLaunch {
    static func prepare(
        options: CLIExecutionOptions,
        sourceDirectory: URL,
        openGrokHome: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> LiveWorktreePreparation? {
        guard let requestedLabel = options.worktree else { return nil }
        if options.forkSession {
            throw CLIApplicationError.failed(
                "--fork-session cannot be combined with --worktree"
            )
        }

        let identity = try discoverGitRepo(at: sourceDirectory)
        guard let sourceRoot = identity.toplevel else {
            throw CLIApplicationError.failed("--worktree requires a non-bare git repository")
        }
        let registry = WorktreeRegistry(openGrokHome: openGrokHome)
        let repositoryName = sanitizedComponent(sourceRoot.lastPathComponent)
        let worktreeID = UUID().uuidString
        let destination = registry.poolRoot
            .appendingPathComponent("\(repositoryName)-\(worktreeID)", isDirectory: true)
        let ref = options.worktreeRef ?? "HEAD"
        let report: WorktreeReport
        do {
            report = try WorktreeBuilder(
                source: sourceDirectory,
                dest: destination,
                gitRef: ref,
                workingTree: .cleanTracked,
                ignoredFiles: .skip,
                creationMode: .gitCheckout,
                allowedPoolRoot: registry.poolRoot
            ).create(isCancelled: isCancelled)
        } catch let error as FastWorktreeError {
            throw CLIApplicationError.failed("could not create worktree: \(error)")
        } catch {
            throw CLIApplicationError.failed("could not create worktree: \(error)")
        }

        let relative = relativePath(from: sourceRoot, to: sourceDirectory)
        let effectiveDirectory = relative.isEmpty
            ? destination
            : destination.appendingPathComponent(relative, isDirectory: true)
        let record = WorktreeRecord(
            id: worktreeID,
            path: destination,
            sourceRepository: sourceRoot,
            repositoryName: sourceRoot.lastPathComponent,
            kind: .launch,
            creationMode: report.creationMode,
            ref: ref,
            head: report.commit,
            label: requestedLabel.isEmpty ? nil : requestedLabel
        )
        do {
            try registry.register(record)
        } catch {
            _ = try? removeWorktreeAt(dest: destination, primaryCheckout: sourceRoot, force: true)
            throw CLIApplicationError.failed("could not register worktree: \(error)")
        }
        return LiveWorktreePreparation(
            sourceDirectory: sourceDirectory,
            effectiveDirectory: effectiveDirectory,
            recordID: record.id,
            registry: registry
        )
    }

    static func attachSession(
        _ preparation: LiveWorktreePreparation?,
        sessionID: String
    ) throws {
        guard let preparation else { return }
        do {
            try preparation.registry.updateSession(id: preparation.recordID, sessionID: sessionID)
        } catch {
            throw CLIApplicationError.failed("could not persist worktree session: \(error)")
        }
    }

    private static func relativePath(from root: URL, to child: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.starts(with: rootComponents) else { return "" }
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let result = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? String(character)
                : "-"
        }.joined()
        return result.isEmpty ? "repo" : result
    }
}
