import Foundation
import Domain
import Input
import Focus

enum AuthenticationScreen { case qr, credentials, approval, guardCode }

extension LibraryModel {
    func startServices() {
        startLogServices()
        requestInstallationDriveRefresh()
        guard !isPreview, let source else { return }
        startInstallServices()
        startCloudServices()
        startSessionServices()
        startAccountPolling()
    }
    func startAccountPolling() {
        guard !isPreview, periodicSyncTask == nil, let source else { return }
        let attempt = authAttempt
        periodicSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let restoredIdentity = try await source.auth.identity()
                guard !Task.isCancelled else { return }
                // Startup restoration may finish after the player has signed in again.
                if authAttempt == attempt {
                    identity = restoredIdentity
                    if identity != nil { refreshLibrary() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if authAttempt == attempt { recordSyncFailure(error) }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
                if identity != nil { refreshLibrary() }
            }
        }
    }
    func stopServices() {
        detailSizeTask?.cancel(); detailSizeTask = nil
        installationDriveTask?.cancel(); installationDriveTask = nil; installationDriveGeneration = UUID()
        notifications = []; notificationJobs = nil
        logObserver?.cancel(); logObserver = nil
        cancelAuthentication(); syncTask?.cancel(); periodicSyncTask?.cancel(); setupTask?.cancel()
        installObserver?.cancel(); installOfferTask?.cancel()
        sessionObserver?.cancel()
        cloudObserver?.cancel()
        uninstallTask?.cancel()
    }
    func beginSignIn(resumingInstall gameID: GameID? = nil) {
        guard !resetBusy else { return }
        guard source != nil else {
            show(.information("Steam sign-in is available in the live app. Launch without --preview to connect your account.")); return
        }
        cancelAuthentication()
        installAfterAuthentication = gameID
        panel = nil; authScreen = .qr; authIndex = 0
        authMessage = "Connecting to Steam…"
        runAuthentication(password: false)
    }
    private func runAuthentication(password: Bool) {
        guard let source else { return }
        authTask?.cancel(); authError = nil
        let attempt = UUID(); authAttempt = attempt
        let name = accountNameDraft, secret = passwordDraft
        passwordDraft = ""
        authTask = Task { [weak self] in
            guard let self else { return }
            let events: @Sendable (AuthenticationEvent) -> Void = { [weak self] event in
                Task { @MainActor in
                    guard let self, self.authAttempt == attempt, self.authScreen != nil else { return }
                    switch event {
                    case .qrChallenge(let url, let expiry): self.authQR = url; self.authExpiresAt = expiry; self.authMessage = "Waiting for your phone"
                    case .awaitingApproval: self.authScreen = .approval; self.authMessage = "Approve Playden in the Steam app on your phone."
                    case .expired: self.authQR = nil; self.authMessage = "Code expired · getting a new one…"
                    }
                }
            }
            do {
                let result: SourceIdentity
                if password {
                    result = try await source.auth.signIn(accountName: name, password: secret,
                        codeProvider: { [weak self] challenge in
                            guard let self else { throw CancellationError() }
                            return try await self.requestGuardCode(challenge, attempt: attempt)
                        }, onEvent: events)
                } else { result = try await source.auth.signInWithQR(onEvent: events) }
                try Task.checkCancellation()
                guard authAttempt == attempt else { return }
                let pendingInstall = installAfterAuthentication
                identity = result; syncError = nil; clearSignInIssue(); cancelAuthentication(); refreshLibrary()
                if let pendingInstall { beginInstall(pendingInstall) }
                else {
                    selectTab(.home)
                    if setupScreen == .account { openVolumeSetup(firstRun: true) }
                }
            } catch {
                guard authAttempt == attempt, !Task.isCancelled else { return }
                authQR = nil; authError = error.localizedDescription; authMessage = "Couldn’t sign in"
                authIndex = 0
            }
        }
    }
    func cancelAuthentication() {
        authAttempt = UUID(); authTask?.cancel(); authTask = nil
        guardContinuation?.resume(throwing: CancellationError()); guardContinuation = nil
        authScreen = nil; authQR = nil; authExpiresAt = nil; authError = nil
        installAfterAuthentication = nil
        accountNameDraft = ""; passwordDraft = ""
        if maskedText || panel == .textEditor(.accountName) { panel = nil; textEditor = TextEditorState() }
    }
    private func requestGuardCode(_ challenge: GuardChallenge, attempt: UUID) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard authAttempt == attempt else { throw CancellationError() }
            authScreen = .guardCode
            authMessage = challenge == .email ? "Enter the Steam Guard code from your email." : "Enter the Steam Guard code from the Steam app."
            beginText(.guardCode)
            return try await withCheckedThrowingContinuation { guardContinuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.authAttempt == attempt else { return }
                self.guardContinuation?.resume(throwing: CancellationError()); self.guardContinuation = nil
            }
        }
    }
    func finishAuthenticationText(_ purpose: TextPurpose) {
        let value = textEditor.text
        if purpose == .guardCode {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { keyboardError = "Enter your Steam Guard code."; return }
            guardContinuation?.resume(returning: value.trimmingCharacters(in: .whitespacesAndNewlines)); guardContinuation = nil
            authScreen = .approval; authMessage = "Verifying your code…"
        } else if purpose == .accountName { accountNameDraft = value.trimmingCharacters(in: .whitespacesAndNewlines); authIndex = 1 }
        else { passwordDraft = value; authIndex = 2 }
        panel = nil; textEditor = TextEditorState()
    }
    var authenticationActions: [String] {
        switch authScreen {
        case .qr: authError == nil ? ["Use password instead", "Skip for now"] : ["Retry", "Use password instead", "Skip for now"]
        case .credentials: ["Account name", "Password", "Sign in", "Back"]
        case .guardCode: ["Enter code", "Cancel"]
        default: authError == nil ? ["Cancel"] : ["Try again", "Cancel"]
        }
    }
    func performAuthentication(_ action: InputAction) {
        switch action {
        case .back: leaveAuthentication()
        case .move(let direction): authIndex = min(max(0, authIndex + (direction == .up || direction == .left ? -1 : 1)), authenticationActions.count - 1)
        case .confirm: activateAuthentication()
        default: break
        }
    }
    func activateAuthentication() {
        guard let title = authenticationActions[safe: authIndex] else { return }
        switch title {
        case "Retry": beginSignIn(resumingInstall: installAfterAuthentication)
        case "Use password instead", "Try again":
            let pendingInstall = installAfterAuthentication
            cancelAuthentication(); authScreen = .credentials; authIndex = 0
            installAfterAuthentication = pendingInstall
        case "Account name": beginText(.accountName)
        case "Password": beginText(.password)
        case "Enter code": beginText(.guardCode)
        case "Sign in":
            guard !accountNameDraft.isEmpty, !passwordDraft.isEmpty else { authError = "Enter your account name and password."; return }
            authScreen = .approval; authIndex = 0; authMessage = "Signing in…"; runAuthentication(password: true)
        default: leaveAuthentication()
        }
    }
    private func leaveAuthentication() {
        cancelAuthentication()
        if setupScreen == .account { openVolumeSetup(firstRun: true) }
    }
    func refreshLibrary() {
        guard !resetBusy else { return }
        guard let source, let syncCoordinator else { return }
        syncTask?.cancel(); syncError = nil; syncing = true
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await syncCoordinator.refresh(source: source) { [weak self] in
                    Task { @MainActor in self?.reloadCatalog() }
                }
                if !Task.isCancelled { clearSignInIssue(); reloadCatalog(); syncing = false; loadDetailDownloadSize() }
            } catch {
                guard !Task.isCancelled else { return }
                syncing = false; recordSyncFailure(error)
            }
        }
    }
    /// A stale sign-in is a dead end for the passive library notice: nothing the player does in
    /// the launcher clears it. Raise those failures as a notification that offers the way out.
    func recordSyncFailure(_ error: Error) {
        syncError = error.localizedDescription
        guard let failure = error as? SourceFailure,
              [.signedOut, .expired, .credentialsRejected].contains(failure) else { return }
        reportSessionIssue(.init(stage: failure == .expired ? "Sign-in expired" : "Sign in to Steam",
                                 reason: error.localizedDescription, output: error.localizedDescription),
                           recovery: .signIn)
    }
    func clearSignInIssue() {
        guard sessionIssueRecovery == .signIn else { return }
        sessionIssue = nil
    }
    func signOut() {
        guard !resetBusy else { return }
        guard let source, let catalog else { return }
        cancelAuthentication(); syncTask?.cancel(); panel = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                await syncCoordinator?.cancel()
                await stopUninstallPreparation()
                await stopCloudCommands()
                try await source.auth.signOut()
                try catalog.clearSourceCatalog(source.id)
                identity = nil; syncError = nil; clearSignInIssue(); syncing = false; cloudStatuses.removeAll(); reloadCatalog()
            } catch { show(.information(error.localizedDescription)) }
        }
    }
    func reloadCatalog() {
        let focusedID = focusedGame?.id
        restoringState = true; restoreCatalog(); restoringState = false
        refreshCloudAvailability()
        if let focusedID, let index = filteredGames.firstIndex(where: { $0.id == focusedID }) { libraryCursor = GridCursor(index: index) }
        if let detailID, !games.contains(where: { $0.id == detailID }) { self.detailID = nil }
    }
}
