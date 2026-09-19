import Foundation
import Domain
import Runner

struct LauncherDisplayScreen: Equatable {
    let uuid: String
    let frame: CGRect
    let visibleFrame: CGRect
}

/// All frames use AppKit coordinates. Their global origin changes when the primary
/// monitor changes; the stable identity and offset within a monitor do not.
struct LauncherWindowPosition: Equatable {
    let displayUUID: String
    let relativeFrame: CGRect
    let fullscreen: Bool

    init(frame: CGRect, screen: LauncherDisplayScreen, fullscreen: Bool) {
        displayUUID = screen.uuid
        relativeFrame = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        self.fullscreen = fullscreen
    }
    func frame(on screen: LauncherDisplayScreen) -> CGRect {
        var frame = relativeFrame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        // A Dock/menu bar or a changed mode can reduce the usable area.
        frame.size.width = min(frame.width, screen.visibleFrame.width)
        frame.size.height = min(frame.height, screen.visibleFrame.height)
        frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        return frame
    }
    func restoringFullscreen(_ fullscreen: Bool) -> LauncherWindowPosition {
        .init(displayUUID: displayUUID, relativeFrame: relativeFrame, fullscreen: fullscreen)
    }
    private init(displayUUID: String, relativeFrame: CGRect, fullscreen: Bool) {
        self.displayUUID = displayUUID; self.relativeFrame = relativeFrame; self.fullscreen = fullscreen
    }
}

@MainActor protocol LauncherWindowControlling: AnyObject {
    var launcherFrame: CGRect { get }
    var launcherScreen: LauncherDisplayScreen? { get }
    var launcherScreens: [LauncherDisplayScreen] { get }
    var launcherFullscreen: Bool { get }
    var launcherFullscreenTransitioning: Bool { get }
    func setLauncherFullscreen(_ enabled: Bool)
    func setLauncherFrame(_ frame: CGRect)
    func showLauncherForRestore() async throws
}

/// Coordinates the app's fullscreen Space around *both* Core Graphics transactions.
/// The Windows runner owns the lease; the app owns its window presentation.
@MainActor final class LauncherDisplayPresentation {
    weak var window: (any LauncherWindowControlling)?
    var reportFailure: (Error) -> Void = { _ in }
    private(set) var isChanging = false
    private(set) var preservedForSession = false

    func consumePreservedWindow() -> Bool {
        defer { preservedForSession = false }
        return preservedForSession
    }

    func acquire(target: GameDisplayTarget, forGame: Bool = true,
                 start: (GameDisplayTarget) async throws -> any PrimaryDisplayHolding) async throws -> any PrimaryDisplayHolding {
        isChanging = true
        defer { isChanging = false }
        let position = try await prepare()
        if forGame { preservedForSession = true }
        var acquired: (any PrimaryDisplayHolding)?
        do {
            try Task.checkCancellation()
            let lease = try await start(target)
            acquired = lease
            // Reentering fullscreen here creates a separate Space immediately before Wine
            // opens its window. Stay on the desktop for handoff; restore fullscreen at exit.
            var destination = forGame ? position.restoringFullscreen(false) : position
            if !forGame, let screen = window?.launcherScreens.first(where: { $0.uuid == lease.target.displayUUID }),
               screen.uuid != position.displayUUID {
                // Immersive mode may have disconnected the launcher's previous monitor.
                destination = .init(frame: screen.visibleFrame, screen: screen, fullscreen: position.fullscreen)
            }
            try await restore(destination)
            try Task.checkCancellation()
            return PresentedPrimaryDisplay(base: lease, presentation: self, position: position, restoreOriginalFullscreen: forGame)
        } catch {
            // A cancelled launch still needs uncancelled AppKit transitions and native rollback.
            await Task { @MainActor in
                if let acquired {
                    _ = try? await self.prepare()
                    await acquired.release()
                }
                do { try await self.restore(position) } catch { self.reportFailure(error) }
            }.value
            throw error
        }
    }

    fileprivate func release(_ base: any PrimaryDisplayHolding, fallback: LauncherWindowPosition, restoreOriginalFullscreen: Bool) async {
        isChanging = true
        defer { isChanging = false }
        var position = fallback
        do { position = try await prepare() } catch { reportFailure(error) }
        if restoreOriginalFullscreen { position = position.restoringFullscreen(fallback.fullscreen) }
        // A failed UI transition must not leave the temporary system configuration held.
        await base.release()
        do { try await restore(position) } catch { reportFailure(error) }
    }

