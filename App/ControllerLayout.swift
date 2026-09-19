import Input

extension LibraryModel {
    var controllerBackButton: ControllerControl { useNintendoButtonLayout ? .south : .east }
    var controllerConfirmGlyph: String { (useNintendoButtonLayout ? ControllerControl.east : .south).label(playStation: playStationGlyphs) }
    var controllerBackGlyph: String { controllerBackButton.label(playStation: playStationGlyphs) }
    var controllerFavoriteGlyph: String { (useNintendoButtonLayout ? ControllerControl.north : .west).label(playStation: playStationGlyphs) }
    var controllerContextGlyph: String { (useNintendoButtonLayout ? ControllerControl.west : .north).label(playStation: playStationGlyphs) }

    func toggleNintendoButtonLayout() {
        do {
            let enabled = !useNintendoButtonLayout
            try updateSetupPreferences { $0.useNintendoButtonLayout = enabled }
            useNintendoButtonLayout = enabled
        } catch {
            persistenceError = error.localizedDescription
            show(.persistenceFailure)
        }
    }

    /// Remap controller events at the launcher boundary; keyboard and mouse actions
    /// remain semantic, and the button tester continues showing physical input.
    func mappedControllerAction(_ action: InputAction) -> InputAction {
        guard useNintendoButtonLayout else { return action }
        return switch action {
        case .confirm: .back
        case .back: .confirm
        case .context: .favorite
        case .favorite: .context
        default: action
        }
    }
}
