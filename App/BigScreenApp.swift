import AppKit
import CoreGraphics
import SwiftUI
import Input
import Focus

@main
struct BigScreenApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = LibraryModel()
    let controller = ControllerInput()
    var window: NSWindow!
    var keyboardMonitor: Any?
    private var cursorHidden = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Design.registerFonts()
        let args = ProcessInfo.processInfo.arguments
        let snapshotIndex = args.firstIndex(of: "--snapshot")
        let isSnapshot = snapshotIndex != nil
        model.fixedClock = isSnapshot
        model.reducedMotion = isSnapshot
        let width: CGFloat = isSnapshot ? 1920 : 1280
        let height: CGFloat = isSnapshot ? 1080 : 720
        NSApp.setActivationPolicy(isSnapshot ? .accessory : .regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: isSnapshot ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "GameNative Big Screen — Design Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 14 / 255, green: 13 / 255, blue: 12 / 255, alpha: 1)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 960, height: 540)
        window.delegate = self
        window.contentView = NSHostingView(rootView: LauncherView(model: model))
        if isSnapshot, let snapshotIndex, args.indices.contains(snapshotIndex + 1) {
            window.orderBack(nil)
            Task { await captureScreens(to: URL(fileURLWithPath: args[snapshotIndex + 1], isDirectory: true)) }
        } else {
            installMenus()
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if args.contains("--fullscreen") { window.toggleFullScreen(nil) }
            controller.onAction = { [weak self] action in
                guard NSApp.isActive else { return }
                self?.model.perform(action)
            }
            controller.onConnection = { [weak self] name, playStation in
                self?.model.controllerName = name
                self?.model.playStationGlyphs = name == nil || playStation
            }
            controller.start()
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                var result: NSEvent? = event
                MainActor.assumeIsolated {
                    if let self { result = self.handle(event) }
                }
                return result
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        restoreCursor()
    }
    func applicationDidResignActive(_ notification: Notification) { restoreCursor() }
    private func restoreCursor() { if cursorHidden { NSCursor.unhide(); cursorHidden = false } }
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) { return event }
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        let action: InputAction?
        switch event.keyCode {
        case 123: action = .move(.left)
        case 124: action = .move(.right)
        case 125: action = .move(.down)
        case 126: action = .move(.up)
        case 36, 76: action = .confirm
        case 53: action = .back
        case 115: action = .home
        case 116: action = .previousPage
        case 121: action = .nextPage
        case 51 where model.panel == .search: model.updateQuery(String(model.query.dropLast())); return nil
        default:
            let text = event.characters ?? ""
            if model.panel == .search && !text.isEmpty && !event.modifierFlags.contains(.control) {
                model.updateQuery(model.query + text); return nil
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
        if let action { model.perform(action); return nil }
        return event
    }
    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit GameNative Big Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            model.reducedMotion = false
            for screen in ["home", "library", "game", "downloads", "settings"] {
                model.panel = nil; model.detailID = nil
                switch screen {
                case "library": model.selectTab(.library)
                case "game":
                    model.selectTab(.library)
                    if let index = model.games.firstIndex(where: { $0.title == "TUNIC" }) {
                        model.games[index].status = .notInstalled; model.openGame(model.games[index])
                    }
                case "downloads":
                    if let index = model.games.firstIndex(where: { $0.title == "TUNIC" }) { model.games[index].status = .downloading }
                    model.selectTab(.downloads)
                case "settings": model.selectTab(.settings)
                default: model.selectTab(.home)
                }
                try await Task.sleep(for: .seconds(2))
                guard let view = window.contentView else { continue }
                view.layoutSubtreeIfNeeded()
                let output = directory.appendingPathComponent("\(screen).png")
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
