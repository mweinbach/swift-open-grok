import OpenGrokShared
import OpenGrokShell

extension LiveInteractiveControllerRenderer {
    /// Stop every remaining writer before the catalog removes this session.
    /// The shell is created lazily, so deletion before the first turn has no
    /// resident actor to clear but must still tear down its child coordinator.
    func prepareLiveSessionDeletion() async throws {
        let deletingSessionID = sessionID
        if let pagerRuntime {
            let shell = await pagerRuntime.shell
            let shellSessionID = SessionID(deletingSessionID)
            if await shell.lookupSession(shellSessionID) != nil {
                try await shell.clearSessionHistoryForDeletion(shellSessionID)
            }
        }

        if let coordinator = toolExecutor?.subagentHost?.coordinator {
            await coordinator.teardown(sessionID: deletingSessionID)
        }
    }
}
