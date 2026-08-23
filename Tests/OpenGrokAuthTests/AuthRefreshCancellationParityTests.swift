import Foundation
import Testing
@testable import OpenGrokAuth

private actor LateReturningTokenRefresher: TokenRefresher {
    private var refreshWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<RefreshOutcome, Never>?

    func refresh(reason: RefreshReason, current: GrokAuth?) async -> RefreshOutcome {
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            let waiter = refreshWaiter
            refreshWaiter = nil
            waiter?.resume()
        }
    }

    func waitForRefresh() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { continuation in
            refreshWaiter = continuation
        }
    }

    func returnLate(_ outcome: RefreshOutcome) {
        let waiter = responseWaiter
        responseWaiter = nil
        waiter?.resume(returning: outcome)
    }
}

@Suite("authentication refresh cancellation and shared-flight ownership")
struct AuthRefreshCancellationParityTests {
    @Test("a cancelled late OAuth refresh cannot update disk, actor credentials, or snapshots")
    func cancelledRefreshCannotAdoptOrPersistLateOAuthCredentials() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-auth-refresh-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, environment: [:])
        var expired = GrokAuth.testDefault(key: "previous-team-bearer", authMode: .oidc)
        expired.refreshToken = "previous-team-refresh-token"
        expired.expiresAt = Date().addingTimeInterval(-600)
        try await manager.update(expired)
        let authPath = home.appendingPathComponent("auth.json")
        let originalCredentials = try Data(contentsOf: authPath)
        let refresher = LateReturningTokenRefresher()
        await manager.configureRefresher(refresher)
        var refreshed = expired
        refreshed.key = "must-not-persist-cancelled-bearer"
        refreshed.refreshToken = "must-not-persist-cancelled-refresh"
        refreshed.expiresAt = Date().addingTimeInterval(3_600)
        let task = Task {
            try await manager.auth()
        }

        await refresher.waitForRefresh()
        task.cancel()
        await refresher.returnLate(.success(refreshed))

        do {
            let credential = try await task.value
            Issue.record("cancelled refresh unexpectedly returned \(credential.key)")
        } catch is CancellationError {
            // The shared task is cancelled before it can adopt or commit.
        } catch {
            Issue.record("cancelled refresh returned an unexpected error: \(error)")
        }

        let currentCredentials = try Data(contentsOf: authPath)
        let current = await manager.currentOrExpired()
        #expect(currentCredentials == originalCredentials)
        #expect(current?.key == "previous-team-bearer")
        #expect(current?.refreshToken == "previous-team-refresh-token")
        #expect(manager.snapshotBox.read().token == "previous-team-bearer")
    }

    @Test("cancelling one waiter never cancels an OAuth refresh another caller still needs")
    func activeFollowerKeepsSharedRefreshAliveAfterLeaderCancellation() async throws {
        let flight = RefreshSingleFlight()
        let refresher = LateReturningTokenRefresher()
        let leader = Task {
            await flight.run {
                let outcome = await refresher.refresh(reason: .preRequest, current: nil)
                guard case .success = outcome else { return false }
                return !Task.isCancelled
            }
        }
        await refresher.waitForRefresh()
        let follower = Task {
            await flight.run { false }
        }

        for _ in 0..<1_000 {
            if await flight.activeWaiterCount == 2 { break }
            await Task.yield()
        }
        let joinedParticipants = await flight.activeWaiterCount
        #expect(joinedParticipants == 2)

        leader.cancel()
        let remainingParticipants = await flight.activeWaiterCount
        #expect(remainingParticipants == 1)
        await refresher.returnLate(.success(GrokAuth.testDefault(key: "shared-refreshed-token")))

        let cancelledLeader = await leader.value
        let activeFollower = await follower.value
        #expect(!cancelledLeader)
        #expect(activeFollower)
        let finalParticipants = await flight.activeWaiterCount
        #expect(finalParticipants == 0)
    }
}
