import Foundation
import OpenGrokPagerRender

extension LiveInteractiveControllerRenderer {
    func beginWaveEAuth(providerName: String) {
        authPresentationTask?.cancel()
        welcomeAuthState = PagerWelcomeAuthState(
            providerName: providerName,
            phase: .signingIn,
            message: "Opening your browser…"
        )
        syncWaveEAuthPresentation()
    }

    func announceWaveEAuthURL(_ url: URL) {
        let rawURL = url.absoluteString
        welcomeAuthState?.phase = .trust
        welcomeAuthState?.url = rawURL
        welcomeAuthState?.deviceCode = PagerWelcomeAuthState.deviceCode(from: rawURL)
        welcomeAuthState?.rawURLMode = enableWaveERawAuthURLMode()
        welcomeAuthState?.message = nil
        syncWaveEAuthPresentation()
    }

    func finishWaveEAuthSuccess(_ message: String) {
        restoreMouseAfterWaveEAuth()
        welcomeAuthState?.phase = .starting
        welcomeAuthState?.url = nil
        welcomeAuthState?.deviceCode = nil
        welcomeAuthState?.rawURLMode = false
        welcomeAuthState?.message = message
        syncWaveEAuthPresentation()
        authPresentationTask?.cancel()
        authPresentationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.clearWaveEAuthPresentation()
        }
    }

    func finishWaveEAuthFailure(_ message: String) {
        authPresentationTask?.cancel()
        restoreMouseAfterWaveEAuth()
        welcomeAuthState?.phase = .failed
        welcomeAuthState?.url = nil
        welcomeAuthState?.deviceCode = nil
        welcomeAuthState?.rawURLMode = false
        welcomeAuthState?.message = message
        syncWaveEAuthPresentation()
    }

    func clearWaveEAuthPresentation() {
        authPresentationTask = nil
        welcomeAuthState = nil
        syncWaveEAuthPresentation()
    }

    private func enableWaveERawAuthURLMode() -> Bool {
        guard minimalHost == nil else { return true }
        guard mouseReportingEnabled else {
            authMouseReportingRestore = false
            return true
        }
        do {
            try renderer.setMouseReporting(false)
            authMouseReportingRestore = true
            mouseReportingEnabled = false
            return true
        } catch {
            authMouseReportingRestore = nil
            return false
        }
    }

    private func restoreMouseAfterWaveEAuth() {
        defer { authMouseReportingRestore = nil }
        guard authMouseReportingRestore == true else { return }
        do {
            try renderer.setMouseReporting(true)
            mouseReportingEnabled = true
        } catch {
            mouseReportingEnabled = false
        }
    }

    private func syncWaveEAuthPresentation() {
        if minimalHost == nil {
            if let auth = welcomeAuthState {
                if !overlays.updateWelcome(id: Self.welcomeOverlayID, { welcome in
                    welcome.auth = auth
                }) {
                    var welcome = welcomeOverlay()
                    welcome.auth = auth
                    overlays.push(.welcome(
                        id: Self.welcomeOverlayID,
                        welcome,
                        capturesInput: false
                    ))
                }
            } else if hasStartedFirstTurn {
                overlays.dismiss(id: Self.welcomeOverlayID)
            } else {
                _ = overlays.updateWelcome(id: Self.welcomeOverlayID) { welcome in
                    welcome.auth = nil
                }
            }
        }
        try? renderState()
    }
}
