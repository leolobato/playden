import Focus

/// Each buffered hardware state is consumed in order, including releases between taps.
struct ControllerMenuState {
    var direction: Direction?
    var buttons: Set<ControllerControl> = []
}

struct ControllerMenuInput {
    private var state = ControllerMenuState()
    private var repeater = DirectionRepeater()
    private var homeHold = HomeHold()
    private var pressed: Set<ControllerControl> = []

    mutating func consume(_ state: ControllerMenuState, at time: Double) -> [InputAction] {
        self.state = state
        return advance(at: time)
    }

    mutating func advance(at time: Double) -> [InputAction] {
        var actions: [InputAction] = []
        if let event = homeHold.event(pressed: state.buttons.contains(.home), at: time) {
            actions.append(event == .hold ? .holdHome : .home)
        }
        if let direction = repeater.update(state.direction, at: time) { actions.append(.move(direction)) }
        let bindings: [(ControllerControl, InputAction)] = [
            (.south, .confirm), (.east, .back), (.north, .context), (.west, .favorite),
            (.menu, .options), (.leftShoulder, .previousTab), (.rightShoulder, .nextTab),
            (.leftTrigger, .previousPage), (.rightTrigger, .nextPage), (.share, .search)
        ]
        for (button, action) in bindings where state.buttons.contains(button) && !pressed.contains(button) {
            actions.append(action)
        }
        pressed = state.buttons
        return actions
    }
}
