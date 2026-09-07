import Foundation
import GameController
import Focus

public enum InputAction: Sendable {
    case move(Direction), confirm, back, context, favorite, options, search, home, holdHome
    case previousTab, nextTab, previousPage, nextPage
}

/// The app routes background input only to the held Home action; normal navigation stays local.
@MainActor
public final class ControllerInput {
    public var onAction: ((InputAction) -> Void)?
    public var onConnection: ((String?, Bool) -> Void)?
    public var onSnapshot: (([ControllerSnapshot], Double) -> Void)?
    private var timer: Timer?
    private var repeater = DirectionRepeater()
    private var lastController: GCController?
    private var pressed: Set<String> = []
    private var lastSnapshotTime = 0.0
    private var homeHold = HomeHold()
    public init() {}

    public func start() {
        guard timer == nil else { return }
        GCController.shouldMonitorBackgroundEvents = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() { timer?.invalidate(); timer = nil; pressed.removeAll(); repeater = .init(); homeHold = .init(); GCController.shouldMonitorBackgroundEvents = false }

    private func poll() {
        let controllers = GCController.controllers()
        let controller = controllers.first(where: { $0.extendedGamepad != nil })
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSnapshotTime >= 1.0 / 30 {
            lastSnapshotTime = now
            onSnapshot?(controllers.compactMap(Self.snapshot), now)
        }
        if controller !== lastController {
            lastController = controller; pressed.removeAll(); repeater = .init(); homeHold = .init()
            onConnection?(controller?.vendorName, controller?.extendedGamepad is GCDualShockGamepad || controller?.extendedGamepad is GCDualSenseGamepad)
        }
        guard let pad = controller?.extendedGamepad else { return }
        if homeHold.update(pressed: pad.buttonHome?.isPressed == true, at: now) { onAction?(.holdHome) }
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
            ("search", (pad as? GCDualShockGamepad)?.touchpadButton ?? (pad as? GCDualSenseGamepad)?.touchpadButton ?? pad.buttonOptions, .search),
        ]
        for (name, button, action) in buttons {
            if button?.isPressed == true {
                if pressed.insert(name).inserted { onAction?(action) }
            } else { pressed.remove(name) }
        }
    }

    private static func snapshot(_ controller: GCController) -> ControllerSnapshot? {
        guard let pad = controller.extendedGamepad else { return nil }
        let controls: [(ControllerControl, GCControllerButtonInput?)] = [
            (.south, pad.buttonA), (.east, pad.buttonB), (.west, pad.buttonX), (.north, pad.buttonY),
            (.up, pad.dpad.up), (.down, pad.dpad.down), (.left, pad.dpad.left), (.right, pad.dpad.right),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.leftTrigger, pad.leftTrigger), (.rightTrigger, pad.rightTrigger),
            (.leftStick, pad.leftThumbstickButton), (.rightStick, pad.rightThumbstickButton),
            (.menu, pad.buttonMenu), (.share, pad.buttonOptions), (.home, pad.buttonHome),
            (.touchpad, (pad as? GCDualShockGamepad)?.touchpadButton ?? (pad as? GCDualSenseGamepad)?.touchpadButton),
        ]
        return ControllerSnapshot(id: String(describing: ObjectIdentifier(controller)), name: controller.vendorName ?? "Game controller",
            playStation: pad is GCDualShockGamepad || pad is GCDualSenseGamepad,
            buttons: Dictionary(uniqueKeysWithValues: controls.compactMap { control, button in button.map { (control, $0.value) } }),
            leftStick: .init(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value),
            rightStick: .init(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value))
    }
}
