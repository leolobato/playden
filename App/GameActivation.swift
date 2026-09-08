import AppKit
import Domain
import Runner

enum GameActivationState { case unavailable, registering, inactive, active }
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
              values.contains(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == window.id &&
                  ($0[kCGWindowOwnerPID as String] as? Int32) == window.process.pid
              }) else { return .unavailable }
        // Wine can publish its first CG window before AppKit has registered an activatable app.
        guard let app = NSRunningApplication(processIdentifier: window.process.pid) else { return .registering }
        if app.isTerminated { return .unavailable }
        if app.isActive { return .active }
        if !app.isFinishedLaunching || app.activationPolicy == .prohibited { return .registering }
        return .inactive
    }

    func requestActivation(of window: GameWindow) {
        guard state(of: window) == .inactive,
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
        var requested = false
        for attempt in 0...20 {
            guard !Task.isCancelled else { return .cancelled }
            switch system.state(of: window) {
            case .active: return .active
            case .unavailable: return .unavailable
            case .registering: break
            case .inactive:
                if !requested { system.requestActivation(of: window); requested = true }
            }
            guard attempt < 20 else { return .timedOut }
            do { try await wait() } catch { return .cancelled }
        }
        return .timedOut
    }
}
