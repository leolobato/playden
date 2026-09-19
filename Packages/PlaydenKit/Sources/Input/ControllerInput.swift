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
    private var menuInput = ControllerMenuInput()
    private var lastController: GCController?
    private var lastSnapshotTime = 0.0
    public init() {}

    public func start() {
        guard timer == nil else { return }
        GCController.shouldMonitorBackgroundEvents = true
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        // Keep repeats and connection checks alive during AppKit tracking modes.
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        detachController()
        GCController.shouldMonitorBackgroundEvents = false
    }

    private func detachController() {
        lastController?.input.inputStateAvailableHandler = nil
        lastController?.input.inputStateQueueDepth = 1
        lastController = nil; menuInput = .init()
    }

    private func poll() {
        let controllers = GCController.controllers()
        let controller = controllers.first(where: { $0.extendedGamepad != nil })
        if controller !== lastController {
            detachController()
            lastController = controller
            if let controller {
                let input = controller.input
                input.queue = .main
                input.inputStateQueueDepth = 256
                input.inputStateAvailableHandler = { [weak self, weak controller] _ in
                    MainActor.assumeIsolated {
                        guard let self, let controller, self.lastController === controller else { return }
                        self.drain(controller)
                    }
                }
            }
            onConnection?(controller?.vendorName, controller?.extendedGamepad is GCDualShockGamepad || controller?.extendedGamepad is GCDualSenseGamepad)
        }
        if let controller { drain(controller) }
        let now = ProcessInfo.processInfo.systemUptime
        for action in menuInput.advance(at: now) { onAction?(action) }
        if now - lastSnapshotTime >= 1.0 / 30 {
            lastSnapshotTime = now
            onSnapshot?(controllers.compactMap(Self.snapshot), now)
        }
    }

    private func drain(_ controller: GCController) {
        // Reading only extendedGamepad's live values collapses press/release/press
        // into a single held state when the main thread is busy. Consume every sample.
        while let state = controller.input.nextInputState() {
            let dpad = state.dpads[.directionPad]
            let stick = state.dpads[.leftThumbstick]
            let direction = DirectionRepeater.direction(x: dpad?.xAxis.value ?? 0, y: dpad?.yAxis.value ?? 0)
                ?? DirectionRepeater.direction(x: stick?.xAxis.value ?? 0, y: stick?.yAxis.value ?? 0)
            let buttons: [(ControllerControl, GCButtonElementName)] = [
                (.south, .a), (.east, .b), (.west, .x), (.north, .y),
                (.menu, .menu), (.home, .home),
                (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
                (.leftTrigger, .leftTrigger), (.rightTrigger, .rightTrigger)
            ]
            var pressed = Set(buttons.compactMap { control, name in
                state.buttons[name]?.pressedInput.isPressed == true ? control : nil
            })
            let touchpad = state.buttons[GCButtonElementName(rawValue: GCInputDualShockTouchpadButton)]
            if (touchpad ?? state.buttons[.options])?.pressedInput.isPressed == true { pressed.insert(.share) }
            // Translate event age into the uptime clock used by held-button ticks.
            let time = ProcessInfo.processInfo.systemUptime - max(0, state.lastEventLatency)
            for action in menuInput.consume(.init(direction: direction, buttons: pressed), at: time) {
                onAction?(action)
            }
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
