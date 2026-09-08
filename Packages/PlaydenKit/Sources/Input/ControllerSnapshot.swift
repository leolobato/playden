import Foundation

public enum ControllerControl: String, CaseIterable, Sendable {
    case south, east, west, north, up, down, left, right
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger, leftStick, rightStick
    case menu, share, home, touchpad
    public func label(playStation: Bool) -> String {
        switch self {
        case .south: playStation ? "✕" : "A"
        case .east: playStation ? "○" : "B"
        case .west: playStation ? "□" : "X"
        case .north: playStation ? "△" : "Y"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .leftShoulder: playStation ? "L1" : "LB"
        case .rightShoulder: playStation ? "R1" : "RB"
        case .leftTrigger: playStation ? "L2" : "LT"
        case .rightTrigger: playStation ? "R2" : "RT"
        case .leftStick: "L3"
        case .rightStick: "R3"
        case .menu: playStation ? "OPTIONS" : "MENU"
        case .share: playStation ? "SHARE" : "VIEW"
        case .home: playStation ? "PS" : "HOME"
        case .touchpad: "PAD"
        }
    }
}

public struct StickPosition: Equatable, Sendable {
    public let x: Float
    public let y: Float
    public init(x: Float = 0, y: Float = 0) {
        func clamp(_ value: Float) -> Float { value.isFinite ? (min(1, max(-1, value)) * 100).rounded() / 100 : 0 }
        self.x = clamp(x); self.y = clamp(y)
    }
}

/// Process-local IDs identify connected devices, never accounts or hardware serial numbers.
public struct ControllerSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let playStation: Bool
    public let buttons: [ControllerControl: Float]
    public let leftStick: StickPosition
    public let rightStick: StickPosition
    public init(id: String, name: String, playStation: Bool, buttons: [ControllerControl: Float] = [:],
                leftStick: StickPosition = .init(), rightStick: StickPosition = .init()) {
        self.id = id; self.name = name; self.playStation = playStation
        self.buttons = buttons.mapValues { $0.isFinite ? (min(1, max(0, $0)) * 100).rounded() / 100 : 0 }
        self.leftStick = leftStick; self.rightStick = rightStick
    }
    public var pressed: Set<ControllerControl> { Set(buttons.filter { $0.value > 0.25 }.map(\.key)) }
}

/// Holding Back exits the test without making a short press impossible to test.
public struct ControllerTestState: Sendable {
    public private(set) var devices: [ControllerSnapshot] = []
    public private(set) var selectedID: String?
    public private(set) var tested: [String: Set<ControllerControl>] = [:]
    public private(set) var lastInput: String?
    public private(set) var closeProgress = 0.0
    private var closeBegan: Double?
    private var closeDeviceID: String?
    public init() {}
    public var selected: ControllerSnapshot? { devices.first { $0.id == selectedID } ?? devices.first }
    @discardableResult public mutating func update(_ values: [ControllerSnapshot], at time: Double) -> Bool {
        for device in values {
            let before = devices.first { $0.id == device.id }
            let newlyPressed = device.pressed.subtracting(before?.pressed ?? [])
            if !newlyPressed.isEmpty || (before != nil && (before?.leftStick != device.leftStick || before?.rightStick != device.rightStick)) {
                selectedID = device.id
                if let control = ControllerControl.allCases.first(where: { newlyPressed.contains($0) }) {
                    lastInput = control.label(playStation: device.playStation)
                } else { lastInput = "Stick movement" }
            }
            tested[device.id, default: []].formUnion(device.pressed)
        }
        devices = values
        if !values.contains(where: { $0.id == selectedID }) { selectedID = values.first?.id; lastInput = nil }
        if let holding = values.first(where: { $0.pressed.contains(.east) }) {
            if closeDeviceID != holding.id { closeBegan = time; closeDeviceID = holding.id }
            closeProgress = min(1, max(0, (time - (closeBegan ?? time)) / 1.2))
        } else { closeBegan = nil; closeDeviceID = nil; closeProgress = 0 }
        return closeProgress >= 1
    }
}
