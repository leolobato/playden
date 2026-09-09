import Foundation
import Domain
import Input
import Focus

enum GameSettingsRow: Equatable { case profile, moreSettings, setting(RuntimeSettingID), resetAll }

extension LibraryModel {
    func profile(for id: GameID) -> RuntimeProfile { runtimeProfiles[id] ?? RuntimeProfile() }
    func profileLabel(_ id: GameID) -> String { RuntimeResolver.displayName(profile(for: id), catalog: profileCatalog) }
    /// The base profile's own name, without the "Custom · from" prefix — for the picker footnote and toast.
    func profileName(_ id: GameID) -> String {
        guard let baseID = profile(for: id).base, let curated = profileCatalog[baseID] else { return "Playden default" }
        return curated.name
    }
    func resolvedValues(_ id: GameID) -> (resolved: [RuntimeSettingID: RuntimeSettingValue], base: [RuntimeSettingID: RuntimeSettingValue]) {
        RuntimeResolver.values(profile(for: id), catalog: profileCatalog)
    }
    func settingsRows(for id: GameID) -> [GameSettingsRow] {
        var rows: [GameSettingsRow] = [.profile] + GameSettingsCatalog.rows(in: .tier1).map { .setting($0.id) } + [.moreSettings]
        if moreSettingsExpanded { rows += GameSettingsCatalog.rows(in: .tier2).map { .setting($0.id) } }
        rows += GameSettingsCatalog.rows(in: .advanced).map { .setting($0.id) }
        rows.append(.resetAll)
        return rows
    }
    var focusedSettingsRow: GameSettingsRow? {
        guard case .gameSettings(let id) = panel else { return nil }
        return settingsRows(for: id)[safe: settingsFocus]
    }
    func rowValueLabel(_ id: GameID, _ setting: RuntimeSettingID) -> String {
        GameSettingsCatalog.valueLabel(setting, value: resolvedValues(id).resolved[setting], launchOptions: gameLaunchOptions[id] ?? [])
    }
    func rowDiffers(_ id: GameID, _ setting: RuntimeSettingID) -> Bool { profile(for: id).overrides[setting] != nil }

    func showGameSettings(_ id: GameID) {
        settingsFocus = 0; moreSettingsExpanded = false; settingsScrollOffset = 0; settingsChangedCount = 0
        gameSettingsError = nil
        show(.gameSettings(id))
    }
    /// Back from a picker or the profile chooser keeps the sheet's focus and change count.
    func returnToGameSettings(_ id: GameID) { panel = .gameSettings(id) }
    func closeGameSettings() {
        guard case .gameSettings(let id) = panel else { panel = nil; return }
        panel = nil
        guard settingsChangedCount > 0 else { return }
        enqueueNotification(.init(source: .settings(id), tone: .success,
            title: "Settings saved · \(profileLabel(id))",
            detail: settingsChangedCount == 1 ? "1 change applies on next launch" : "\(settingsChangedCount) changes apply on next launch"))
    }

