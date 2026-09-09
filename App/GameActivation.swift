import AppKit
import Domain
import Runner

enum GameActivationState { case unavailable, registering, inactive, hidden, active }
enum GameActivationResult { case active, unavailable, timedOut, cancelled }

@MainActor
protocol GameActivationSystem {
    func state(of window: GameWindow) -> GameActivationState
    func requestActivation(of window: GameWindow)
}

@MainActor
struct MacGameActivationSystem: GameActivationSystem {
    func state(of window: GameWindow) -> GameActivationState {
        guard RuntimeProcessInspector().identity(of: window.process.pid) == window.process,
              let values = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: Any]],
              let value = values.first(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == window.id &&
                  ($0[kCGWindowOwnerPID as String] as? Int32) == window.process.pid
              }) else { return .unavailable }
        // Wine can publish its first CG window before AppKit has registered an activatable app.
        guard let app = NSRunningApplication(processIdentifier: window.process.pid) else { return .registering }
        if app.isTerminated { return .unavailable }
        // Activation alone does not mean macOS switched to the Space containing the game.
        if app.isActive { return value[kCGWindowIsOnscreen as String] as? Bool == true ? .active : .hidden }
        if !app.isFinishedLaunching || app.activationPolicy == .prohibited { return .registering }
        return .inactive
    }

    func requestActivation(of window: GameWindow) {
        guard [.inactive, .hidden].contains(state(of: window)),
              let app = NSRunningApplication(processIdentifier: window.process.pid) else { return }
        NSApp.yieldActivation(to: app)
        // Acceptance of a request is not evidence of foreground activation. The waiter observes it.
        _ = app.activate(from: .current, options: [.activateAllWindows])
    }
}

@MainActor
struct GameActivationWaiter {
    let system: any GameActivationSystem
    var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }

    func activate(_ window: GameWindow) async -> GameActivationResult {
        var nextRequest = 0
        for attempt in 0...50 {
            guard !Task.isCancelled else { return .cancelled }
            switch system.state(of: window) {
            case .active: return .active
            case .unavailable: return .unavailable
            case .registering: break
            case .inactive, .hidden:
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
