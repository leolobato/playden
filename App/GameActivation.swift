import AppKit
import Domain
import Runner

enum GameActivationState { case unavailable, registering, inactive, hidden, obscured, active }
enum GameActivationResult { case active, unavailable, timedOut, cancelled }

@MainActor
protocol GameActivationSystem {
    func state(of window: GameWindow) -> GameActivationState
    func requestActivation(of window: GameWindow)
    func ownsForeground(_ window: GameWindow) -> Bool
}

@MainActor
struct MacGameActivationSystem: GameActivationSystem {
    func state(of window: GameWindow) -> GameActivationState {
        guard RuntimeProcessInspector().identity(of: window.process.pid) == window.process,
              let values = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let value = values.first(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == window.id &&
                  ($0[kCGWindowOwnerPID as String] as? Int32) == window.process.pid
              }) else { return .unavailable }
        // Wine can publish its first CG window before AppKit has registered an activatable app.
        guard let app = NSRunningApplication(processIdentifier: window.process.pid) else { return .registering }
        if app.isTerminated { return .unavailable }
        // Activation alone does not mean macOS switched to the Space containing the game.
        if app.isActive {
            guard value[kCGWindowIsOnscreen as String] as? Bool == true else { return .hidden }
            return Self.isObscured(window, in: values) ? .obscured : .active
        }
        if !app.isFinishedLaunching || app.activationPolicy == .prohibited { return .registering }
        return .inactive
    }

    func ownsForeground(_ window: GameWindow) -> Bool {
        RuntimeProcessInspector().identity(of: window.process.pid) == window.process &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == window.process.pid
    }

    // CG's onscreen flag includes windows covered by other apps. Only ordinary application
    // windows count here; menu bars, floating palettes and system overlays may stay above games.
    static func isObscured(_ window: GameWindow, in values: [[String: Any]]) -> Bool {
        guard let index = values.firstIndex(where: { ($0[kCGWindowNumber as String] as? UInt32) == window.id }),
              let bounds = values[index][kCGWindowBounds as String] as? [String: Any],
              let target = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return values[..<index].contains { value in
            guard value[kCGWindowIsOnscreen as String] as? Bool == true,
                  value[kCGWindowLayer as String] as? Int == 0,
                  (value[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  value[kCGWindowOwnerPID as String] as? Int32 != window.process.pid,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 64, rect.height >= 64 else { return false }
            return target.intersects(rect)
        }
    }

    func requestActivation(of window: GameWindow) {
        guard [.inactive, .hidden, .obscured].contains(state(of: window)),
              let app = NSRunningApplication(processIdentifier: window.process.pid) else { return }
        // An already-active Wine app can create a new window behind other apps. It needs its
        // windows ordered forward, rather than another cooperative transfer from Playden.
        if app.isActive { _ = app.activate(options: [.activateAllWindows]) }
        else {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current, options: [.activateAllWindows])
        }
        // Acceptance of a request is not evidence of foreground activation. The waiter observes it.
    }
}

@MainActor
struct GameActivationWaiter {
    let system: any GameActivationSystem
    var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }

    func activate(_ window: GameWindow, preservingForeground: Bool = false) async -> GameActivationResult {
        var nextRequest = 0
        var activeSamples = 0
        for attempt in 0...50 {
            guard !Task.isCancelled else { return .cancelled }
            if preservingForeground && !system.ownsForeground(window) { return .cancelled }
            let state = system.state(of: window)
            if state != .active { activeSamples = 0 }
            switch state {
            case .active:
                activeSamples += 1
                // Do not acknowledge a single transient activation while Wine changes windows.
                if activeSamples >= 6 { return .active }
            case .unavailable: return .unavailable
            case .registering: break
            case .inactive, .hidden, .obscured:
                // Wine's activation and Space/window registration can settle separately.
                // Retry at most twice per second while this exact window remains the target.
                if attempt >= nextRequest && attempt < 50 {
                    system.requestActivation(of: window); nextRequest = attempt + 5
                }
            }
            guard attempt < 50 else { return .timedOut }
            do { try await wait() } catch { return .cancelled }
        }
        return .timedOut
    }
}
