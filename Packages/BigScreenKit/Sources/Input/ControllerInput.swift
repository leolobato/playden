import Foundation
import GameController
import Focus

public enum InputAction: Sendable {
    case move(Direction), confirm, back, context, favorite, options, search, home
    case previousTab, nextTab, previousPage, nextPage
}

/// Foreground navigation only. Background game/overlay routing remains the M0 feasibility gate.
@MainActor
public final class ControllerInput {
    public var onAction: ((InputAction) -> Void)?
    public var onConnection: ((String?, Bool) -> Void)?
    private var timer: Timer?
    private var repeater = DirectionRepeater()
    private var lastController: GCController?
    private var pressed: Set<String> = []
    public init() {}

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() { timer?.invalidate(); timer = nil; pressed.removeAll(); repeater = .init() }

    private func poll() {
        let controller = GCController.controllers().first
        if controller !== lastController {
            lastController = controller; pressed.removeAll(); repeater = .init()
            onConnection?(controller?.vendorName, controller?.extendedGamepad is GCDualShockGamepad)
        }
        guard let pad = controller?.extendedGamepad else { return }
        let dpad = DirectionRepeater.direction(x: pad.dpad.xAxis.value, y: pad.dpad.yAxis.value)
        let stick = DirectionRepeater.direction(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value)
        if let direction = repeater.update(dpad ?? stick, at: ProcessInfo.processInfo.systemUptime) {
            onAction?(.move(direction))
        }
        let buttons: [(String, GCControllerButtonInput?, InputAction)] = [
            ("confirm", pad.buttonA, .confirm), ("back", pad.buttonB, .back),
            ("context", pad.buttonY, .context), ("favorite", pad.buttonX, .favorite),
            ("options", pad.buttonMenu, .options), ("home", pad.buttonHome, .home),
            ("previousTab", pad.leftShoulder, .previousTab), ("nextTab", pad.rightShoulder, .nextTab),
            ("previousPage", pad.leftTrigger, .previousPage), ("nextPage", pad.rightTrigger, .nextPage),
            ("search", (pad as? GCDualShockGamepad)?.touchpadButton ?? pad.buttonOptions, .search),
        ]
        for (name, button, action) in buttons {
            if button?.isPressed == true {
                if pressed.insert(name).inserted { onAction?(action) }
            } else { pressed.remove(name) }
        }
    }
}
