import Foundation
import Domain
import Input

enum ResetAction { case cancel, reset, checkAgain }

extension LibraryModel {
    func showResetAppData() {
        guard !resetBusy else { return }
        resetError = nil; resetBlocker = nil
        show(.resetAppData); checkResetReview()
    }
    func closeResetAppData() { guard !resetBusy else { return }; panel = nil }
    var resetActions: [ResetAction] { resetBusy ? [] : resetBlocker == nil ? [.cancel, .reset] : [.cancel, .checkAgain] }
    func resetActionTitle(_ action: ResetAction) -> String {
        switch action { case .cancel: "Cancel"; case .reset: resetError == nil ? "Reset Big Screen" : "Retry reset"; case .checkAgain: "Check again" }
    }
    func checkResetReview() {
        resetBlocker = nil
        do { try checkResetAvailability() }
        catch { resetBlocker = (error as? OperationFailure)?.reason ?? "The app data could not be checked. Try again." }
        panelIndex = 0
    }
    private func checkResetAvailability() throws {
        if hasActiveSession || sessionBusy || (sessions != nil && !sessionReady) {
            throw resetIssue("Close the game and let session recovery finish before resetting Big Screen.")
        }
        if setupBusy || uninstallBusy || !cloudCommands.isEmpty {
            throw resetIssue("Let game setup, removal or save sync finish before resetting Big Screen.")
        }
        if let catalog { try catalog.checkAppReset() }
        else if !isPreview { throw resetIssue("The app database is unavailable. Restart Big Screen before resetting it.") }
    }
    func performResetInput(_ action: InputAction) -> Bool {
        guard panel == .resetAppData || resetBusy else { return false }
        guard !resetBusy else { return true }
        switch action {
        case .back: closeResetAppData()
        case .move(let direction): panelIndex = min(max(0, panelIndex + (direction == .left || direction == .up ? -1 : 1)), max(0, resetActions.count - 1))
        case .confirm: if let selected = resetActions[safe: panelIndex] { activateReset(selected) }
        default: break
        }
        return true
    }
    func activateReset(_ action: ResetAction) {
        guard !resetBusy, resetActions.contains(action) else { return }
        switch action {
        case .cancel: closeResetAppData()
        case .checkAgain: checkResetReview()
        case .reset:
            checkResetReview()
            guard resetBlocker == nil else { return }
            resetBusy = true; resetError = nil
            resetTask = Task { [weak self] in
                guard let self else { return }
                var signedOut = false, committed = false
                defer { resetBusy = false; resetTask = nil; startAccountPolling() }
                do {
                    // Invalidate refresh before joining its tasks, so a late owned-library or
                    // metadata response cannot repopulate the cache after reset commits.
                    let authentication = authTask, refresh = syncTask, polling = periodicSyncTask, setup = setupTask, offer = installOfferTask
                    cancelAuthentication(); refresh?.cancel(); polling?.cancel(); setup?.cancel(); offer?.cancel()
                    periodicSyncTask = nil; syncTask = nil; setupTask = nil; installOfferTask = nil
                    await syncCoordinator?.cancel()
                    await source?.auth.cancelSignIn()
                    await authentication?.value; await refresh?.value; await polling?.value; await setup?.value; await offer?.value
                    resolvingInstall = false; runtimeChecking = false
                    try checkResetAvailability()
                    try await source?.auth.signOut()
                    signedOut = true; identity = nil; cloudStatuses.removeAll(); syncing = false; syncError = nil
                    // Keychain and SQLite cannot share a transaction. If sign-out fails, local
                    // data is untouched. If the database commit fails, report the signed-out
                    // state honestly and retain the old personalization for an explicit retry.
                    try catalog?.resetAppData(); committed = true
                    persistenceError = nil
                    if catalog != nil { if isPreview { resetPreviewState() }; reloadCatalog() }
                    else { resetPreviewState() }
                    guard persistenceError == nil else { throw resetIssue("The reset completed, but the library could not be reloaded. Restart Big Screen.") }
                    loadDownloadHistory()
                    try await sessions?.setDownloadWhilePlaying(false)
                    query = ""; textEditor = .init(); symbols = false; uppercase = false
                    homeRow = 0; homeColumns = [:]; homeRowOffsets = [:]; homeScrollOffset = 0
                    libraryCursor = .init(); libraryScrollOffset = 0; railFocused = false
                    downloadIndex = 0; downloadScrollOffset = 0
                    tab = .home; detailID = nil; tabsFocused = false; sessionIssue = nil
                    resetBlocker = nil; panel = nil
                    onboarding = true; setupScreen = .controller; setupIndex = 0
                    setupFailure = nil; runtimeChecking = false
                } catch {
                    resetError = committed ? "The reset completed, but Big Screen could not finish reloading. Restart the app." :
                        signedOut ? "You’re signed out, but app data could not be reset. Your settings and library customizations are still kept. Try again." :
                        (error as? OperationFailure)?.reason ?? "Could not sign out. Your app data was not reset. Try again."
                    panel = .resetAppData; panelIndex = 0
                }
            }
        }
    }
    private func resetPreviewState() {
        restoringState = true
        for index in games.indices { games[index].isFavorite = false; games[index].isHidden = false; games[index].compatibility = .untested }
        collections = []; compatibilityNotes = [:]
        filter = .all; sort = .name; refinements = .init(); reducedMotion = false; downloadWhilePlaying = false
        gamesVolume = nil; selectedDisplayID = nil; selectedDisplayUUID = nil; selectedDisplayName = nil; startInFullscreen = true
        restoringState = false
    }
    private func resetIssue(_ reason: String) -> OperationFailure { .init(stage: "Reset Big Screen", reason: reason, output: "") }

    func configureResetSnapshot(_ screen: String) {
        guard fixedClock else { return }
        selectTab(.settings); settingsSection = 4; settingsIndex = 2; settingsRailFocused = false
        controllerName = "DUALSHOCK 4"; keyboardNavigation = false
        if screen == "settings-about" { return }
        showResetAppData()
        if screen == "settings-reset-blocked" { resetBlocker = "Pause each download or file verification in Downloads before resetting Big Screen." }
        if screen == "settings-reset-error" { resetError = "Could not sign out. Your app data was not reset. Try again." }
        if screen == "settings-reset-busy" { resetBusy = true }
    }
}
