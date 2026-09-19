import AppKit
import Domain
import Runner

/// Serializes display leases so changing monitors never stacks temporary layouts.
@MainActor final class ImmersiveDisplayController {
    var acquire: (GameDisplayTarget) async throws -> any PrimaryDisplayHolding = { _ in
        throw OperationFailure(stage: "Immersive mode", reason: "The display helper is unavailable.", output: "")
    }
    var darken: ([LauncherDisplayScreen]) -> Void = { _ in }
    var stateChanged: (Bool, Error?) -> Void = { _, _ in }
    private(set) var activeDisplayUUID: String?
    private var requestedUUID: String?
    private var fullscreenDisplayUUID: String?
    private var screens: [LauncherDisplayScreen] = []
    private var lease: (any PrimaryDisplayHolding)?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var failure: Error?

    func update(target: GameDisplayTarget?, screens: [LauncherDisplayScreen]) {
        guard !stopped else { return }
        self.screens = screens
        let uuid = target?.displayUUID
        guard uuid != requestedUUID else { updateDarkening(); return }
        requestedUUID = uuid; generation += 1
        let revision = generation, previous = worker
        // Never leave every monitor covered after unplugging or changing the target.
        darken([]); stateChanged(true, nil)
        worker = Task { @MainActor in
            await previous?.value
            guard generation == revision, !stopped else { return }
            let old = lease; lease = nil; activeDisplayUUID = nil
            await old?.release()
            guard generation == revision, !stopped else { return }
            failure = nil
            if let target, let uuid {
                do {
                    let acquired = try await acquire(target)
                    guard generation == revision, !stopped else { await acquired.release(); return }
                    lease = acquired; activeDisplayUUID = uuid
                } catch { failure = error }
            }
            guard generation == revision, !stopped else { return }
            updateDarkening(); stateChanged(false, failure)
        }
    }

    /// Visibility is independent of the primary-display lease, which stays stable during games.
    func updatePresentation(fullscreenDisplayUUID: String?, screens: [LauncherDisplayScreen]) {
        guard !stopped else { return }
        self.fullscreenDisplayUUID = fullscreenDisplayUUID
        self.screens = screens
        updateDarkening()
    }

    func waitUntilReady() async throws {
        var revision: Int
        repeat {
            revision = generation
            await worker?.value
            try Task.checkCancellation()
        } while revision != generation
        if let failure { throw failure }
    }

    func shutdown() async {
        stopped = true; generation += 1; requestedUUID = nil
        darken([])
        await worker?.value
        let old = lease; lease = nil; activeDisplayUUID = nil
        await old?.release()
        stateChanged(false, nil)
    }

    private func updateDarkening() {
        guard let uuid = activeDisplayUUID, uuid == requestedUUID, uuid == fullscreenDisplayUUID,
              screens.contains(where: { $0.uuid == uuid }) else { darken([]); return }
        darken(screens.filter { $0.uuid != uuid })
    }
}

@MainActor final class DarkenedDisplayWindows {
    private var windows: [String: NSPanel] = [:]
    func update(_ screens: [LauncherDisplayScreen]) {
        let retained = Set(screens.map(\.uuid))
        for uuid in Array(windows.keys) where !retained.contains(uuid) {
            windows.removeValue(forKey: uuid)?.close()
        }
        for screen in screens {
            let panel: NSPanel
            if let existing = windows[screen.uuid] { panel = existing }
            else {
                panel = DarkenedDisplayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.backgroundColor = .black; panel.isOpaque = true; panel.hasShadow = false
                panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true; panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                windows[screen.uuid] = panel
            }
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
        }
    }
}

private final class DarkenedDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Both rectangles must use the same coordinate system. A maximized desktop window
/// that leaves room for the menu bar or Dock does not qualify as fullscreen.
enum ImmersiveFullscreenGeometry {
    static func fillsDisplay(_ window: CGRect, display: CGRect) -> Bool {
        guard !window.isEmpty, !display.isEmpty else { return false }
        let tolerance: CGFloat = 2
        return abs(window.minX - display.minX) <= tolerance &&
            abs(window.minY - display.minY) <= tolerance &&
            abs(window.maxX - display.maxX) <= tolerance &&
            abs(window.maxY - display.maxY) <= tolerance
    }
}
