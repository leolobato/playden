import Foundation
import Domain
import Input
import Focus
import Catalog

enum AuthenticationScreen { case qr, credentials, approval, guardCode, deviceCode }

/// Sign-in state for one store. Steam's is also reachable as `identity`, `syncError` and `syncing`.
struct AccountState: Equatable {
    var identity: SourceIdentity?
    var syncError: String?
    /// The last refresh failed because the store wants the player to sign in again.
    var needsSignIn = false
    var syncing = false
}

/// A code to enter at a URL on another device; `completeURL` already carries the code.
struct DeviceCodePrompt: Equatable {
    let userCode: String
    let verificationURL: URL
    let completeURL: URL
}

extension LibraryModel {
    func startServices() {
        startLogServices()
        requestInstallationDriveRefresh()
        guard !isPreview else { return }
        startInstallServices()
        startCloudServices()
        startSessionServices()
        startAccountPolling()
        refreshScannedLibraries()
    }
    func startAccountPolling() {
        let others = otherAccountSources
        guard !isPreview, periodicSyncTask == nil, source != nil || !others.isEmpty else { return }
        let primary = source
        let attempt = authAttempt
        periodicSyncTask = Task { [weak self] in
            guard let self else { return }
            if let primary {
                do {
                    let restoredIdentity = try await primary.auth.identity()
                    guard !Task.isCancelled else { return }
                    // Startup restoration may finish after the player has signed in again.
                    if authAttempt == attempt {
                        identity = restoredIdentity
                        if identity != nil { refreshLibrary(primary.id) }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if authAttempt == attempt { recordSyncFailure(error, sourceID: primary.id) }
                }
            }
            for other in others {
                do {
                    let restoredIdentity = try await other.auth.identity()
                    guard !Task.isCancelled else { return }
                    if account(other.id).identity == nil {
                        setIdentity(restoredIdentity, for: other.id)
                        if restoredIdentity != nil { refreshLibrary(other.id) }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if account(other.id).identity == nil { recordSyncFailure(error, sourceID: other.id) }
                }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
                for id in sources.accountSources.map(\.id) where account(id).identity != nil { refreshLibrary(id) }
            }
        }
    }
    func stopServices() {
        detailSizeTask?.cancel(); detailSizeTask = nil
        installationDriveTask?.cancel(); installationDriveTask = nil; installationDriveGeneration = UUID()
        notifications = []; notificationJobs = nil
        logObserver?.cancel(); logObserver = nil
        cancelAuthentication(); accountSyncTasks.values.forEach { $0.cancel() }; periodicSyncTask?.cancel(); scanTask?.cancel(); setupTask?.cancel()
        installObserver?.cancel(); installOfferTask?.cancel()
        sessionObserver?.cancel()
        cloudObserver?.cancel()
        uninstallTask?.cancel()
    }
    /// Signs in to `sourceID`, or to the store of the install waiting on it, or to Steam.
    func beginSignIn(_ sourceID: String? = nil, resumingInstall gameID: GameID? = nil) {
        guard !resetBusy else { return }
        let id = gameID?.source ?? sourceID ?? primaryAccountID
        guard let target = sources[id], target.capabilities.account != .none else {
            show(.information("\(accountName(id)) sign-in is available in the live app. Launch without --preview to connect your account.")); return
        }
        cancelAuthentication()
        installAfterAuthentication = gameID
        authSourceID = id
        panel = nil; authIndex = 0
        authMessage = "Connecting to \(accountName(id))…"
        if target.capabilities.account == .deviceCode { authScreen = .deviceCode; runAuthentication(mode: .deviceCode) }
        else { authScreen = .qr; runAuthentication(mode: .qr) }
    }
    private enum SignInMode { case qr, password, deviceCode }
    private func runAuthentication(password: Bool) { runAuthentication(mode: password ? .password : .qr) }
    private func runAuthentication(mode: SignInMode) {
        let sourceID = authSourceID ?? primaryAccountID
        guard let auth = sources[sourceID]?.auth else { return }
        let password = mode == .password
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
                    case .deviceCode(let code, let url, let complete, let expiry):
                        self.authDeviceCode = DeviceCodePrompt(userCode: code, verificationURL: url, completeURL: complete)
                        self.authQR = complete; self.authExpiresAt = expiry; self.authMessage = "Waiting for your phone"
                    }
                }
            }
            do {
                let result: SourceIdentity
                if password {
                    result = try await auth.signIn(accountName: name, password: secret,
                        codeProvider: { [weak self] challenge in
                            guard let self else { throw CancellationError() }
                            return try await self.requestGuardCode(challenge, attempt: attempt)
                        }, onEvent: events)
                } else if mode == .deviceCode { result = try await auth.signInWithDeviceCode(onEvent: events) }
                else { result = try await auth.signInWithQR(onEvent: events) }
                try Task.checkCancellation()
                guard authAttempt == attempt else { return }
                let pendingInstall = installAfterAuthentication
                setIdentity(result, for: sourceID); accounts[sourceID, default: .init()].syncError = nil; accounts[sourceID, default: .init()].needsSignIn = false
                clearSignInIssue(sourceID); cancelAuthentication(); refreshLibrary(sourceID)
                if let pendingInstall { beginInstall(pendingInstall, volume: installDestination, platform: installPlatform) }
                else {
                    selectTab(.home)
                    if setupScreen == .account { openVolumeSetup(firstRun: true) }
                }
            } catch {
                guard authAttempt == attempt, !Task.isCancelled else { return }
                authQR = nil; authDeviceCode = nil; authError = error.localizedDescription; authMessage = "Couldn’t sign in"
                // Terms to accept on the store's website: show the page as a QR code instead of a dead end.
                if case SourceFailure.actionRequired(let url?) = error { authQR = url; authMessage = "Accept the terms on your phone" }
                authIndex = 0
            }
        }
    }
    func cancelAuthentication() {
        authAttempt = UUID(); authTask?.cancel(); authTask = nil
        guardContinuation?.resume(throwing: CancellationError()); guardContinuation = nil
        authScreen = nil; authQR = nil; authExpiresAt = nil; authError = nil; authDeviceCode = nil; authSourceID = nil
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
        case .deviceCode: authError == nil ? ["Get a new code", "Cancel"] : ["Try again", "Cancel"]
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
        case "Retry": beginSignIn(authSourceID, resumingInstall: installAfterAuthentication)
        case "Get a new code": beginSignIn(authSourceID, resumingInstall: installAfterAuthentication)
        case "Try again" where authScreen == .deviceCode: beginSignIn(authSourceID, resumingInstall: installAfterAuthentication)
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
        // With This Mac available, leaving sign-in returns to the choice of stores.
        if setupScreen == .account {
            if localSource != nil || !otherAccountSources.isEmpty {
                setupScreen = .games; setupIndex = setupStoreChoices.firstIndex(of: .local) ?? 0
            } else { openVolumeSetup(firstRun: true) }
        }
    }
    /// Steam, and every other store the player is signed in to.
    func refreshLibrary() {
        refreshLibrary(primaryAccountID)
        for other in otherAccountSources where account(other.id).identity != nil { refreshLibrary(other.id) }
    }
    /// Each store refreshes on its own coordinator, so one store's refresh never cancels another's.
    func refreshLibrary(_ sourceID: String) {
        guard !resetBusy else { return }
        guard let source = sources[sourceID], let coordinator = libraryCoordinator(for: sourceID) else { return }
        accountSyncTasks[sourceID]?.cancel()
        accounts[sourceID, default: .init()].syncError = nil; accounts[sourceID, default: .init()].needsSignIn = false
        accounts[sourceID, default: .init()].syncing = true
        accountSyncTasks[sourceID] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await coordinator.refresh(source: source) { [weak self] in
                    Task { @MainActor in self?.reloadCatalog() }
                }
                if !Task.isCancelled {
                    clearSignInIssue(sourceID); reloadCatalog(); accounts[sourceID, default: .init()].syncing = false; loadDetailDownloadSize()
                }
            } catch {
                guard !Task.isCancelled else { return }
                accounts[sourceID, default: .init()].syncing = false; recordSyncFailure(error, sourceID: sourceID)
            }
        }
    }
    /// Stores that scan this Mac refresh on their own coordinator, so a Steam refresh never
    /// cancels a scan. A failed scan keeps the last library it found.
    func refreshScannedLibraries() {
        guard !isPreview, !resetBusy, let scanCoordinator else { return }
        let scanned = sources.all.filter { $0.capabilities.acquisition == .external }
        guard !scanned.isEmpty else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            for source in scanned {
                do {
                    _ = try await scanCoordinator.refresh(source: source)
                    guard !Task.isCancelled else { return }
                    self?.scanErrors[source.id] = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.scanErrors[source.id] = error.localizedDescription
                }
            }
            self?.reloadCatalog()
        }
    }
    /// A stale sign-in is a dead end for the passive library notice: nothing the player does in
    /// the launcher clears it. Raise those failures as a notification that offers the way out.
    func recordSyncFailure(_ error: Error, sourceID: String? = nil) {
        let id = sourceID ?? primaryAccountID
        accounts[id, default: .init()].syncError = error.localizedDescription
        guard let failure = error as? SourceFailure,
              [.signedOut, .expired, .credentialsRejected].contains(failure) else { return }
        accounts[id, default: .init()].needsSignIn = true
        reportSessionIssue(.init(stage: failure == .expired ? "Sign-in expired" : "Sign in to \(accountName(id))",
                                 reason: error.localizedDescription, output: error.localizedDescription),
                           recovery: .signIn(id))
    }
    /// Clears a "sign in again" notice for that store, or for any store when `sourceID` is nil.
    func clearSignInIssue(_ sourceID: String? = nil) {
        guard case .signIn(let id) = sessionIssueRecovery, sourceID == nil || sourceID == id else { return }
        sessionIssue = nil
    }
    func signOut(_ sourceID: String? = nil) {
        guard !resetBusy else { return }
        let id = sourceID ?? signOutSourceID ?? primaryAccountID
        guard let target = sources[id], let catalog else { return }
        let auth = target.auth, coordinator = libraryCoordinator(for: id), cloudStore = target.capabilities.cloudSaves
        cancelAuthentication(); accountSyncTasks[id]?.cancel(); panel = nil; signOutSourceID = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                await coordinator?.cancel()
                if cloudStore { await stopUninstallPreparation(); await stopCloudCommands() }
                try await auth.signOut()
                try catalog.clearSourceCatalog(id)
                accounts[id] = AccountState(); if id == primaryAccountID { loadDetailDownloadSize() }
                clearSignInIssue(id)
                if cloudStore { cloudStatuses.removeAll() }
                reloadCatalog()
            } catch { show(.information(error.localizedDescription)) }
        }
    }
    func account(_ sourceID: String) -> AccountState { accounts[sourceID] ?? AccountState() }
    /// The first store's refresh error, Steam first, with the store named when it isn't Steam.
    var librarySyncError: String? {
        if let syncError { return syncError }
        for other in otherAccountSources { if let error = account(other.id).syncError { return "\(accountName(other.id)): \(error)" } }
        return nil
    }
    var librarySyncing: Bool { syncing || otherAccountSources.contains { account($0.id).syncing } }
    func setIdentity(_ identity: SourceIdentity?, for sourceID: String) {
        if sourceID == primaryAccountID { self.identity = identity } else { accounts[sourceID, default: .init()].identity = identity }
    }
    /// The store Playden was built around. Tests stand in a fixture for it.
    var primaryAccountID: String { source?.id ?? SourceID.steam }
    var otherAccountSources: [any GameSource] { sources.accountSources.filter { $0.id != primaryAccountID } }
    func accountName(_ sourceID: String) -> String { StoreNames.name(sourceID == primaryAccountID ? SourceID.steam : sourceID) }
    func libraryCoordinator(for sourceID: String) -> LibrarySyncCoordinator? {
        sourceID == primaryAccountID ? syncCoordinator : accountCoordinators[sourceID]
    }
    /// Downloads, the games drive and CrossOver matter once any store that installs games is signed in.
    var signedInToDownloadStore: Bool {
        identity != nil || otherAccountSources.contains { $0.capabilities.acquisition == .download && account($0.id).identity != nil }
    }
    func reloadCatalog() {
        let focusedID = focusedGame?.id
        restoringState = true; restoreCatalog(); restoringState = false
        refreshCloudAvailability()
        if let focusedID, let index = filteredGames.firstIndex(where: { $0.id == focusedID }) { libraryCursor = GridCursor(index: index) }
        if let detailID, !games.contains(where: { $0.id == detailID }) { self.detailID = nil }
    }
}