    private func persistRuntimeProfile(_ profile: RuntimeProfile, for id: GameID) throws {
        if let catalog {
            var edits = try catalog.edits(for: id)
            edits.runtime = profile
            try catalog.saveEdits(edits, for: id)
        } else if !isPreview {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    func setOverride(_ id: GameID, _ setting: RuntimeSettingID, _ value: RuntimeSettingValue?) {
        var updated = profile(for: id)
        if let value { updated.overrides[setting] = value } else { updated.overrides.removeValue(forKey: setting) }
        let normalized = RuntimeResolver.normalized(updated, catalog: profileCatalog)
        guard normalized != profile(for: id) else { return }
        do {
            try persistRuntimeProfile(normalized, for: id)
            runtimeProfiles[id] = normalized
            settingsChangedCount += 1
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }
    func resetAllToProfile(_ id: GameID) {
        var updated = profile(for: id)
        let removed = updated.overrides.count
        guard removed > 0 else { return }
        updated.overrides = [:]
        do {
            try persistRuntimeProfile(updated, for: id)
            runtimeProfiles[id] = updated
            settingsChangedCount += removed
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }
    func applyProfile(_ id: GameID, profileID: String) {
        let updated = RuntimeProfile(base: profileID, overrides: [:], source: .profile, appliedAt: .now)
        guard updated != profile(for: id) else { return }
        do {
            try persistRuntimeProfile(updated, for: id)
            runtimeProfiles[id] = updated
            settingsChangedCount += 1
        } catch {
            gameSettingsError = "Could not save game settings. Try again."
        }
    }

    // MARK: - Picker
    func showSettingPicker(_ id: GameID, _ setting: RuntimeSettingID) {
        let choices = pickerChoices(id, setting)
        let currentValue = resolvedValues(id).resolved[setting]
        pickerIndex = choices.firstIndex { choice in
            guard case .scalar(let raw)? = currentValue else { return false }
            return choice.value == raw
        } ?? 0
        panel = .settingPicker(id, setting)
    }
    /// `.launchOption` synthesizes one choice per the game's own launch options; the first is the default.
    func pickerChoices(_ id: GameID, _ setting: RuntimeSettingID) -> [RuntimeSettingChoice] {
        switch GameSettingsCatalog.definition(setting).kind {
        case .choices(let choices): return choices
        case .launchOption:
            return (gameLaunchOptions[id] ?? []).map { option in
                RuntimeSettingChoice(value: option.id, name: option.title, shortName: option.title,
                    explanation: "Starts this launch entry.", technicalNames: option.spec.executableRelativePath)
            }
        case .text: return []
        }
    }
    /// "Playden default" wins over "From profile" when a choice happens to be both.
    func pickerMeta(_ id: GameID, _ setting: RuntimeSettingID, choice: RuntimeSettingChoice) -> String? {
        let isDefault: Bool
        if case .launchOption = GameSettingsCatalog.definition(setting).kind {
            isDefault = pickerChoices(id, setting).first?.value == choice.value
        } else {
            isDefault = GameSettingsCatalog.isDefaultValue(setting, choice.value)
        }
        if isDefault { return "Playden default" }
        if case .scalar(let base)? = resolvedValues(id).base[setting], base == choice.value { return "From profile" }
        return nil
    }
    func activatePickerChoice() {
        guard case .settingPicker(let id, let setting) = panel, let choice = pickerChoices(id, setting)[safe: pickerIndex] else { return }
        setOverride(id, setting, .scalar(choice.value))
        returnToGameSettings(id)
    }

    // MARK: - Profile chooser
    func showProfileChooser(_ id: GameID) {
        let current = profile(for: id)
        if current.isCustom { chooserIndex = profileCatalog.profiles.count }
        else {
            let baseID = current.base ?? CuratedProfileCatalog.playdenDefaultID
            chooserIndex = profileCatalog.profiles.firstIndex { $0.id == baseID } ?? 0
        }
        panel = .profileChooser(id)
    }
    /// `nil` stands in for the trailing Custom row, shown only while the profile has overrides.
    func chooserRows(_ id: GameID) -> [CuratedProfile?] {
        var rows: [CuratedProfile?] = profileCatalog.profiles
        if profile(for: id).isCustom { rows.append(nil) }
        return rows
    }
    struct SettingComparison: Equatable { let id: RuntimeSettingID; let title: String; let current: String; let proposed: String; let changed: Bool }
    /// Rows where the game's current value or the candidate profile's value differs from the Playden default.
    func comparison(_ id: GameID, with profileID: String) -> [SettingComparison] {
        guard let curated = profileCatalog[profileID] else { return [] }
        let resolved = resolvedValues(id).resolved
        var proposedValues = RuntimeResolver.defaultValues
        for (key, value) in curated.settings { proposedValues[key] = value }
        let launchOptions = gameLaunchOptions[id] ?? []
        return RuntimeSettingID.allCases.filter { $0 != .launchOption }.compactMap { settingID in
            let currentValue = resolved[settingID]
            let proposedValue = proposedValues[settingID]
            let defaultValue = RuntimeResolver.defaultValues[settingID]
            guard currentValue != defaultValue || proposedValue != defaultValue || currentValue != proposedValue else { return nil }
            let currentLabel = GameSettingsCatalog.valueLabel(settingID, value: currentValue, launchOptions: launchOptions)
            let proposedLabel = GameSettingsCatalog.valueLabel(settingID, value: proposedValue, launchOptions: launchOptions)
            return SettingComparison(id: settingID, title: GameSettingsCatalog.definition(settingID).title,
                current: currentLabel, proposed: proposedLabel, changed: currentLabel != proposedLabel)
        }
    }
    func activateChooserSelection() {
        guard case .profileChooser(let id) = panel, let row = chooserRows(id)[safe: chooserIndex] else { return }
        if let curated = row { applyProfile(id, profileID: curated.id) }
        returnToGameSettings(id)
    }

    // MARK: - Input
    func performGameSettingsInput(_ action: InputAction) -> Bool {
        switch panel {
        case .gameSettings(let id):
            let rows = settingsRows(for: id)
            switch action {
            case .move(let direction):
                if direction == .up { settingsFocus = max(0, settingsFocus - 1) }
                else if direction == .down { settingsFocus = min(max(0, rows.count - 1), settingsFocus + 1) }
                // .left/.right have nothing to do in this single-column list.
            case .confirm:
                switch rows[safe: settingsFocus] {
                case .profile: showProfileChooser(id)
                case .moreSettings:
                    moreSettingsExpanded.toggle()
                    settingsFocus = min(settingsFocus, max(0, settingsRows(for: id).count - 1))
                case .setting(let setting):
                    switch GameSettingsCatalog.definition(setting).kind {
                    case .choices, .launchOption: showSettingPicker(id, setting)
                    case .text: beginText(.runtimeText(id, setting))
                    }
                case .resetAll: if profile(for: id).isCustom { resetAllToProfile(id) }
                case nil: break
                }
            case .back: closeGameSettings()
            case .context: if case .setting(let setting) = rows[safe: settingsFocus] { setOverride(id, setting, nil) }
            case .previousPage: settingsFocus = max(0, settingsFocus - 5)
            case .nextPage: settingsFocus = min(max(0, rows.count - 1), settingsFocus + 5)
            default: break
            }
            return true
        case .settingPicker(let id, let setting):
            switch action {
            case .move(let direction):
                let choices = pickerChoices(id, setting)
                pickerIndex = min(max(0, pickerIndex + (direction == .up || direction == .left ? -1 : 1)), max(0, choices.count - 1))
            case .confirm: activatePickerChoice()
            case .back: returnToGameSettings(id)
            case .context: setOverride(id, setting, nil); returnToGameSettings(id)
            default: break
            }
            return true
        case .profileChooser(let id):
            switch action {
            case .move(let direction):
                if direction == .up { chooserIndex = max(0, chooserIndex - 1) }
                else if direction == .down { chooserIndex = min(max(0, chooserRows(id).count - 1), chooserIndex + 1) }
            case .confirm: activateChooserSelection()
            case .back: returnToGameSettings(id)
            default: break
            }
            return true
        default: return false
        }
    }
}
