import Testing
@testable import OpenGrokPagerRender

@Suite("permission cursor selection preserves least privilege and session scope")
struct PermissionSelectionParityTests {
    @Test("missing and malformed cursor preferences safely select allow-once")
    func invalidPreferenceDefaultsToAllowOnce() {
        #expect(PagerDefaultSelectedPermission(configuredValue: nil) == .allowOnce)
        #expect(PagerDefaultSelectedPermission(configuredValue: "") == .allowOnce)
        #expect(PagerDefaultSelectedPermission(configuredValue: "grant_everything") == .allowOnce)
    }

    @Test("cursor preference accepts upstream and legacy registry canonical values")
    func canonicalPreferenceSpellingsRemainCompatible() {
        #expect(PagerDefaultSelectedPermission(configuredValue: "ALLOW_ONCE") == .allowOnce)
        #expect(PagerDefaultSelectedPermission(configuredValue: "allow-once") == .allowOnce)
        #expect(
            PagerDefaultSelectedPermission(configuredValue: "allow-command-always")
                == .allowCommandAlways
        )
        #expect(
            PagerDefaultSelectedPermission(configuredValue: "always_allow_all_sessions")
                == .alwaysAllowAllSessions
        )
        #expect(PagerDefaultSelectedPermission(configuredValue: "reject") == .reject)
    }

    @Test("global always-approve preference never aliases the scoped edit-session row")
    func unavailableGlobalApprovalFallsBackToAllowOnce() {
        let options = PagerPermissionRequest.defaultOptions

        #expect(PagerDefaultSelectedPermission.allowOnce.initialIndex(in: options) == 1)
        #expect(PagerDefaultSelectedPermission.reject.initialIndex(in: options) == 2)
        #expect(PagerDefaultSelectedPermission.allowCommandAlways.initialIndex(in: options) == 0)
        #expect(
            PagerDefaultSelectedPermission.alwaysAllowAllSessions.initialIndex(in: options) == 1
        )
    }

    @Test("unavailable remembered-command option falls back to allow-once")
    func unavailableRememberedOptionCannotSelectBroaderApproval() {
        let options = [
            PagerPermissionOption(decision: .allowOnce, label: "Yes"),
            PagerPermissionOption(decision: .deny, label: "No"),
        ]

        #expect(PagerDefaultSelectedPermission.allowCommandAlways.initialIndex(in: options) == 0)
    }

    @Test("permission overlay paints the exact preselected request index")
    func overlayConsumesResolvedSelection() {
        let request = PagerPermissionRequest(
            id: "selected",
            toolName: "Edit",
            initialSelectedIndex: 2
        )
        let overlay = PagerOverlay.permission(request)

        guard case .permission(let prompt) = overlay.content else {
            Issue.record("expected a permission overlay")
            return
        }
        #expect(prompt.selectedIndex == 2)
    }

    @Test("invalid preselected indices are clamped instead of indexing outside options")
    func resolvedSelectionAlwaysRemainsInBounds() {
        let request = PagerPermissionRequest(
            id: "clamped",
            toolName: "Edit",
            initialSelectedIndex: 999
        )

        #expect(PagerPermissionPrompt(request: request).selectedIndex == 2)
        #expect(PagerPermissionPrompt(request: request, selectedIndex: -1).selectedIndex == 0)
    }

    @Test("configured first choice becomes sticky after an explicit user decision")
    func explicitDecisionBecomesStickyForTheSameSession() async {
        let coordinator = PagerPermissionCoordinator(defaultSelectedPermission: .reject)
        let firstRequest = PagerPermissionRequest(id: "first", toolName: "Edit")
        async let firstDecision = coordinator.decision(for: firstRequest)
        while await coordinator.currentRequest == nil {
            await Task.yield()
        }
        #expect(await coordinator.currentRequest?.initialSelectedIndex == 2)

        await coordinator.resolve(requestID: "first", decision: .allowOnce)
        #expect(await firstDecision == .allowOnce)
        #expect(await coordinator.lastSelectedPermission == .allowOnce)

        let secondRequest = PagerPermissionRequest(id: "second", toolName: "Edit")
        async let secondDecision = coordinator.decision(for: secondRequest)
        while await coordinator.currentRequest == nil {
            await Task.yield()
        }
        #expect(await coordinator.currentRequest?.initialSelectedIndex == 1)

        await coordinator.resolve(requestID: "second", decision: .deny)
        #expect(await secondDecision == .deny)
        #expect(await coordinator.lastSelectedPermission == .reject)
    }

    @Test("edit-session approval never changes later prompt preselection")
    func editSessionGrantDoesNotBecomeSticky() async {
        let coordinator = PagerPermissionCoordinator(defaultSelectedPermission: .reject)
        async let decision = coordinator.decision(for: PagerPermissionRequest(
            id: "edit",
            toolName: "Edit"
        ))
        while await coordinator.currentRequest == nil {
            await Task.yield()
        }

        await coordinator.resolve(requestID: "edit", decision: .allowSession)
        #expect(await decision == .allowSession)
        #expect(await coordinator.lastSelectedPermission == nil)
    }

    @Test("queued second prompt is reseated after the first answer becomes sticky")
    func queuedPromptUpdatesAfterPreviousSelection() async {
        let coordinator = PagerPermissionCoordinator(defaultSelectedPermission: .allowOnce)
        async let first = coordinator.decision(for: PagerPermissionRequest(
            id: "queued-first",
            toolName: "Edit"
        ))
        while await coordinator.currentRequest?.id != "queued-first" {
            await Task.yield()
        }
        async let second = coordinator.decision(for: PagerPermissionRequest(
            id: "queued-second",
            toolName: "Edit"
        ))
        while await coordinator.pendingCount < 2 {
            await Task.yield()
        }

        await coordinator.resolve(requestID: "queued-first", decision: .deny)
        #expect(await first == .deny)
        #expect(await coordinator.currentRequest?.initialSelectedIndex == 2)
        await coordinator.resolve(requestID: "queued-second", decision: .allowOnce)
        #expect(await second == .allowOnce)
    }

    @Test("different coordinators and reset never inherit another session's choice")
    func selectionHistoryIsIsolatedAndRevocable() async {
        let first = PagerPermissionCoordinator(defaultSelectedPermission: .allowOnce)
        let second = PagerPermissionCoordinator(defaultSelectedPermission: .allowOnce)
        async let decision = first.decision(for: PagerPermissionRequest(
            id: "session-a",
            toolName: "Edit"
        ))
        while await first.currentRequest == nil {
            await Task.yield()
        }
        await first.resolve(requestID: "session-a", decision: .deny)
        #expect(await decision == .deny)
        #expect(await first.lastSelectedPermission == .reject)
        #expect(await second.lastSelectedPermission == nil)

        await first.resetSelectedPermission()
        #expect(await first.lastSelectedPermission == nil)
    }
}
