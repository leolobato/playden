import AppKit
import CoreGraphics
import ColorSync
import SwiftUI
import Input
import Focus
import Catalog
import Sources
import Domain
import Runner
import Installs

@main
struct PlaydenApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, LauncherWindowControlling {
    let model: LibraryModel
    private static var isTestProcess: Bool {
        let args = ProcessInfo.processInfo.arguments
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            args.contains("-XCTest") || args.contains("-NSTreatUnknownArgumentsAsOpen")
    }
    override init() {
        let args = ProcessInfo.processInfo.arguments
        // Keep tests and visual fixtures deterministic and separate from the interactive profile.
        if args.contains("--snapshot") || args.contains("--cloud-read-check") || args.contains("--diagnose-install") || Self.isTestProcess { model = LibraryModel() }
        else {
            let preview = args.contains("--preview")
            do {
                let support = AppPaths.supportRoot()
                let root = preview ? support.appendingPathComponent("Preview", isDirectory: true) : support
                model = LibraryModel(catalog: try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path), preview: preview, source: preview ? nil : SteamSource(runtimeTools: CrossOverTools()), runtime: preview ? nil : CrossOverRuntime(), volumeStore: preview ? nil : GamesVolumeStore(), diagnosticArchive: preview ? nil : DiagnosticArchive(root: root.appendingPathComponent("logs")))
            } catch {
                model = LibraryModel(preview: preview)
                model.persistenceError = error.localizedDescription
                model.show(.information("The library database could not be opened. This session will not save changes. Your existing database has been left in place.\n\n\(error.localizedDescription)"))
            }
        }
        super.init()
    }
    let controller = ControllerInput()
    var window: NSWindow!
    var keyboardMonitor: Any?
    private var mouseMonitor: Any?
    private var exitPanel: GameExitPanel?
    private let exitShortcut = GameExitShortcut()
    private let gameActivation = GameActivationWaiter(system: MacGameActivationSystem())
    private var gameActivationTask: Task<Void, Never>?
    private var gameActivationObserver: Any?
    private var volumeObservers: [NSObjectProtocol] = []
    private var pendingDisplayID: UInt32?
    private var resumeFullscreenAfterMove = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isTestProcess {
            NSApp.setActivationPolicy(.prohibited)
            Design.registerFonts()
            return
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--diagnose-install") {
            NSApp.setActivationPolicy(.prohibited)
            guard args.indices.contains(index + 1), let appID = UInt32(args[index + 1]) else {
                fputs("Usage: Playden --diagnose-install STEAM_APP_ID [--download-probe-root FOLDER]\n", stderr); exit(2)
            }
            var probeRoot: URL?
            if let probeIndex = args.firstIndex(of: "--download-probe-root") {
                guard args.indices.contains(probeIndex + 1) else { fputs("Specify an existing folder for --download-probe-root.\n", stderr); exit(2) }
                probeRoot = URL(fileURLWithPath: args[probeIndex + 1], isDirectory: true)
            }
            Task {
                let succeeded = await SteamInstallDiagnostics.inspect(appID: appID, downloadProbeRoot: probeRoot) { message in
                    FileHandle.standardOutput.write(Data((message + "\n").utf8))
                }
                exit(succeeded ? 0 : 1)
            }
            return
        }
        #if DEBUG
        if let index = args.firstIndex(of: "--cloud-read-check"), args.indices.contains(index + 1) {
            NSApp.setActivationPolicy(.accessory)
            Task { await CloudReadCheck.run(game: args[index + 1]); NSApp.terminate(nil) }
            return
        }
        #endif
        Design.registerFonts()
        let snapshotIndex = args.firstIndex(of: "--snapshot")
        let isSnapshot = snapshotIndex != nil
        model.fixedClock = isSnapshot
        if isSnapshot { model.reducedMotion = true }
        let requestedWidth: Int? = args.firstIndex(of: "--snapshot-width").flatMap { index in
            args.indices.contains(index + 1) ? Int(args[index + 1]) : nil
        }
        let width: CGFloat = isSnapshot ? CGFloat(min(3840, max(960, requestedWidth ?? 1920))) : 1280
        let height: CGFloat = width * 9 / 16
        NSApp.setActivationPolicy(isSnapshot ? .accessory : .regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: isSnapshot ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = model.isPreview ? "Playden — Design Preview" : "Playden"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 14 / 255, green: 13 / 255, blue: 12 / 255, alpha: 1)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 960, height: 540)
        window.delegate = self
        model.displayPresentation.window = self
        model.displayPresentation.reportFailure = { [weak self] error in
            self?.model.reportSessionIssue(error as? OperationFailure ?? .init(stage: "Prepare game display", reason: error.localizedDescription, output: ""), gameID: self?.model.session.session?.gameID)
        }
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: LauncherView(model: model))
        if isSnapshot, let snapshotIndex, args.indices.contains(snapshotIndex + 1) {
            window.orderBack(nil)
            Task { await captureScreens(to: URL(fileURLWithPath: args[snapshotIndex + 1], isDirectory: true)) }
        } else {
            installMenus()
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            refreshDisplays()
            model.onDisplaySelected = { [weak self] id in self?.moveWindow(to: id) }
            model.onFullscreenRequested = { [weak self] enabled in self?.setFullscreen(enabled) }
            model.onGameStarted = { [weak self] in
                guard let self else { return }
                self.exitShortcut.action = { [weak self] in self?.model.keyboardNavigation = true; self?.model.perform(.holdHome) }
                if !self.exitShortcut.start() {
                    self.model.reportSessionIssue(.init(stage: "Game controls", reason: "Shift–Home is already in use. Return to Playden to open the game controls.", output: "Could not register the game exit shortcut."), gameID: self.model.session.session?.gameID)
                }
            }
            model.onGameWindow = { [weak self] gameWindow in self?.activateGame(gameWindow) }
            model.onGameEnded = { [weak self] in
                guard let self else { return }
                self.gameActivationTask?.cancel(); self.gameActivationTask = nil
                self.exitShortcut.stop(); self.exitPanel?.orderOut(nil)
                if !self.model.displayPresentation.consumePreservedWindow() { self.restorePreferredDisplay() }
                self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
            model.onExitOverlayChanged = { [weak self] visible in self?.presentExitOverlay(visible) }
            model.onLauncherQuit = { NSApp.terminate(nil) }
            gameActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.clearResolvedGameActivationIssue() }
            }
            if model.shouldStartFullscreen(arguments: args) { setFullscreen(true) }
            model.startServices()
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                         NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
                volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.requestInstallationDriveRefresh() }
                })
            }
            model.startSetupServices()
            controller.onAction = { [weak self] action in
                if case .holdHome = action, self?.model.hasActiveSession == true { self?.model.performController(action); return }
                guard NSApp.isActive || self?.model.exitOverlay == true else { return }
                self?.hideCursorForNavigation()
                self?.model.performController(action)
            }
            controller.onSnapshot = { [weak self] values, time in
                guard NSApp.isActive else { return }
                self?.model.receiveControllers(values, at: time)
            }
            controller.onConnection = { [weak self] name, playStation in
                self?.model.receiveControllerConnection(name: name, playStation: playStation)
            }
            controller.start()
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                var result: NSEvent? = event
                MainActor.assumeIsolated {
                    if let self { result = self.handle(event) }
                }
                return result
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.restoreCursor()
                    self?.model.keyboardNavigation = true
                }
                return event
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.isTestProcess }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.requiresLauncherQuitConfirmation else { return true }
        NSApp.terminate(nil)
        return false
    }
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.installQueue != nil || model.sessions != nil else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        if model.requiresLauncherQuitConfirmation && !model.consumeLauncherQuitApproval() {
            model.requestLauncherQuit()
            return .terminateCancel
        }
        terminating = true
        model.launcherQuitting = true
        Task {
            await model.resetTask?.value
            await model.sessionStartup?.value
            await model.sessionCommand?.value
            do {
                await model.stopUninstallPreparation()
                await model.stopCloudCommands()
                if let sessions = model.sessions { try await sessions.shutdown() }
                else { await model.installQueue?.shutdown() }
                model.stopServices(); await model.flushLogs(); sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                model.resetLauncherQuit()
                model.reportSessionIssue(model.sessionFailure(error, stage: "Quit game"), gameID: model.session.session?.gameID)
                sender.reply(toApplicationShouldTerminate: false)
                if model.hasActiveSession { model.setExitOverlay(true) }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stopServices()
        controller.stop()
        exitShortcut.stop()
        gameActivationTask?.cancel()
        if let gameActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(gameActivationObserver) }
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        restoreCursor()
    }
    func applicationDidResignActive(_ notification: Notification) { model.launcherActive = false; restoreCursor() }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.launcherActive = true
        model.requestInstallationDriveRefresh()
        restoreCursor()
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) { refreshDisplays() }
    private func refreshDisplays() {
        model.displays = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            return DisplayChoice(id: id, name: screen.localizedName, resolution: "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))", uuid: uuid)
        }
        if model.setupScreen == .display { model.setupIndex = min(model.setupIndex, model.displays.count) }
        model.currentDisplayName = window?.screen?.localizedName
        if !model.displayPresentation.isChanging { restorePreferredDisplay() }
    }
    private func restorePreferredDisplay() {
        guard window != nil, !model.hasActiveSession else { return }
        if let display = model.preferredDisplay { moveWindow(to: display.id) }
        else if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }), let screen = NSScreen.screens.first,
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            // Keep the saved preference when unplugged; use an available screen for this session.
            moveWindow(to: id)
        }
    }
    private func moveWindow(to id: UInt32) {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { return }
        guard window.screen != screen else { return }
        if model.fullscreenTransitioning { pendingDisplayID = id; return }
        if window.styleMask.contains(.fullScreen) {
            pendingDisplayID = id; resumeFullscreenAfterMove = true; setFullscreen(false); return
        }
        if window.frame.width > screen.visibleFrame.width || window.frame.height > screen.visibleFrame.height {
            let scale = min(screen.visibleFrame.width / window.frame.width, screen.visibleFrame.height / window.frame.height)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width * scale, height: window.frame.height * scale)), display: true)
        }
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2, y: screen.visibleFrame.midY - window.frame.height / 2))
        model.currentDisplayName = screen.localizedName
    }
    private func setFullscreen(_ enabled: Bool) {
        guard !model.fullscreenTransitioning, window.styleMask.contains(.fullScreen) != enabled else { return }
        model.fullscreenTransitioning = true
        window.toggleFullScreen(nil)
    }
    var launcherFrame: CGRect { window?.frame ?? .zero }
    var launcherScreen: LauncherDisplayScreen? { window?.screen.flatMap(launcherDisplayScreen) }
    var launcherScreens: [LauncherDisplayScreen] { NSScreen.screens.compactMap(launcherDisplayScreen) }
    var launcherFullscreen: Bool { window?.styleMask.contains(.fullScreen) == true }
    var launcherFullscreenTransitioning: Bool { model.fullscreenTransitioning }
    func setLauncherFullscreen(_ enabled: Bool) {
        // This transaction supersedes pending preference-driven window moves.
        pendingDisplayID = nil; resumeFullscreenAfterMove = false
        setFullscreen(enabled)
    }
    func setLauncherFrame(_ frame: CGRect) { window?.setFrame(frame, display: true) }
    func showLauncherForRestore() async throws {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let start = ContinuousClock.now
        while !NSApp.isActive || window?.isOnActiveSpace != true {
            try Task.checkCancellation()
            guard start.duration(to: .now) < .seconds(3) else {
                throw OperationFailure(stage: "Restore launcher", reason: "macOS could not bring Playden back to its desktop.", output: "The launcher must be on the active Space before restoring fullscreen.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func launcherDisplayScreen(_ screen: NSScreen) -> LauncherDisplayScreen? {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return .init(uuid: CFUUIDCreateString(nil, uuid) as String, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
    func windowDidChangeScreen(_ notification: Notification) { model.currentDisplayName = window?.screen?.localizedName }
    func windowWillEnterFullScreen(_ notification: Notification) { model.fullscreenTransitioning = true }
    func windowWillExitFullScreen(_ notification: Notification) { model.fullscreenTransitioning = true }
    func windowDidEnterFullScreen(_ notification: Notification) {
        model.isFullscreen = true; model.fullscreenTransitioning = false
        if pendingDisplayID != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let id = self.pendingDisplayID else { return }
                self.pendingDisplayID = nil; self.moveWindow(to: id)
            }
        }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullscreen = false; model.fullscreenTransitioning = false
        // AppKit still owns the previous transition while delivering this delegate call.
        // Moving/re-entering synchronously can strand the window in its old fullscreen Space.
        if pendingDisplayID != nil || resumeFullscreenAfterMove {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let id = self.pendingDisplayID { self.pendingDisplayID = nil; self.moveWindow(to: id) }
                if self.resumeFullscreenAfterMove { self.resumeFullscreenAfterMove = false; self.setFullscreen(true) }
            }
        }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullscreenFailed() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullscreenFailed() }
    private func fullscreenFailed() {
        model.isFullscreen = window.styleMask.contains(.fullScreen); model.fullscreenTransitioning = false
        pendingDisplayID = nil; resumeFullscreenAfterMove = false
        // The presentation coordinator checks the requested state and reports a real
        // failure after cleanup. Do not leave a duplicate generic popup behind a game.
        guard !model.displayPresentation.isChanging else { return }
        model.show(.information("macOS could not switch the window mode. Try again from Settings → Display."))
    }
    private func restoreCursor() { NSCursor.setHiddenUntilMouseMoves(false) }
    private func hideCursorForNavigation() {
        guard !model.fixedClock, NSApp.isActive || exitPanel?.isKeyWindow == true else { return }
        // AppKit reveals the pointer on movement. Do not hold a hide/unhide counter across
        // mouse input or activation changes, and never capture/warp the launcher's pointer.
        NSCursor.setHiddenUntilMouseMoves(true)
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        model.keyboardNavigation = true
        if event.keyCode == 115, event.modifierFlags.contains(.shift), model.hasActiveSession { hideCursorForNavigation(); model.perform(.holdHome); return nil }
        if (model.exitOverlay || model.isLaunchingGame) && event.modifierFlags.contains(.command) { return event }
        if event.modifierFlags.contains(.command) {
            if [36, 76].contains(event.keyCode), model.isEditingText { hideCursorForNavigation(); model.finishText(); return nil }
            if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...4).contains(digit) {
                if model.panel == nil && model.authScreen == nil && model.setupScreen == nil { hideCursorForNavigation(); model.selectTab(AppTab.allCases[digit - 1]) }
                return nil
            }
            return event
        }
        let action: InputAction?
        switch event.keyCode {
        case 48: action = event.modifierFlags.contains(.shift) ? .previousTab : .nextTab
        case 123: action = .move(.left)
        case 124: action = .move(.right)
        case 125: action = .move(.down)
        case 126: action = .move(.up)
        case 36, 76: action = .confirm
        case 53: action = .back
        case 115: action = .home
        case 116: action = .previousPage
        case 121: action = .nextPage
        case 51 where model.isEditingText && !model.exitOverlay: hideCursorForNavigation(); model.eraseText(); return nil
        default:
            let text = event.characters ?? ""
            if model.isEditingText && !model.exitOverlay && !text.isEmpty && !event.modifierFlags.contains(.control) {
                hideCursorForNavigation(); model.insertText(text); return nil
            }
            action = switch text.lowercased() {
            case "[": .previousTab
            case "]": .nextTab
            case "f": .favorite
            case "t": .context
            case "o": .options
            case "/": .search
            default: nil
            }
        }
        if let action { hideCursorForNavigation(); model.perform(action); return nil }
        return event
    }
    private func activateGame(_ gameWindow: GameWindow) {
        restoreCursor()
        exitPanel?.orderOut(nil)
        gameActivationTask?.cancel()
        gameActivationTask = Task { [weak self] in
            guard let self else { return }
            let result = await gameActivation.activate(gameWindow)
            guard !Task.isCancelled, model.hasActiveSession, !model.exitOverlay,
                  model.session.session?.runtime?.window == gameWindow else { return }
            switch result {
            case .active:
                model.recordGameWindowHandoff(gameWindow)
                window.level = .normal; window.orderBack(nil)
            case .timedOut:
                model.reportSessionIssue(.init(stage: "Return to game", reason: "The game is open, but its window could not be brought forward. Use the Dock to return to it.", output: "The tracked game window did not become visible and active within five seconds."), gameID: model.session.session?.gameID)
            case .unavailable:
                // Startup windows can disappear before they become activatable. Session updates
                // will request handoff for the replacement until one is acknowledged.
                guard model.gameWindowHandedOff else { return }
                model.reportSessionIssue(.init(stage: "Return to game", reason: "The game window is no longer available. Wait for the game to finish opening, then try Return to game again.", output: "The tracked game window or process identity is no longer available."), gameID: model.session.session?.gameID)
            case .cancelled: break
            }
        }
    }
    private func clearResolvedGameActivationIssue() {
        guard model.sessionIssue?.stage == "Return to game", model.hasActiveSession,
              let target = model.session.session?.runtime?.window,
              gameActivation.system.state(of: target) == .active else { return }
        model.recordGameWindowHandoff(target)
    }
    private func presentExitOverlay(_ visible: Bool) {
        guard visible else { exitPanel?.orderOut(nil); return }
        // A late activation result must not lower the launcher or replace an opened exit panel.
        gameActivationTask?.cancel(); gameActivationTask = nil
        var screen = window.screen ?? NSScreen.main
        var gameLevel = NSWindow.Level.normal.rawValue
        if let gameWindow = model.session.session?.runtime?.window,
           let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], gameWindow.id) as? [[String: Any]])?.first,
           let dictionary = info[kCGWindowBounds as String] as? [String: Any],
           let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            gameLevel = info[kCGWindowLayer as String] as? Int ?? gameLevel
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            screen = NSScreen.screens.first { $0.frame.contains(center) } ?? screen
        }
        guard let screen else { return }
        if exitPanel == nil {
            let panel = GameExitPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.level = .floating
            panel.contentView = NSHostingView(rootView: ScaledGameExitOverlay(model: model))
            exitPanel = panel
        }
        exitPanel?.setFrame(screen.frame, display: true)
        // Wine's exclusive fullscreen window can sit above the normal floating-panel level.
        exitPanel?.level = .init(rawValue: max(NSWindow.Level.floating.rawValue, gameLevel + 1))
        exitPanel?.orderFrontRegardless(); exitPanel?.makeKey()
    }
    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Playden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        let fullscreen = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]
        NSApp.mainMenu = main
    }
    private func captureScreens(to directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Prime the same cache used by the interactive app; no fixture image substitutions.
            for game in model.games { if let url = game.coverURL { _ = await ArtworkCache.shared.image(for: url) } }
            for title in ["Hades", "TUNIC"] {
                if let game = model.games.first(where: { $0.title == title }) {
                    for url in [game.heroURL, game.logoURL].compactMap({ $0 }) { _ = await ArtworkCache.shared.image(for: url) }
                }
            }
            let arguments = ProcessInfo.processInfo.arguments
            let reducedMotion = arguments.contains("--snapshot-reduced-motion")
            model.reducedMotion = reducedMotion
            let requestedScreens: Set<String>? = arguments.firstIndex(of: "--snapshot-screens").flatMap { index in
                arguments.indices.contains(index + 1) ? Set(arguments[index + 1].split(separator: ",").map(String.init)) : nil
            }
            for screen in ["game-settings", "game-more", "game-settings-more", "game-settings-custom", "picker-graphics", "profile-chooser", "toast-settings", "cloud-timestamp", "launcher-quit", "launcher-quit-warning", "exit-overlay-warning", "launcher-quitting", "game-drive-disconnected", "game-drive-checking", "context-drive-disconnected", "library-drive-disconnected", "toast-complete", "toast-failed", "toast-connected", "toast-disconnected", "uninstall-confirm", "uninstall-unsynced", "uninstall-checking", "cloud-ready", "cloud-conflict", "cloud-account", "cloud-pending", "cloud-syncing", "cloud-recovery", "home", "home-tabs", "home-library-card", "home-playstation", "home-large-library", "home-large-library-end", "home-collection-end", "library-large", "library-large-end", "library", "library-playstation", "library-paged", "library-return", "game", "game-status-clean", "game-status-crash", "library-running", "context-uninstall", "downloads", "downloads-queued", "settings", "settings-about", "settings-reset", "settings-reset-blocked", "settings-reset-error", "settings-reset-busy", "settings-display", "settings-runtime", "settings-runtime-missing", "settings-runtime-busy", "collections", "keyboard", "keyboard-playstation", "keyboard-generic", "keyboard-space", "keyboard-long", "compatibility", "uninstall", "logs", "logs-retry", "logs-long", "logs-long-end", "logs-long-return", "signin-qr", "signin-password", "signin-error", "setup-controller", "setup-permissions", "setup-display", "setup-volume", "setup-runtime", "setup-error", "setup-ready", "controller-test", "controller-waiting", "library-filters", "library-filters-bottom", "library-download-glyph", "library-download-focused", "library-artwork-fallback", "game-unknown-size", "game-favorite", "install-offer", "install-offer-space", "install-queue", "install-verifying", "install-verifying-all", "install-history-failed", "install-history-completed", "install-mini-progress", "install-storage-shortage", "install-storage-unavailable", "install-game-progress", "launching", "exit-overlay", "exit-overlay-quit", "notification", "notification-focused"] {
                if let requestedScreens, !requestedScreens.contains(screen) { continue }
                // Keep each capture independent of the requested screen order.
                let model = LibraryModel()
                model.fixedClock = true
                model.reducedMotion = reducedMotion
                model.resetBusy = false; model.resetError = nil; model.resetBlocker = nil
                model.panel = nil; model.detailID = nil; model.authScreen = nil; model.setupScreen = nil
                model.session = .init(); model.exitOverlay = false; model.controllerName = nil
                model.cloudStatuses = [:]; model.cloudReview = nil
                model.uninstallBusy = false; model.uninstallReview = nil; model.uninstallError = nil; model.uninstallPhase = .confirm
                model.setupBusy = false; model.runtimeChecking = false; model.setupFailure = nil; model.setupIndex = 0; model.onboarding = false
                switch screen {
                case "game-drive-disconnected", "game-drive-checking", "context-drive-disconnected", "library-drive-disconnected":
                    model.selectTab(.library)
                    model.controllerName = "DUALSHOCK 4"
                    if let index = model.games.firstIndex(where: { $0.title == "A Short Hike" }) {
                        model.games[index].status = screen == "game-drive-checking" ? .installed : .driveDisconnected
                        let game = model.games[index]
                        if screen == "game-drive-checking" {
                            model.installationDriveTargets[game.id] = .init(installationID: UUID(), location: .init(volumeID: "snapshot", lastKnownRoot: URL(fileURLWithPath: "/snapshot"), relativePath: "game"))
                            model.checkingInstallationDrives = [game.id]
                        }
                        model.libraryCursor = .init(index: model.filteredGames.firstIndex { $0.id == game.id } ?? 0)
                        if screen != "library-drive-disconnected" { model.openGame(game) }
                        if screen == "context-drive-disconnected" { model.show(.context) }
                    }
                case "toast-complete", "toast-failed", "toast-connected", "toast-disconnected":
                    model.selectTab(.library)
                    model.controllerName = "DUALSHOCK 4"
                    if screen == "toast-disconnected" {
                        model.receiveControllerConnection(name: nil, playStation: true)
                    } else if screen == "toast-connected" {
                        model.controllerName = nil
                        model.receiveControllerConnection(name: "DUALSHOCK 4", playStation: true)
                    } else {
                        let failed = screen == "toast-failed"
                        model.enqueueNotification(.init(source: .job(UUID()), tone: failed ? .failure : .success,
                            title: failed ? "Installation failed" : "Download complete",
                            detail: failed ? "A Short Hike · The connection was interrupted." : "A Short Hike",
                            guidance: failed ? "Open Downloads for Retry and View logs" : nil))
                    }
                case "game-status-clean", "game-status-crash", "library-running", "context-uninstall": model.configureGameStatusSnapshot(screen)
                case "uninstall-confirm", "uninstall-unsynced", "uninstall-checking": model.configureUninstallSnapshot(screen)
                case "cloud-ready", "cloud-conflict", "cloud-account", "cloud-pending", "cloud-syncing", "cloud-recovery": model.configureCloudSnapshot(screen)
                case "launcher-quit", "launcher-quit-warning", "exit-overlay-warning", "launcher-quitting", "launching", "exit-overlay", "exit-overlay-quit", "notification", "notification-focused": model.configureSessionSnapshot(screen)
                case "library-download-glyph", "library-download-focused":
                    model.selectTab(.library); model.filter = .all
                    if let index = model.games.firstIndex(where: { $0.title == "Disco Elysium" }) { model.games[index].status = .notInstalled }
                    let title = screen == "library-download-focused" ? "Disco Elysium" : "A Short Hike"
                    if let index = model.filteredGames.firstIndex(where: { $0.title == title }) { model.libraryCursor = GridCursor(index: index) }
                case "game-unknown-size", "game-favorite":
                    model.selectTab(.library)
                    if let index = model.games.firstIndex(where: { $0.title == "TUNIC" }) {
                        model.games[index].status = .notInstalled; model.games[index].size = "—"
                        model.games[index].isFavorite = screen == "game-favorite"
                        model.openGame(model.games[index]); model.detailAction = screen == "game-favorite" ? 2 : 0
                    }
                case "settings-runtime", "settings-runtime-missing", "settings-runtime-busy":
                    model.selectTab(.settings); model.settingsSection = 1; model.settingsIndex = 3
                    model.setupScreen = .runtime
                    model.runtimeInfo = RuntimeInfo(version: screen == "settings-runtime-missing" ? nil : "26.2", templateVersion: "1", templateReady: screen == "settings-runtime")
                    model.setupBusy = screen == "settings-runtime-busy"
                    model.templateStage = model.setupBusy ? .creating : .checking
                    if screen == "settings-runtime-missing" { model.setupFailure = OperationFailure(stage: "Check runtime", reason: "Install CrossOver in Applications, then try again.", output: "Snapshot fixture") }
                case "setup-controller", "setup-permissions", "setup-display", "setup-volume", "setup-runtime", "setup-error", "setup-ready":
                    model.onboarding = true
                    model.setupScreen = screen == "setup-controller" ? .controller : screen == "setup-permissions" ? .permissions : screen == "setup-display" ? .display : screen == "setup-volume" ? .volume : .runtime
                    model.displays = [DisplayChoice(id: 1, name: "Living room TV", resolution: "3840 × 2160"), DisplayChoice(id: 2, name: "Studio Display", resolution: "5120 × 2880")]
                    model.availableVolumes = [GamesVolume(id: "fixture-ssd", name: "Games SSD", mountURL: URL(fileURLWithPath: "/Volumes/Games"), gamesRoot: URL(fileURLWithPath: "/Volumes/Games/Playden/games"), freeBytes: 812_000_000_000, totalBytes: 1_000_000_000_000, isRecommended: true), GamesVolume(id: "fixture-mac", name: "This Mac", mountURL: URL(fileURLWithPath: "/"), gamesRoot: URL(fileURLWithPath: "/fixture/games"), freeBytes: 206_000_000_000, totalBytes: 1_000_000_000_000)]
                    model.selectedVolumeID = "fixture-ssd"
                    model.runtimeInfo = RuntimeInfo(version: "26.2", templateVersion: "1", templateReady: screen == "setup-ready")
                    model.templateStage = screen == "setup-ready" ? .ready : .creating
                    model.setupBusy = screen == "setup-runtime"
                    if screen == "setup-error" { model.setupFailure = OperationFailure(stage: "Create template", reason: "Game setup couldn’t finish. Try again, or browse your library and set up later.", output: "Design fixture") }
                case "home-tabs":
                    model.selectTab(.home); model.perform(.move(.up))
                case "home-library-card":
                    model.selectTab(.home)
                    model.homeColumns[0] = model.rows[0].games.count
                case "home-playstation", "library-playstation":
                    model.selectTab(screen == "home-playstation" ? .home : .library)
                    model.controllerName = "DualShock 4"; model.playStationGlyphs = true; model.keyboardNavigation = false
                case "library": model.selectTab(.library)
                case "library-paged":
                    model.selectTab(.library); model.perform(.nextPage); model.perform(.nextPage)
                case "library-return":
                    model.selectTab(.library)
                    for _ in 0..<5 { model.perform(.nextPage) }
                    for _ in 0..<5 { model.perform(.previousPage) }
                case "downloads-queued":
                    model.selectTab(.downloads); model.perform(.move(.down))
                case "game-settings", "game-more", "game-settings-more", "game-settings-custom", "picker-graphics", "profile-chooser", "toast-settings":
                    if let game = model.games.first(where: { $0.status == .installed }) {
                        model.openGame(game)
                        switch screen {
                        case "game-more": model.show(.context)
                        case "toast-settings":
                            model.showGameSettings(game.id)
                            model.setOverride(game.id, .graphics, .scalar("dxvk"))
                            model.setOverride(game.id, .highResolution, .scalar("off"))
                            model.setOverride(game.id, .virtualDesktop, .scalar("1920x1080"))
                            model.closeGameSettings()
                        default:
                            model.runtimeProfiles[game.id] = RuntimeProfile(base: "older-3d-game",
                                overrides: screen == "game-settings-custom" ? [.highResolution: .scalar("off")] : [:])
                            model.showGameSettings(game.id)
                            switch screen {
                            case "game-settings-more", "game-settings-custom":
                                model.moreSettingsExpanded = true
                                if let index = model.settingsRows(for: game.id).firstIndex(of: .setting(.virtualDesktop)) { model.settingsFocus = index }
                            case "picker-graphics":
                                if let index = model.settingsRows(for: game.id).firstIndex(of: .setting(.graphics)) { model.settingsFocus = index }
                                model.showSettingPicker(game.id, .graphics)
                                if let dxvkIndex = model.pickerChoices(game.id, .graphics).firstIndex(where: { $0.value == "dxvk" }) { model.pickerIndex = dxvkIndex }
                            case "profile-chooser":
                                // Compare the default profile against "Older 3D game" so the table shows its changes.
                                model.runtimeProfiles[game.id] = nil
                                model.showProfileChooser(game.id)
                                if let index = model.chooserRows(game.id).firstIndex(where: { $0?.id == "older-3d-game" }) { model.chooserIndex = index }
                            default: break
                            }
                        }
                    }
                case "cloud-timestamp":
                    model.configureCloudSnapshot("cloud-ready")
                    if let id = model.detailID { model.showCloud(id) }
                case "game":
                    model.selectTab(.library)
                    if let index = model.games.firstIndex(where: { $0.title == "TUNIC" }) {
                        model.games[index].status = .notInstalled; model.openGame(model.games[index])
                    }
                case "downloads":
                    if let index = model.games.firstIndex(where: { $0.title == "TUNIC" }) { model.games[index].status = .downloading }
                    model.selectTab(.downloads)
                case "library-filters", "library-filters-bottom":
                    model.selectTab(.library); model.show(.filters)
                    if screen == "library-filters-bottom" {
                        model.refinements.compatibility = .playable
                        model.filterChoiceIndex = max(0, model.filterLayout.chips.count - 1); model.revealFilterFocus()
                    }
                case "controller-test", "controller-waiting":
                    model.selectTab(.settings); model.settingsSection = 4
                    let buttons = Dictionary(uniqueKeysWithValues: ControllerControl.allCases.map { ($0, Float(0)) })
                    let idle = ControllerSnapshot(id: "fixture-ds4", name: "DUALSHOCK 4 Wireless Controller", playStation: true, buttons: buttons)
                    model.connectedControllers = screen == "controller-test" ? [idle] : []
                    model.openControllerTest()
                    if screen == "controller-test" {
                        var pressed = buttons; pressed[.south] = 1; pressed[.leftTrigger] = 0.64
                        model.receiveControllers([ControllerSnapshot(id: idle.id, name: idle.name, playStation: true, buttons: pressed,
                            leftStick: .init(x: 0.62, y: 0.4), rightStick: .init(x: -0.2, y: -0.7))], at: ProcessInfo.processInfo.systemUptime)
                    }
                case "settings-about", "settings-reset", "settings-reset-blocked", "settings-reset-error", "settings-reset-busy": model.configureResetSnapshot(screen)
                case "settings": model.selectTab(.settings)
                case "settings-display":
                    model.selectTab(.settings); model.settingsSection = 2; model.settingsRailFocused = false; model.settingsIndex = 1
                    model.displays = [DisplayChoice(id: 1, name: "Living room TV", resolution: "3840 × 2160", uuid: "fixture-tv")]
                    model.selectedDisplayID = 1; model.selectedDisplayUUID = "fixture-tv"; model.isFullscreen = true
                case "signin-qr", "signin-password", "signin-error":
                    model.authScreen = screen == "signin-password" ? .credentials : .qr
                    model.authIndex = 0
                    // A non-authenticating design sample; real challenges are never written to captures.
                    model.authQR = screen == "signin-qr" ? URL(string: "https://example.invalid/playden-design-preview") : nil
                    model.authMessage = "Design preview · QR layout"
                    model.authError = screen == "signin-error" ? "Steam can’t be reached. Check your connection and try again." : nil
                case "collections", "keyboard", "keyboard-playstation", "keyboard-generic", "keyboard-space", "keyboard-long", "compatibility", "uninstall", "logs", "logs-retry", "logs-long", "logs-long-end", "logs-long-return":
                    model.selectTab(.library)
                    if let game = model.games.first(where: { $0.title == "Hades" }) {
                        model.openGame(game)
                        switch screen {
                        case "collections": model.show(.collections(game.id))
                        case "keyboard", "keyboard-playstation", "keyboard-generic", "keyboard-space", "keyboard-long":
                            model.symbols = false; model.uppercase = false
                            model.beginText(.newCollection(game.id)); model.insertText("Weekend favorites")
                            model.keyRow = screen == "keyboard-space" ? 4 : 1; model.keyColumn = 0
                            model.keyboardNavigation = screen == "keyboard" || screen == "keyboard-long"
                            if !model.keyboardNavigation {
                                model.controllerName = screen == "keyboard-generic" ? "Xbox Wireless Controller" : "DUALSHOCK 4"
                                model.playStationGlyphs = screen != "keyboard-generic"
                            }
                            if screen == "keyboard-long" {
                                model.beginText(.compatibilityNote(game.id))
                                model.insertText(String(repeating: "Long compatibility note. ", count: 12) + "Latest typed words")
                            }
                        case "compatibility":
                            model.compatibilityNotes[game.id] = "Works well with the controller. Try a lower resolution for a quieter Mac."
                            model.show(.compatibility); model.panelIndex = 1
                        case "uninstall": model.show(.confirmation(.uninstall(game.id)))
                        default:
                            model.show(.logs(game.id))
                            if screen == "logs-retry" {
                                var played = PlaySessionRecord(gameID: game.id, bottleID: "snapshot-only")
                                played.endedAt = played.startedAt; played.outcome = .launchFailed
                                var log = DiagnosticLog(id: played.id, gameID: game.id, kind: "play session", startedAt: played.startedAt)
                                log.record("Prepare game · failed", at: played.startedAt)
                                log.capture("The game runtime could not be prepared. Reconnect the games drive, then retry.", at: played.startedAt)
                                model.logDocument = log; model.logSession = played; model.logActionIndex = 1
                            }
                            if screen.hasPrefix("logs-long") {
                                var log = DiagnosticLog(id: UUID(), gameID: game.id, kind: "repair", startedAt: Date(timeIntervalSince1970: 1_788_832_000))
                                log.record("download · running", at: log.startedAt)
                                log.captureCommand(.init(tool: "cxstart", timestamp: log.startedAt.addingTimeInterval(8), exitCode: 0, output: "PLAYDEN_GAME_BOTTLE_READY"))
                                log.record("stage · failed · Preparation: The runtime could not prepare the game.", at: log.startedAt.addingTimeInterval(15))
                                log.capture((1...100).map { "Line \($0): Verified game content; preparing the owned runtime and checking the game's launch configuration. Diagnostic output remains selectable and wraps to fit the screen." }.joined(separator: "\n"), at: log.startedAt.addingTimeInterval(15))
                                model.logDocument = log
                            }
                        }
                    }
                default: model.selectTab(.home)
                }
                let isLargeLibrary = screen.contains("large-library") || screen.hasPrefix("library-large") || screen == "home-collection-end"
                let fixture = screen == "library-artwork-fallback" ? LibraryModel(preview: true) : isLargeLibrary ? BrowseSnapshots.model(for: screen) : screen.hasPrefix("install-") ? InstallSnapshots.model(for: screen) : model
                if screen == "library-artwork-fallback" {
                    fixture.games = [("228400", "ACE COMBAT™ ASSAULT HORIZON Enhanced Edition"),
                        ("18700", "And Yet It Moves"), ("219890", "Antichamber"), ("24420", "Aquaria")].map { id, title in
                        Game(id: .init(source: "steam", value: id), title: title,
                            coverURL: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg"))
                    }
                    fixture.fixedClock = true; fixture.selectTab(.library); fixture.filter = .all
                    fixture.libraryCursor = GridCursor(index: 1)
                    for game in fixture.games { _ = await ArtworkCache.shared.image(for: game.coverURL, fallbackURL: game.coverFallbackURL) }
                }
                fixture.reducedMotion = reducedMotion
                if screen.hasPrefix("game-status") || screen == "context-uninstall", let game = fixture.focusedGame {
                    for url in [game.heroURL, game.logoURL].compactMap({ $0 }) { _ = await ArtworkCache.shared.image(for: url) }
                }
                window.contentView = NSHostingView(rootView: LauncherView(model: fixture))
                try await Task.sleep(for: .seconds(2))
                if screen == "logs-long-end" || screen == "logs-long-return" {
                    for _ in 0..<40 { model.perform(.nextPage); try await Task.sleep(for: .milliseconds(30)) }
                    if screen == "logs-long-return" {
                        for _ in 0..<40 { model.perform(.previousPage); try await Task.sleep(for: .milliseconds(30)) }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard let view = window.contentView else { continue }
                view.layoutSubtreeIfNeeded()
                let output = directory.appendingPathComponent("\(screen).png")
                if arguments.contains("--snapshot-offscreen") {
                    // Explicit SwiftUI-only rendering for layout review while the desktop is
                    // locked. Native NSViewRepresentable content still needs a window capture.
                    let renderer = ImageRenderer(content: LauncherView(model: fixture)
                        .frame(width: view.bounds.width, height: view.bounds.height))
                    renderer.scale = 1
                    guard let bitmap = renderer.cgImage,
                          let data = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else { throw CaptureError.bitmap }
                    try data.write(to: output, options: .atomic)
                    print("Rendered offscreen \(output.path)")
                    continue
                }
                guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenPermission }
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
                try capture.run()
                capture.waitUntilExit()
                guard capture.terminationStatus == 0 else { throw CaptureError.bitmap }
                print("Captured \(output.path)")
            }
        } catch { fputs("Snapshot failed: \(error)\n", stderr); exit(1) }
        NSApp.terminate(nil)
    }
    enum CaptureError: Error { case bitmap, screenPermission }
}

@MainActor
private final class GameExitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