    private func prepare() async throws -> LauncherWindowPosition {
        try await waitForTransition()
        guard let window, let screen = window.launcherScreen else { throw failure("The launcher’s monitor is unavailable.") }
        let initial = LauncherWindowPosition(frame: window.launcherFrame, screen: screen, fullscreen: window.launcherFullscreen)
        do {
            if initial.fullscreen {
                window.setLauncherFullscreen(false)
                try await waitForTransition()
                guard !window.launcherFullscreen else { throw failure("macOS could not leave the launcher’s fullscreen Space.") }
            }
            // Exiting fullscreen reveals AppKit's saved normal window frame. Preserve that
            // frame, not the fullscreen rectangle, for subsequent toggles back to windowed.
            guard let originalScreen = window.launcherScreens.first(where: { $0.uuid == initial.displayUUID }) else {
                throw failure("The launcher’s monitor was disconnected.")
            }
            return .init(frame: window.launcherFrame, screen: originalScreen, fullscreen: initial.fullscreen)
        } catch {
            await Task { @MainActor in
                do {
                    try await self.waitForTransition()
                    let restored = !window.launcherFullscreen
                        ? LauncherWindowPosition(frame: window.launcherFrame, screen: screen, fullscreen: initial.fullscreen)
                        : initial
                    try await self.restore(restored)
                } catch { self.reportFailure(error) }
            }.value
            throw error
        }
    }

    private func restore(_ position: LauncherWindowPosition) async throws {
        try await waitForTransition()
        guard let window else { return }
        if window.launcherFullscreen {
            if position.fullscreen && window.launcherScreen?.uuid == position.displayUUID { return }
            window.setLauncherFullscreen(false)
            try await waitForTransition()
            guard !window.launcherFullscreen else { throw failure("macOS could not restore the launcher’s monitor.") }
        }
        guard let screen = window.launcherScreens.first(where: { $0.uuid == position.displayUUID }) else {
            throw failure("The launcher’s previous monitor was disconnected.")
        }
        window.setLauncherFrame(position.frame(on: screen))
        if position.fullscreen {
            // AppKit may reject fullscreen changes for a background window in another Space.
            try await window.showLauncherForRestore()
            window.setLauncherFullscreen(true)
            try await waitForTransition()
            guard window.launcherFullscreen, window.launcherScreen?.uuid == position.displayUUID else {
                throw failure("macOS could not restore the launcher’s fullscreen Space on its monitor.")
            }
        }
    }

    private func waitForTransition() async throws {
        let start = ContinuousClock.now
        while window?.launcherFullscreenTransitioning == true {
            try Task.checkCancellation()
            guard start.duration(to: .now) < .seconds(8) else { throw failure("The launcher’s fullscreen transition timed out. Try again in windowed mode.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }
    private func failure(_ reason: String) -> OperationFailure {
        .init(stage: "Prepare game display", reason: reason, output: "Could not preserve the launcher window during a primary-display change.")
    }
}

@MainActor private final class PresentedPrimaryDisplay: PrimaryDisplayHolding {
    nonisolated let target: GameDisplayTarget
    private let base: any PrimaryDisplayHolding
    private let presentation: LauncherDisplayPresentation
    private let position: LauncherWindowPosition
    private let restoreOriginalFullscreen: Bool
    private var cleanup: Task<Void, Never>?
    init(base: any PrimaryDisplayHolding, presentation: LauncherDisplayPresentation, position: LauncherWindowPosition, restoreOriginalFullscreen: Bool) {
        self.base = base; self.presentation = presentation; self.position = position; target = base.target
        self.restoreOriginalFullscreen = restoreOriginalFullscreen
    }
    func isAlive() async -> Bool { await base.isAlive() }

    func release() async {
        if cleanup == nil {
            cleanup = Task { @MainActor [base, presentation, position, restoreOriginalFullscreen] in
                await presentation.release(base, fallback: position, restoreOriginalFullscreen: restoreOriginalFullscreen)
            }
        }
        await cleanup?.value
    }
}
